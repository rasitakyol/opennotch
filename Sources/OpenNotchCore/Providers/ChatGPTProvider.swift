import Foundation

/// ChatGPT plan limits for Codex, read with the Codex CLI's ChatGPT sign-in.
/// Like Claude, the session is only read; Codex refreshes its own tokens.
public struct ChatGPTProvider: UsageProvider {
    public let id = ProviderID.chatgpt
    private let http: HTTPClient

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    static var authFile: String {
        let environment = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let base = (environment?.isEmpty == false) ? environment! : LocalFiles.path(".codex")
        return base + "/auth.json"
    }

    public func detect() async -> Bool {
        LocalFiles.exists(Self.authFile)
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let auth = LocalFiles.json(Self.authFile),
              let token = auth["tokens"]["access_token"].string, !token.isEmpty
        else { throw ProviderIssue.notConfigured }
        if JWT.isExpired(token) { throw ProviderIssue.expired }

        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account = auth["tokens"]["account_id"].string, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let json = try await http.json(request)

        let metrics = Self.parseUsage(json)
        guard !metrics.isEmpty else { throw ProviderIssue.unexpected("No usage limits found") }
        let planType = json["plan_type"].string
            ?? JWT.claims(token)?["https://api.openai.com/auth"]["chatgpt_plan_type"].string
        return ProviderSnapshot(provider: id, plan: Self.planName(planType), metrics: metrics)
    }

    public static func parseUsage(_ json: JSON, now: Date = Date()) -> [UsageMetric] {
        var metrics: [UsageMetric] = []

        func add(_ window: JSON, name: String?, idPrefix: String) {
            guard !window.isNull, let used = window["used_percent"].double else { return }
            let seconds = window["limit_window_seconds"].double
            let kind = UsageWindow(seconds: seconds)
            var base = kind.title
            if kind == .fiveHour, let seconds, abs(seconds - 18_000) > 600 {
                base = "\(max(1, Int((seconds / 3_600).rounded())))-hour"
            }
            let reset = ISODate.fromUnix(window["reset_at"].double)
                ?? window["reset_after_seconds"].double.map { now.addingTimeInterval($0) }
            metrics.append(UsageMetric(
                id: "\(idPrefix).\(kind.rawValue)",
                title: name.map { "\(base) · \($0)" } ?? base,
                usedPercent: used,
                resetsAt: reset,
                window: kind
            ))
        }

        let main = json["rate_limit"]
        add(main["primary_window"], name: nil, idPrefix: "chatgpt")
        add(main["secondary_window"], name: nil, idPrefix: "chatgpt")

        // Per-model limits, when the plan has any. Accepts both list and keyed-object shapes.
        let extras = json["additional_rate_limits"]
        var extraEntries: [(String?, JSON)] = extras.array.map { entry in
            (entry["limit_name"].string ?? entry["name"].string ?? entry["model"].string ?? entry["metered_feature"].string, entry)
        }
        if extraEntries.isEmpty {
            extraEntries = extras.dictionary.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        for (index, entry) in extraEntries.enumerated() {
            let limits = entry.1["rate_limit"].isNull ? entry.1 : entry.1["rate_limit"]
            add(limits["primary_window"], name: entry.0, idPrefix: "chatgpt.extra\(index)")
            add(limits["secondary_window"], name: entry.0, idPrefix: "chatgpt.extra\(index)")
        }

        return metrics.enumerated()
            .sorted { ($0.element.window.sortOrder, $0.offset) < ($1.element.window.sortOrder, $1.offset) }
            .map(\.element)
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }
}
