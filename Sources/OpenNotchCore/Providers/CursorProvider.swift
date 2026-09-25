import Foundation

/// Cursor plan pools (Cursor models = Cursor Grok & Composer, other models) and Grok Bot, read with the
/// session of the Cursor IDE or the Grok Bot app (both sign into the same Cursor account).
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
        async let grokBotCall = try? http.connect(Self.api.appendingPathComponent("GetSandUsageStatus"), bearer: token)
        let usage = try await usageCall
        let grokBot = await grokBotCall

        let metrics = Self.parse(usage: usage, grokBot: grokBot)
        guard !metrics.isEmpty else { throw ProviderIssue.unexpected("No usage data found") }
        let plan = grokBot?["cursorPlanName"].string
            ?? SQLiteKV.value(forKey: "cursorAuth/stripeMembershipType", databaseAt: Self.ideDatabase)?.capitalized
        return ProviderSnapshot(provider: id, plan: plan, metrics: metrics)
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

    public static func parse(usage: JSON, grokBot: JSON?) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        let cycleEnd = ISODate.fromUnix(usage["billingCycleEnd"].double)
        let plan = usage["planUsage"]

        if let auto = plan["autoPercentUsed"].double {
            metrics.append(UsageMetric(id: "cursor.auto", title: "Grok & Composer", usedPercent: auto, resetsAt: cycleEnd, window: .monthly))
        }
        if let api = plan["apiPercentUsed"].double {
            metrics.append(UsageMetric(id: "cursor.api", title: "Other models", usedPercent: api, resetsAt: cycleEnd, window: .monthly))
        }
        if metrics.isEmpty {
            if let total = plan["totalPercentUsed"].double {
                metrics.append(UsageMetric(id: "cursor.total", title: "Included usage", usedPercent: total, resetsAt: cycleEnd, window: .monthly))
            } else if let limit = plan["limit"].double, limit > 0 {
                let spend = plan["totalSpend"].double ?? 0
                metrics.append(UsageMetric(
                    id: "cursor.total",
                    title: "Included usage",
                    usedPercent: spend / limit * 100,
                    resetsAt: cycleEnd,
                    detail: "\(UsageFormat.dollars(spend / 100)) / \(UsageFormat.dollars(limit / 100))",
                    window: .monthly
                ))
            }
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
}
