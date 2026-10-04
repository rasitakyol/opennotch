import Foundation

/// Antigravity model pools (Gemini models; Claude & GPT models), each with a 5-hour and a weekly limit.
///
/// The Antigravity app and the `agy` CLI share a Google session file, but its access token lives about an
/// hour and both renew it only in memory. Once the file has expired, OpenNotch asks the running app's local
/// server for the same summary instead. Neither path refreshes a token.
public struct AntigravityProvider: UsageProvider {
    public let id = ProviderID.antigravity
    private let requestJSON: @Sendable (URLRequest) async throws -> JSON
    private let loadCredentials: @Sendable () -> Credentials?
    private let sessionFileExists: @Sendable () -> Bool
    private let findApp: @Sendable () async -> AppAvailability

    static let api = "https://cloudcode-pa.googleapis.com/v1internal"
    static let appService = "exa.language_server_pb.LanguageServerService"
    static let otherModels = "Other models"

    public init(http: HTTPClient = .shared) {
        self.init(
            requestJSON: { try await http.json($0) },
            loadCredentials: { LocalFiles.data(Self.tokenFile).flatMap(Self.parseCredentials) },
            sessionFileExists: { LocalFiles.exists(Self.tokenFile) },
            findApp: { await RunningApp.find() }
        )
    }

    init(
        requestJSON: @escaping @Sendable (URLRequest) async throws -> JSON,
        loadCredentials: @escaping @Sendable () -> Credentials?,
        sessionFileExists: @escaping @Sendable () -> Bool = { false },
        findApp: @escaping @Sendable () async -> AppAvailability
    ) {
        self.requestJSON = requestJSON
        self.loadCredentials = loadCredentials
        self.sessionFileExists = sessionFileExists
        self.findApp = findApp
    }

    static var tokenFile: String {
        LocalFiles.path(".gemini", "jetski-standalone-oauth-token")
    }

    public func detect() async -> Bool {
        if sessionFileExists() { return true }
        if case .running = await findApp() { return true }
        return false
    }

    public func fetch() async throws -> ProviderSnapshot {
        let sessionIssue: ProviderIssue
        if let credentials = loadCredentials() {
            if let expiresAt = credentials.expiresAt, expiresAt <= Date().addingTimeInterval(30) {
                sessionIssue = .expired
            } else {
                do {
                    return try await fetchFromGoogle(token: credentials.accessToken)
                } catch ProviderIssue.unauthorized {
                    sessionIssue = .unauthorized
                }
            }
        } else {
            sessionIssue = .notConfigured
        }
        // Only a missing or stale session switches source; network errors and rate limits stay as they are.
        switch await findApp() {
        case .notRunning:
            throw sessionIssue == .notConfigured ? ProviderIssue.notConfigured : .appNotRunning
        case .unavailable:
            throw ProviderIssue.appUnavailable
        case .running(let app):
            return try await fetchFromApp(app)
        }
    }

