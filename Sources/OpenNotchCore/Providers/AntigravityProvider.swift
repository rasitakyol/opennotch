import Foundation

/// Antigravity model pools (Gemini models; Claude & GPT models), each with a 5-hour and a weekly limit,
/// read with the Google session that the Antigravity app and the `agy` CLI share.
///
/// The access token lives about an hour and is only read here: Antigravity renews it while the app or the
/// CLI runs, and OpenNotch never touches the refresh token.
public struct AntigravityProvider: UsageProvider {
    public let id = ProviderID.antigravity
    private let http: HTTPClient

    static let api = "https://cloudcode-pa.googleapis.com/v1internal"
    static let otherModels = "Other models"

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    static var tokenFile: String {
        LocalFiles.path(".gemini", "jetski-standalone-oauth-token")
    }

    public func detect() async -> Bool {
        LocalFiles.exists(Self.tokenFile)
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let data = LocalFiles.data(Self.tokenFile), let credentials = Self.parseCredentials(data) else {
            throw ProviderIssue.notConfigured
        }
        if let expiresAt = credentials.expiresAt, expiresAt <= Date().addingTimeInterval(30) {
            throw ProviderIssue.expired
        }

        async let summaryCall = http.json(request("retrieveUserQuotaSummary", body: "{}", token: credentials.accessToken))
        async let tierCall = try? http.json(request("loadCodeAssist", body: #"{"metadata":{"ideType":"ANTIGRAVITY"}}"#, token: credentials.accessToken))
        let metrics = Self.parse(quotaSummary: try await summaryCall)
        let tier = await tierCall

        guard !metrics.isEmpty else { throw ProviderIssue.unexpected("No usage limits found") }
        return ProviderSnapshot(provider: id, plan: tier.flatMap(Self.planName), metrics: metrics)
    }

    private func request(_ method: String, body: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(Self.api):\(method)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The backend only answers Antigravity clients (any other agent gets 403), so requests carry the
    /// installed app's identity.
    static var userAgent: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let version = Bundle(path: "/Applications/Antigravity.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return version.map { "antigravity/\($0) darwin/\(arch)" } ?? "antigravity"
    }

    struct Credentials: Sendable {
        let accessToken: String
        let expiresAt: Date?
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let json = try? JSON(data: data), let token = json["token"]["access_token"].string, !token.isEmpty else { return nil }
        return Credentials(accessToken: token, expiresAt: ISODate.parse(json["token"]["expiry"].string))
    }

    /// Gemini limits get a cell each; every other pool's limits share one cell titled with the pool.
    public static func parse(quotaSummary json: JSON) -> [UsageMetric] {
        var gemini: [UsageMetric] = []
        var others: [UsageMetric] = []

        for group in json["groups"].array {
            let name = group["displayName"].string ?? ""
            let buckets = group["buckets"].array.filter { $0["disabled"].bool != true }
            let bucketIDs = buckets.compactMap { $0["bucketId"].string }
            let isGemini = name.lowercased().hasPrefix("gemini") || bucketIDs.contains { $0.hasPrefix("gemini") }
            // "3p" buckets are the third-party models (Claude, GPT-OSS).
            let label = isGemini ? "Gemini" : (bucketIDs.contains { $0.hasPrefix("3p") } || name.isEmpty ? otherModels : name)
            // "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS" → the list itself.
            let models = group["description"].string.map { text in
                text.range(of: ":").map { String(text[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? text
            }

            var metrics: [UsageMetric] = []
            for bucket in buckets {
                guard let remaining = bucket["remainingFraction"].double else { continue }
                let window = window(bucket["window"].string)
                metrics.append(UsageMetric(
                    id: "antigravity.\(bucket["bucketId"].string ?? "\(label.lowercased()).\(window.rawValue)")",
                    title: "\(label) \(window.title.lowercased())",
                    usedPercent: (1 - min(max(remaining, 0), 1)) * 100,
                    // An untouched window reports "now + its length", which would restart on every refresh.
                    resetsAt: remaining < 1 ? ISODate.parse(bucket["resetTime"].string) : nil,
                    detail: isGemini ? nil : models,
                    window: window,
                    group: isGemini ? nil : label
                ))
            }
            metrics.sort { $0.window.sortOrder < $1.window.sortOrder }
            if isGemini { gemini += metrics } else { others += metrics }
        }
        return gemini + others
    }

    static func window(_ name: String?) -> UsageWindow {
        switch (name ?? "").lowercased() {
        case "5h": .fiveHour
        case "daily": .daily
        case "weekly": .weekly
        case "monthly": .monthly
        default: .other
        }
    }

    /// Google One plans arrive as a paid tier next to the base "free-tier".
    static func planName(_ json: JSON) -> String? {
        let tier = (json["paidTier"]["id"].string ?? json["currentTier"]["id"].string ?? "").lowercased()
        if tier.contains("ultra") { return "Ultra" }
        if tier.contains("pro") { return "Pro" }
        if tier.contains("standard") { return "Standard" }
        if tier.contains("enterprise") { return "Enterprise" }
        if tier.contains("free") { return "Free" }
        return nil
    }
}
