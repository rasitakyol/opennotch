import Foundation

/// Amp tier pools (agent usage in dollars, orb usage in hours), read with the Amp CLI's session.
/// Individual credits are not shown.
///
/// Amp's CLI stores either a long-lived API key or a short-lived (5-minute) OAuth JWT alongside
/// `oauth-refresh-token@...` in `~/.local/share/amp/secrets.json`. When the cached JWT has expired,
/// OpenNotch runs `amp usage` so the Amp CLI itself renews its session safely and returns the same
/// display text.
public struct AmpProvider: UsageProvider {
    public let id = ProviderID.amp
    private let requestJSON: @Sendable (URLRequest) async throws -> JSON
    private let secretsPath: @Sendable () -> String
    private let findCLI: @Sendable () -> String?
    private let runCLI: @Sendable (String) async -> ProcessRunner.Output?
    private let now: @Sendable () -> Date

    static let defaultBase = URL(string: "https://ampcode.com/")!
    static let keyPrefix = "apiKey@"
    static let refreshPrefix = "oauth-refresh-token@"

    struct Credentials: Sendable, Equatable {
        let apiKey: String?
        let hasRefreshToken: Bool
        let base: URL
    }

    public init(http: HTTPClient = .shared) {
        self.init(
            requestJSON: { try await http.json($0) },
            secretsPath: { Self.secretsFile },
            findCLI: { Self.locateCLI() },
            runCLI: { cli in await ProcessRunner.run(cli, ["usage"], environment: Self.cliEnvironment(), timeout: 15) },
            now: { Date() }
        )
    }

    init(
        requestJSON: @escaping @Sendable (URLRequest) async throws -> JSON,
        secretsPath: @escaping @Sendable () -> String,
        findCLI: @escaping @Sendable () -> String?,
        runCLI: @escaping @Sendable (String) async -> ProcessRunner.Output?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.requestJSON = requestJSON
        self.secretsPath = secretsPath
        self.findCLI = findCLI
        self.runCLI = runCLI
        self.now = now
    }

    static var secretsFile: String {
        LocalFiles.path(".local", "share", "amp", "secrets.json")
    }

    public func detect() async -> Bool {
        LocalFiles.exists(secretsPath())
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let credentials = Self.loadCredentials(from: secretsPath()) else {
            throw ProviderIssue.notConfigured
        }

        let currentTime = now()
        if let key = credentials.apiKey, !JWT.isExpired(key, now: currentTime) {
            do {
                return try await fetchViaHTTP(apiKey: key, base: credentials.base, now: currentTime)
            } catch ProviderIssue.unauthorized where credentials.hasRefreshToken || JWT.expiry(key) != nil {
                // Short-lived OAuth JWT was rejected (e.g. slight clock skew); let `amp usage` renew it.
            }
        }

        guard credentials.hasRefreshToken || credentials.apiKey.flatMap(JWT.expiry) != nil else {
            throw ProviderIssue.notConfigured
        }
        return try await fetchViaCLI(now: currentTime)
    }