    private func fetchFromGoogle(token: String) async throws -> ProviderSnapshot {
        async let summaryCall = requestJSON(googleRequest("retrieveUserQuotaSummary", body: "{}", token: token))
        async let tierCall = try? requestJSON(googleRequest("loadCodeAssist", body: #"{"metadata":{"ideType":"ANTIGRAVITY"}}"#, token: token))
        let metrics = Self.parse(quotaSummary: try await summaryCall)
        let tier = await tierCall

        guard !metrics.isEmpty else { throw ProviderIssue.unexpected("No usage limits found") }
        return ProviderSnapshot(provider: id, plan: tier.flatMap(Self.planName), metrics: metrics, credentialSource: "Antigravity session (~/.gemini)")
    }

    /// The app's server listens on two loopback ports and only one speaks plain HTTP, so each is tried.
    private func fetchFromApp(_ app: RunningApp) async throws -> ProviderSnapshot {
        var lastIssue = ProviderIssue.appUnavailable
        for port in app.ports {
            // Without forceRefresh the app answers with the reading it took at launch.
            do {
                let summary = try await requestJSON(appRequest("RetrieveUserQuotaSummary", body: #"{"forceRefresh":true}"#, port: port, app: app))
                let metrics = Self.parse(quotaSummary: summary["response"])
                guard !metrics.isEmpty else {
                    lastIssue = .unexpected("Antigravity returned no usage limits. Reopen the app and refresh OpenNotch.")
                    continue
                }
                let tier = try? await requestJSON(appRequest("GetLoadCodeAssist", body: "{}", port: port, app: app))
                return ProviderSnapshot(
                    provider: id,
                    plan: tier.flatMap { Self.planName($0["response"]) },
                    metrics: metrics,
                    credentialSource: "Running Antigravity app"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let issue as ProviderIssue {
                // A TLS-only port can reject HTTP; it must not hide a useful failure from the HTTP port.
                if issue != .server(status: 400) && issue != .offline { lastIssue = issue }
            } catch {
                lastIssue = .appUnavailable
            }
        }
        throw lastIssue
    }

    private func googleRequest(_ method: String, body: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(Self.api):\(method)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func appRequest(_ method: String, body: String, port: Int, app: RunningApp) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(Self.appService)/\(method)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(app.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
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

    enum AppAvailability: Sendable {
        case notRunning
        case unavailable
        case running(RunningApp)
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let json = try? JSON(data: data), let token = json["token"]["access_token"].string, !token.isEmpty else { return nil }
        return Credentials(accessToken: token, expiresAt: ISODate.parse(json["token"]["expiry"].string))
    }

    /// The Antigravity app's local language server: where it listens and the token it expects in each request.
    struct RunningApp: Sendable, Equatable {
        let csrfToken: String
        let ports: [Int]

        static func find() async -> AppAvailability {
            guard let list = await ProcessRunner.run("/bin/ps", ["-axww", "-o", "pid=,command="]), list.status == 0 else {
                return .unavailable
            }
            let processes = String(decoding: list.stdout, as: UTF8.self)
            guard let server = languageServer(inProcessList: processes) else {
                return isAppRunning(inProcessList: processes) ? .unavailable : .notRunning
            }
            guard let sockets = await ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", server.pid, "-iTCP", "-sTCP:LISTEN"]), sockets.status == 0 else {
                return .unavailable
            }
            let ports = loopbackPorts(lsofOutput: String(decoding: sockets.stdout, as: UTF8.self))
            return ports.isEmpty ? .unavailable : .running(RunningApp(csrfToken: server.csrfToken, ports: ports))
        }

        static func isAppRunning(inProcessList text: String) -> Bool {
            text.split(whereSeparator: \.isNewline).contains { line in
                let fields = line.split(separator: " ")
                guard fields.count > 1 else { return false }
                let executable = fields[1].lowercased()
                return executable.hasSuffix("/antigravity.app/contents/macos/antigravity")
                    || (executable.split(separator: "/").last?.hasPrefix("language_server") == true
                        && line.lowercased().contains("antigravity"))
            }
        }

        /// The app hands its server a new CSRF token on the command line at every launch.
        static func languageServer(inProcessList text: String) -> (pid: String, csrfToken: String)? {
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ")
                guard fields.count > 1,
                      fields[1].split(separator: "/").last?.hasPrefix("language_server") == true,
                      line.lowercased().contains("antigravity"),
                      let pid = fields.first else { continue }
                for (index, field) in fields.enumerated() {
                    if field == "--csrf_token", index + 1 < fields.count {
                        return (String(pid), String(fields[index + 1]))
                    }
                    if field.hasPrefix("--csrf_token=") {
                        return (String(pid), String(field.dropFirst("--csrf_token=".count)))
                    }
                }
            }
            return nil
        }

        /// Ports from `lsof -nP -iTCP -sTCP:LISTEN` lines such as "… TCP 127.0.0.1:63194 (LISTEN)", loopback only.
        static func loopbackPorts(lsofOutput text: String) -> [Int] {
            text.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: " ")
                guard fields.last == "(LISTEN)", fields.count >= 2 else { return nil }
                let address = fields[fields.count - 2]
                guard address.hasPrefix("127.0.0.1:") || address.hasPrefix("[::1]:"),
                      let colon = address.lastIndex(of: ":")
                else { return nil }
                return Int(address[address.index(after: colon)...])
            }
        }
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
