import Foundation
import os

/// Cursor included usage, read with the session of the Cursor IDE or the Grok Bot app (both sign into
/// the same account).
///
/// The IDE token is tried first when both expire together. If that session is rejected, Grok Bot's
/// active account is next, then any other saved Grok Bot account. Encrypted copies are unwrapped
/// with the app's own Keychain key. Refresh tokens are never read.
///
/// The X Subscription has one weekly pool for Grok, Grok Bot, and Cursor. A separate Grok Bot quota is
/// shown only when that allowance still comes from a SuperGrok plan that has not moved onto it.
/// The third-party Other models pool is not shown.
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
        let material = await Self.loadMaterial()
        return try await CursorSessions.resolve(material) { candidate in
            try await self.snapshot(using: candidate)
        }
    }

    private func snapshot(using candidate: CursorSessions.Candidate) async throws -> ProviderSnapshot {
        let token = candidate.token
        async let usageCall = http.connect(Self.api.appendingPathComponent("GetCurrentPeriodUsage"), bearer: token)
        async let planCall = try? http.connect(Self.api.appendingPathComponent("GetPlanInfo"), bearer: token)
        async let grokBotCall = try? http.connect(Self.api.appendingPathComponent("GetSandUsageStatus"), bearer: token)
        let usage = try await usageCall
        let plan = await planCall
        let grokBot = await grokBotCall

        let metrics = Self.parse(usage: usage, grokBot: grokBot, plan: plan)
        guard !metrics.isEmpty else { throw ProviderIssue.unexpected("No usage data found") }
        let membership = SQLiteKV.value(forKey: "cursorAuth/stripeMembershipType", databaseAt: Self.ideDatabase)
        return ProviderSnapshot(
            provider: id,
            plan: Self.planName(plan: plan, grokBot: grokBot, membership: membership),
            metrics: metrics,
            credentialSource: candidate.source
        )
    }

    private static func loadMaterial() async -> CursorSessions.Material {
        let ide = SQLiteKV.value(forKey: "cursorAuth/accessToken", databaseAt: ideDatabase)
        let secrets = LocalFiles.json(grokBotSecrets)
        async let cursorPassword = CursorSafeStorage.password(
            needed: CursorSessions.isSealed(ide),
            service: "Cursor Safe Storage",
            accounts: ["Cursor Key", "Cursor"],
            reason: "Read Cursor usage limits in OpenNotch"
        )
        async let grokPassword = CursorSafeStorage.password(
            needed: grokSecretsNeedsKey(secrets),
            service: "Grok Bot Safe Storage",
            accounts: ["Grok Bot Key", "Grok Bot"],
            reason: "Read Grok Bot usage limits in OpenNotch"
        )
        return CursorSessions.material(
            ideValue: ide,
            grokSecrets: secrets,
            decryptCursor: CursorSafeStorage.decrypt(await cursorPassword),
            decryptGrok: CursorSafeStorage.decrypt(await grokPassword)
        )
    }

    private static func grokSecretsNeedsKey(_ secrets: JSON?) -> Bool {
        guard let secrets else { return false }
        if CursorSessions.isSealed(secrets["cursor-access-token"].string) { return true }
        guard let accountsText = secrets["cursor-accounts"].string,
              let accounts = try? JSON(string: accountsText) else { return false }
        return accounts["accounts"].dictionary.values.contains {
            CursorSessions.isSealed($0["cursor-access-token"].string)
        }
    }

    /// `plan` is `GetPlanInfo`. A weekly included period, or `isUnified` on the Grok Bot status, means
    /// The X Subscription's single pool.
    public static func parse(usage: JSON, grokBot: JSON?, plan: JSON? = nil) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        let info = plan.map { $0["planInfo"] }
        let weekly = info.map { Self.isWeekly($0["includedUsagePeriod"]) } ?? false
        let sharedPool = weekly || grokBot?["isUnified"].bool == true
        let cycleEnd = ISODate.fromUnix(usage["billingCycleEnd"].double)
            ?? info.flatMap { ISODate.fromUnix($0["billingCycleEnd"].double) }
        let grokReset = ISODate.parse(grokBot?["nextResetTimestampUtc"].string)
        let resetsAt = sharedPool
            ? (info.flatMap { ISODate.fromUnix($0["includedUsageResetsAt"].double) } ?? grokReset ?? cycleEnd)
            : cycleEnd
        let window: UsageWindow = sharedPool ? .weekly : .monthly
        let pools = usage["planUsage"]

        // The shared pool is the whole included amount. Otherwise the figure is the Cursor models pool.
        // The third-party pool (`apiPercentUsed`) is left out in either case.
        let auto = pools["autoPercentUsed"].double
        let total = pools["totalPercentUsed"].double
        let merged = plan?["isMerged"].bool == true
        let grokPercent = Self.grokBotPercent(grokBot)
        let included = sharedPool ? (total ?? grokPercent ?? auto) : (merged ? (total ?? auto) : (auto ?? total))
        let namedPool = !sharedPool && !merged && auto != nil

        if let included {
            metrics.append(UsageMetric(
                id: sharedPool ? "cursor.weekly" : (namedPool ? "cursor.auto" : "cursor.total"),
                title: sharedPool ? "Weekly" : (namedPool ? "Grok & Composer" : "Included usage"),
                usedPercent: included,
                resetsAt: resetsAt,
                window: window
            ))
        } else if let limit = pools["limit"].double, limit > 0 {
            let spend = pools["totalSpend"].double ?? 0
            metrics.append(UsageMetric(
                id: sharedPool ? "cursor.weekly" : "cursor.total",
                title: sharedPool ? "Weekly" : "Included usage",
                usedPercent: spend / limit * 100,
                resetsAt: resetsAt,
                detail: "\(UsageFormat.dollars(spend / 100)) / \(UsageFormat.dollars(limit / 100))",
                window: window
            ))
        }

        // proto3 JSON drops `false`, so an absent flag means this separate allowance includes usage.
        if !sharedPool, let percent = grokPercent {
            metrics.append(UsageMetric(
                id: "cursor.grokbot",
                title: "Grok Bot",
                usedPercent: percent,
                resetsAt: grokReset,
                window: .weekly
            ))
        }
        return metrics
    }

    /// Grok Bot's own meter. On The X Subscription this is the same weekly pool, so the caller shows it once.
    private static func grokBotPercent(_ grokBot: JSON?) -> Double? {
        guard let grokBot, grokBot["includedLimitZero"].bool != true else { return nil }
        return grokBot["usagePercent"].double
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

/// Electron safe-storage password for Cursor or Grok Bot. The password stays in memory for this process.
enum CursorSafeStorage {
    private static let passwords = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private static let prompted = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func password(needed: Bool, service: String, accounts: [String], reason: String) async -> String? {
        guard needed else { return nil }
        for account in accounts {
            if let password = await password(service: service, account: account, reason: reason) {
                return password
            }
        }
        return nil
    }

    static func decrypt(_ password: String?) -> @Sendable (Data) -> String? {
        guard let password, !password.isEmpty else { return { _ in nil } }
        return { data in
            guard let clear = ClaudeDesktopCredentials.decrypt(data, password: password),
                  let text = String(data: clear, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
    }

    private static func password(service: String, account: String, reason: String) async -> String? {
        let key = "\(service)\n\(account)"
        if let cached = passwords.withLock({ $0[key] }) { return cached }

        let silent = await DesktopKeychain.readData(service: service, account: account, interaction: .forbidden, reason: reason)
        let result: DesktopKeychain.ReadResult
        switch silent {
        case .success:
            result = silent
        case .unavailable:
            return nil
        case .interactionRequired:
            let shouldPrompt = prompted.withLock { asked -> Bool in
                guard !asked.contains(key) else { return false }
                asked.insert(key)
                return true
            }
            guard shouldPrompt else { return nil }
            result = await DesktopKeychain.readData(service: service, account: account, interaction: .userInitiated, reason: reason)
        }

        guard case .success(let data) = result,
              let password = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty else { return nil }
        passwords.withLock { $0[key] = password }
        return password
    }
}
