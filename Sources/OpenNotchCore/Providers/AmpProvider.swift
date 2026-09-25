import Foundation

/// Amp tier pools (agent usage in dollars, orb usage in hours), read with the Amp CLI's API key.
///
/// Amp only exposes this through the same call `amp usage` makes, which returns display text,
/// so the numbers are parsed out of that text.
public struct AmpProvider: UsageProvider {
    public let id = ProviderID.amp
    private let http: HTTPClient

    static let defaultBase = URL(string: "https://ampcode.com/")!
    static let keyPrefix = "apiKey@"

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    static var secretsFile: String {
        LocalFiles.path(".local", "share", "amp", "secrets.json")
    }

    public func detect() async -> Bool {
        LocalFiles.exists(Self.secretsFile)
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let (key, base) = Self.loadCredentials() else { throw ProviderIssue.notConfigured }
        var components = URLComponents(url: base.appendingPathComponent("api/internal"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "userDisplayBalanceInfo"
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"method":"userDisplayBalanceInfo","params":{}}"#.utf8)

        let json = try await http.json(request)
        guard let text = json["result"]["displayText"].string else {
            throw ProviderIssue.unexpected("Usage text not found")
        }
        let parsed = Self.parse(displayText: text)
        guard !parsed.metrics.isEmpty else { throw ProviderIssue.unexpected("Unrecognized Amp usage format") }
        return ProviderSnapshot(provider: id, plan: parsed.plan, metrics: parsed.metrics, note: parsed.note)
    }

    static func loadCredentials() -> (String, URL)? {
        guard let secrets = LocalFiles.json(secretsFile)?.dictionary else { return nil }
        // Keys look like "apiKey@https://ampcode.com/"; prefer the public service when several exist.
        let entries = secrets
            .filter { $0.key.hasPrefix(keyPrefix) }
            .sorted { ($0.key.contains("ampcode.com") ? 0 : 1, $0.key) < ($1.key.contains("ampcode.com") ? 0 : 1, $1.key) }
        for (name, value) in entries {
            guard let key = value.string, !key.isEmpty else { continue }
            let base = URL(string: String(name.dropFirst(keyPrefix.count))) ?? defaultBase
            return (key, base)
        }
        return nil
    }

    public static func parse(displayText: String, now: Date = Date()) -> (plan: String?, metrics: [UsageMetric], note: String?) {
        let text = displayText.replacingOccurrences(of: "**", with: "")
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

        var note: String?
        if let credits = firstMatch(#"Individual credits:?\s*\$([\d,]+(?:\.\d+)?) remaining"#, in: text), let value = number(credits[0]) {
            note = "Credits \(UsageFormat.dollars(value))"
        }
        return (plan, metrics, note)
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
