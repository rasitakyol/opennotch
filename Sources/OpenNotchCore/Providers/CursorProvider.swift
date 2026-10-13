import Foundation

/// Cursor included usage and Grok Bot, read with the session of the Cursor IDE or the Grok Bot app
/// (both sign into the same Cursor account).
///
/// The included pool follows the subscription from `GetPlanInfo`: some plans reset weekly, others with
/// the monthly billing cycle. The third-party Other models pool is not shown.
public struct CursorProvider: UsageProvider {
    public let id = ProviderID.cursor
    private let http: HTTPClient

    static let api = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/")!

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    static var ideDatabase: String {
        LocalFiles.path("Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb")
    }

    /// Grok Bot ("Sand") keeps its Cursor account list in plain JSON next to its other app data.
    static var grokBotSecrets: String {
        LocalFiles.path("Library", "Application Support", "Grok Bot", "sand-secrets.json")
    }

    public func detect() async -> Bool {
        LocalFiles.exists(Self.ideDatabase) || LocalFiles.exists(Self.grokBotSecrets)
    }

    public func fetch() async throws -> ProviderSnapshot {
        let tokens = Self.localTokens()
        guard !tokens.isEmpty else { throw ProviderIssue.notConfigured }
        // Several apps may hold a token for the account; use the one that stays valid the longest.
        guard let token = tokens
            .filter({ !JWT.isExpired($0) })
            .max(by: { (JWT.expiry($0) ?? .distantPast) < (JWT.expiry($1) ?? .distantPast) })
        else { throw ProviderIssue.expired }

        async let usageCall = http.connect(Self.api.appendingPathComponent("GetCurrentPeriodUsage"), bearer: token)
        async let planCall = try? http.connect(Self.api.appendingPathComponent("GetPlanInfo"), bearer: token)
        async let grokBotCall = try? http.connect(Self.api.appendingPathComponent("GetSandUsageStatus"), bearer: token)
        let usage = try await usageCall
        let plan = await planCall
        let grokBot = await grokBotCall

        let metrics = Self.parse(usage: usage, grokBot: grokBot, plan: plan)
        guard !metrics.isEmpty else { throw ProviderIssue.unexpected("No usage data found") }
        let membership = SQLiteKV.value(forKey: "cursorAuth/stripeMembershipType", databaseAt: Self.ideDatabase)
        return ProviderSnapshot(provider: id, plan: Self.planName(plan: plan, grokBot: grokBot, membership: membership), metrics: metrics)
    }

    static func localTokens() -> [String] {
        var tokens: [String] = []
        if let token = SQLiteKV.value(forKey: "cursorAuth/accessToken", databaseAt: ideDatabase), !token.isEmpty {
            tokens.append(token)
        }
        if let secrets = LocalFiles.json(grokBotSecrets),
           let accountsText = secrets["cursor-accounts"].string,
           let accounts = try? JSON(string: accountsText) {
            let active = accounts["active"].string
            let ordered = accounts["accounts"].dictionary.sorted {
                ($0.key == active ? 0 : 1, $0.key) < ($1.key == active ? 0 : 1, $1.key)
            }
            for (_, account) in ordered {
                if let token = account["cursor-access-token"].string, !token.isEmpty { tokens.append(token) }
            }
        }
        return tokens
    }

    /// `plan` is `GetPlanInfo`. Its included-usage period decides whether the pool is a weekly limit.
    public static func parse(usage: JSON, grokBot: JSON?, plan: JSON? = nil) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        let info = plan.map { $0["planInfo"] }
        let weekly = info.map { Self.isWeekly($0["includedUsagePeriod"]) } ?? false
        let cycleEnd = ISODate.fromUnix(usage["billingCycleEnd"].double)
            ?? info.flatMap { ISODate.fromUnix($0["billingCycleEnd"].double) }
        let resetsAt = weekly
            ? (info.flatMap { ISODate.fromUnix($0["includedUsageResetsAt"].double) } ?? cycleEnd)
            : cycleEnd
        let window: UsageWindow = weekly ? .weekly : .monthly
        let pools = usage["planUsage"]

        // A merged plan has one included pool (`totalPercentUsed`). Otherwise the figure is the
        // Cursor models pool; the third-party pool (`apiPercentUsed`) is left out.
        let auto = pools["autoPercentUsed"].double
        let total = pools["totalPercentUsed"].double
        let merged = plan?["isMerged"].bool == true
        let included = merged ? (total ?? auto) : (auto ?? total)
        let namedPool = !merged && auto != nil

        if let included {
            metrics.append(UsageMetric(
                id: weekly ? "cursor.weekly" : (namedPool ? "cursor.auto" : "cursor.total"),
                title: weekly ? "Weekly" : (namedPool ? "Grok & Composer" : "Included usage"),
                usedPercent: included,
                resetsAt: resetsAt,
                window: window
            ))
        } else if let limit = pools["limit"].double, limit > 0 {
            let spend = pools["totalSpend"].double ?? 0
            metrics.append(UsageMetric(
                id: weekly ? "cursor.weekly" : "cursor.total",
                title: weekly ? "Weekly" : "Included usage",
                usedPercent: spend / limit * 100,
                resetsAt: resetsAt,
                detail: "\(UsageFormat.dollars(spend / 100)) / \(UsageFormat.dollars(limit / 100))",
                window: window
            ))
        }

        // proto3 JSON drops `false`, so an absent flag means the plan does include Grok Bot usage.
        if let grokBot, grokBot["includedLimitZero"].bool != true, let percent = grokBot["usagePercent"].double {
            metrics.append(UsageMetric(
                id: "cursor.grokbot",
                title: "Grok Bot",
                usedPercent: percent,
                resetsAt: ISODate.parse(grokBot["nextResetTimestampUtc"].string),
                window: .weekly
            ))
        }
        return metrics
    }

    static func planName(plan: JSON?, grokBot: JSON?, membership: String?) -> String? {
        if let name = plan?["planInfo"]["planName"].string, !name.isEmpty { return name }
        if let name = grokBot?["cursorPlanName"].string, !name.isEmpty { return name }
        guard let membership, !membership.isEmpty else { return nil }
        return membership.capitalized
    }

    /// Connect JSON sends the proto enum as a name (`INCLUDED_USAGE_PERIOD_WEEKLY`) or as its number (`2`).
    private static func isWeekly(_ value: JSON) -> Bool {
        if value.string?.lowercased().contains("weekly") == true { return true }
        return value.double == 2
    }
}