    private func fetchViaHTTP(apiKey: String, base: URL, now: Date) async throws -> ProviderSnapshot {
        var components = URLComponents(url: base.appendingPathComponent("api/internal"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "userDisplayBalanceInfo"
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"method":"userDisplayBalanceInfo","params":{}}"#.utf8)

        let json = try await requestJSON(request)
        guard let text = json["result"]["displayText"].string else {
            throw ProviderIssue.unexpected("Usage text not found")
        }
        return try makeSnapshot(displayText: text, credentialSource: "Amp CLI session", now: now)
    }

    private func fetchViaCLI(now: Date) async throws -> ProviderSnapshot {
        guard let cli = findCLI() else {
            throw ProviderIssue.expired
        }
        guard let output = await runCLI(cli) else {
            throw ProviderIssue.timeout
        }
        let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
        if output.status == 0 {
            return try makeSnapshot(displayText: stdout, credentialSource: "Amp CLI", now: now)
        }

        let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
        let combined = "\(stdout)\n\(stderr)".lowercased()
        if combined.contains("amp login")
            || combined.contains("not logged in")
            || combined.contains("not signed in")
            || combined.contains("authentication failed")
            || combined.contains("session expired")
        {
            throw ProviderIssue.unauthorized
        }
        if combined.contains("enotfound")
            || combined.contains("econnrefused")
            || combined.contains("etimedout")
            || combined.contains("fetch failed")
            || combined.contains("network")
            || combined.contains("offline")
        {
            throw ProviderIssue.offline
        }
        throw ProviderIssue.unexpected("amp usage exited with status \(output.status)")
    }

    private func makeSnapshot(displayText: String, credentialSource: String, now: Date) throws -> ProviderSnapshot {
        let parsed = Self.parse(displayText: displayText, now: now)
        guard !parsed.metrics.isEmpty else {
            throw ProviderIssue.unexpected("Unrecognized Amp usage format")
        }
        return ProviderSnapshot(
            provider: id,
            plan: parsed.plan,
            metrics: parsed.metrics,
            balance: parsed.balance,
            credentialSource: credentialSource
        )
    }

    static func loadCredentials(from path: String = secretsFile) -> Credentials? {
        guard let secrets = LocalFiles.json(path)?.dictionary else { return nil }
        var bases = Set<String>()
        for (name, value) in secrets {
            guard let str = value.string, !str.isEmpty else { continue }
            if name.hasPrefix(keyPrefix) {
                bases.insert(String(name.dropFirst(keyPrefix.count)))
            } else if name.hasPrefix(refreshPrefix) {
                bases.insert(String(name.dropFirst(refreshPrefix.count)))
            }
        }
        // Keys look like "apiKey@https://ampcode.com/"; prefer the public service when several exist.
        let ordered = bases.sorted { ($0.contains("ampcode.com") ? 0 : 1, $0) < ($1.contains("ampcode.com") ? 0 : 1, $1) }
        for rawBase in ordered {
            let apiKey = secrets[keyPrefix + rawBase]?.string.flatMap { $0.isEmpty ? nil : $0 }
            let refresh = secrets[refreshPrefix + rawBase]?.string.flatMap { $0.isEmpty ? nil : $0 }
            guard apiKey != nil || refresh != nil else { continue }
            let base = URL(string: rawBase) ?? defaultBase
            return Credentials(apiKey: apiKey, hasRefreshToken: refresh != nil, base: base)
        }
        return nil
    }

    static func locateCLI() -> String? {
        var candidates: [String] = []
        if let custom = UserDefaults(suiteName: "com.ampcode.amp.macos")?.string(forKey: "runnerCLIPath")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty
        {
            candidates.append((custom as NSString).expandingTildeInPath)
        }
        candidates.append(contentsOf: [
            LocalFiles.path(".local", "bin", "amp"),
            "/opt/homebrew/bin/amp",
            "/usr/local/bin/amp",
            LocalFiles.path(".amp", "bin", "amp"),
        ])
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
                candidates.append("\(dir)/amp")
            }
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func cliEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        let standard = [
            LocalFiles.path(".local", "bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged = standard
        for entry in existing where !merged.contains(entry) {
            merged.append(entry)
        }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    public static func parse(displayText: String, now: Date = Date()) -> (plan: String?, metrics: [UsageMetric], balance: UsageBalance?) {
        let stripped = displayText.replacingOccurrences(of: #"\u{001B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        let text = stripped.replacingOccurrences(of: "**", with: "")
        var metrics: [UsageMetric] = []
        var plan: String?

        let periodEnd = firstMatch(#"period \d{4}-\d{2}-\d{2} to (\d{4}-\d{2}-\d{2})"#, in: text).flatMap { dayStart($0[0]) }
        let renewal = firstMatch(#"renewal in (\d+) days?"#, in: text).flatMap { Double($0[0]) }.map { now.addingTimeInterval($0 * 86_400) }
        let tierReset = periodEnd ?? renewal

        if let tier = firstMatch(#"Amp ([A-Za-z0-9][A-Za-z0-9 ]*?) Tier"#, in: text) {
            plan = tier[0]
        }

        if let agent = firstMatch(#"agent usage \$([\d,]+(?:\.\d+)?) of \$([\d,]+(?:\.\d+)?) remaining"#, in: text),
           let remaining = number(agent[0]), let limit = number(agent[1]), limit > 0 {
            metrics.append(UsageMetric(
                id: "amp.agent",
                title: "AI model",
                usedPercent: (limit - remaining) / limit * 100,
                resetsAt: tierReset,
                detail: "\(UsageFormat.dollars(remaining)) / \(UsageFormat.dollars(limit)) left",
                window: .monthly
            ))
        }

        if let orb = firstMatch(#"orb usage ([\d,]+(?:\.\d+)?)h of ([\d,]+(?:\.\d+)?)h"#, in: text),
           let remaining = number(orb[0]), let limit = number(orb[1]), limit > 0 {
            metrics.append(UsageMetric(
                id: "amp.orb",
                title: "Orb",
                usedPercent: (limit - remaining) / limit * 100,
                resetsAt: tierReset,
                detail: "\(UsageFormat.number(remaining)) / \(UsageFormat.number(limit)) h left",
                window: .monthly
            ))
        }

        // Free tier: "Amp Free: $7.20/$10 remaining (replenishes +$0.42/hour)".
        if let free = firstMatch(#"Amp Free:?\s*\$([\d,]+(?:\.\d+)?)\s*/\s*\$([\d,]+(?:\.\d+)?) remaining"#, in: text),
           let remaining = number(free[0]), let limit = number(free[1]), limit > 0 {
            plan = plan ?? "Free"
            var refill: Date?
            if let rate = firstMatch(#"replenishes \+\$([\d.]+)/hour"#, in: text).flatMap({ number($0[0]) }), rate > 0 {
                refill = now.addingTimeInterval(max(0, limit - remaining) / rate * 3_600)
            }
            metrics.append(UsageMetric(
                id: "amp.free",
                title: "Amp Free",
                usedPercent: (limit - remaining) / limit * 100,
                resetsAt: remaining < limit ? refill : nil,
                detail: "\(UsageFormat.dollars(remaining)) / \(UsageFormat.dollars(limit)) left",
                window: .daily
            ))
        }

        return (plan, metrics, nil)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private static func dayStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
