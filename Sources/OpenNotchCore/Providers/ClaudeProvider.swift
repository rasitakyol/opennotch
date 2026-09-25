import Foundation

/// Claude subscription limits, read with Claude Code's own OAuth session.
///
/// The token is only read. It is never refreshed here: Claude Code rotates refresh tokens, so
/// refreshing from a second process could sign the user out of Claude Code.
public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    private let http: HTTPClient

    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    struct Credentials: Sendable {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    static var credentialFiles: [String] {
        var files: [String] = []
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            files.append(configDir + "/.credentials.json")
        }
        files.append(LocalFiles.path(".claude", ".credentials.json"))
        return files
    }

    public func detect() async -> Bool {
        if Self.credentialFiles.contains(where: LocalFiles.exists) { return true }
        return await Keychain.hasGenericPassword(service: Self.keychainService)
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let credentials = await loadCredentials() else { throw ProviderIssue.notConfigured }
        if let expiresAt = credentials.expiresAt, expiresAt <= Date().addingTimeInterval(30) {
            throw ProviderIssue.expired
        }

        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let json = try await http.json(request)

        let metrics = Self.parseUsage(json)
        guard !metrics.isEmpty else { throw ProviderIssue.unexpected("No usage limits found") }
        return ProviderSnapshot(
            provider: id,
            plan: Self.planName(subscription: credentials.subscriptionType, tier: credentials.rateLimitTier),
            metrics: metrics
        )
    }

    /// Keychain is where current Claude Code versions keep the session; the JSON file is the older/Linux location.
    /// Whichever is freshest wins, so a stale leftover file never shadows a valid keychain token.
    private func loadCredentials() async -> Credentials? {
        var candidates: [Credentials] = []
        if let secret = await Keychain.genericPassword(service: Self.keychainService),
           let credentials = Self.parseCredentials(Data(secret.utf8)) {
            candidates.append(credentials)
        }
        for file in Self.credentialFiles {
            if let data = LocalFiles.data(file), let credentials = Self.parseCredentials(data) {
                candidates.append(credentials)
            }
        }
        return candidates.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let json = try? JSON(data: data) else { return nil }
        let oauth = json["claudeAiOauth"]
        guard let token = oauth["accessToken"].string, !token.isEmpty else { return nil }
        return Credentials(
            accessToken: token,
            expiresAt: ISODate.fromUnix(oauth["expiresAt"].double),
            subscriptionType: oauth["subscriptionType"].string,
            rateLimitTier: oauth["rateLimitTier"].string
        )
    }

    /// Prefers the generic `limits` list (session, weekly, per-model weekly such as Fable) and
    /// falls back to the older fixed keys when it is missing.
    public static func parseUsage(_ json: JSON) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        var seen = Set<String>()
        func add(_ metric: UsageMetric) {
            guard seen.insert(metric.id).inserted else { return }
            metrics.append(metric)
        }

        for entry in json["limits"].array {
            guard let percent = entry["percent"].double else { continue }
            let kind = (entry["kind"].string ?? "").lowercased()
            let group = (entry["group"].string ?? "").lowercased()
            let reset = ISODate.parse(entry["resets_at"].string)
            let scope = entry["scope"]
            let scopeName = scope["model"]["display_name"].string
                ?? scope["surface"]["display_name"].string
                ?? scope["model"]["id"].string

            let window: UsageWindow
            if kind.contains("session") || group == "session" {
                window = .fiveHour
            } else if kind.contains("weekly") || group == "weekly" {
                window = .weekly
            } else if kind.contains("daily") || group == "daily" {
                window = .daily
            } else if kind.contains("monthly") || group == "monthly" {
                window = .monthly
            } else {
                continue
            }

            if let scopeName, !scopeName.isEmpty {
                add(UsageMetric(
                    id: "claude.\(window.rawValue).\(scopeName.lowercased())",
                    title: "\(window.title) · \(scopeName)",
                    usedPercent: percent,
                    resetsAt: reset,
                    window: window
                ))
            } else {
                add(UsageMetric(id: "claude.\(window.rawValue)", title: window.title, usedPercent: percent, resetsAt: reset, window: window))
            }
        }

        if metrics.isEmpty {
            let legacy: [(key: String, title: String, window: UsageWindow)] = [
                ("five_hour", UsageWindow.fiveHour.title, .fiveHour),
                ("seven_day", UsageWindow.weekly.title, .weekly),
                ("seven_day_opus", "Weekly · Opus", .weekly),
                ("seven_day_sonnet", "Weekly · Sonnet", .weekly),
            ]
            for item in legacy {
                let bucket = json[item.key]
                guard let utilization = bucket["utilization"].double else { continue }
                add(UsageMetric(
                    id: "claude.\(item.key)",
                    title: item.title,
                    usedPercent: utilization,
                    resetsAt: ISODate.parse(bucket["resets_at"].string),
                    window: item.window
                ))
            }
        }
        return metrics
    }

    static func planName(subscription: String?, tier: String?) -> String? {
        let tier = (tier ?? "").lowercased()
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        switch (subscription ?? "").lowercased() {
        case "": return nil
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case let other: return other.capitalized
        }
    }
}
