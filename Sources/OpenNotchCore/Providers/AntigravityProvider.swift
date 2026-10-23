import Foundation

/// Antigravity's Gemini pool: a 5-hour limit and a weekly limit. The third-party Other models pool is not shown.
///
/// The Antigravity app and the `agy` CLI share a Google session file, but its access token lives about an
/// hour and both renew it only in memory. Once the file has expired, OpenNotch asks the running app's local
/// server for the same summary instead. Neither path refreshes a token.
public struct AntigravityProvider: UsageProvider {
    public let id = ProviderID.antigravity
    public var keepsCachedReadingWhenUndetected: Bool { true }
    private let requestJSON: @Sendable (URLRequest) async throws -> JSON
    private let loadCredentials: @Sendable () -> Credentials?
    private let sessionFileExists: @Sendable () -> Bool
    private let findApp: @Sendable () async -> AppAvailability

    static let api = "https://cloudcode-pa.googleapis.com/v1internal"
    static let appService = "exa.language_server_pb.LanguageServerService"
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
            if sessionIssue == .notConfigured && sessionFileExists() {
                throw ProviderIssue.notConfigured
            }
            throw ProviderIssue.appNotRunning
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
                    credentialSource: app.credentialSource
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

    /// The local language server (inside Antigravity.app or Gemini.app's embedded `agy --hub`):
    /// where it listens and the CSRF token it expects in each request.
    struct RunningApp: Sendable, Equatable {
        struct Server: Sendable, Equatable {
            let pid: String
            let csrfToken: String?
            let ports: [Int]
            let credentialSource: String
        }

        let csrfToken: String
        let ports: [Int]
        var credentialSource: String = "Running Antigravity app"

        static func find(
            loadHTML: @Sendable (URL) async -> Data? = Self.fetchHTML
        ) async -> AppAvailability {
            guard let list = await ProcessRunner.run("/bin/ps", ["-axww", "-o", "pid=,ucomm=,command="]), list.status == 0 else {
                return .unavailable
            }
            let processes = String(decoding: list.stdout, as: UTF8.self)
            let candidates = servers(inProcessList: processes)
            guard !candidates.isEmpty else {
                return isAppRunning(inProcessList: processes) ? .unavailable : .notRunning
            }
            for server in candidates {
                let ports: [Int]
                if !server.ports.isEmpty {
                    ports = server.ports
                } else {
                    guard let sockets = await ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", server.pid, "-iTCP", "-sTCP:LISTEN"]),
                          sockets.status == 0
                    else { continue }
                    ports = loopbackPorts(lsofOutput: String(decoding: sockets.stdout, as: UTF8.self))
                }
                guard !ports.isEmpty else { continue }

                if let token = server.csrfToken {
                    return .running(RunningApp(csrfToken: token, ports: ports, credentialSource: server.credentialSource))
                }
                for port in ports {
                    guard let url = URL(string: "http://127.0.0.1:\(port)/"),
                          let data = await loadHTML(url),
                          let token = csrfToken(inHTML: String(decoding: data, as: UTF8.self))
                    else { continue }
                    return .running(RunningApp(csrfToken: token, ports: [port], credentialSource: server.credentialSource))
                }
            }
            return .unavailable
        }

        private static func fetchHTML(_ url: URL) async -> Data? {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            return data
        }

        static func isAppRunning(inProcessList text: String) -> Bool {
            if !servers(inProcessList: text).isEmpty { return true }
            return text.split(whereSeparator: \.isNewline).contains { line in
                let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard fields.count == 3 else { return false }
                // ucomm identifies the executable independently of spaces in its path or arguments.
                let executable = fields[1].lowercased()
                let command = fields[2].lowercased()
                return (executable == "antigravity" && command.contains("/antigravity.app/contents/macos/antigravity"))
                    || (executable.hasPrefix("language_server") && command.contains("antigravity"))
            }
        }

        static func languageServer(inProcessList text: String) -> Server? {
            servers(inProcessList: text).first
        }

        /// Finds Antigravity's standalone `language_server` (which receives `--csrf_token` on the command line)
        /// or Gemini.app's embedded `agy --hub` server (which exposes `--hub-port` and embeds its CSRF token in `GET /`).
        static func servers(inProcessList text: String) -> [Server] {
            var result: [Server] = []
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count > 2, let pid = fields.first else { continue }
                let executable = fields[1].lowercased()
                let lowerLine = line.lowercased()

                if executable.hasPrefix("language_server"),
                   lowerLine.contains("antigravity"),
                   let token = flagValue("--csrf_token", in: fields),
                   !token.isEmpty
                {
                    result.append(Server(
                        pid: String(pid),
                        csrfToken: token,
                        ports: [],
                        credentialSource: "Running Antigravity app"
                    ))
                } else if executable == "agy",
                          fields.contains(where: { $0 == "--hub" || $0.hasPrefix("--hub-port") })
                {
                    let token = flagValue("--csrf_token", in: fields).flatMap { $0.isEmpty ? nil : $0 }
                    let hubPort = flagValue("--hub-port", in: fields).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
                    let source = (lowerLine.contains("/gemini.app/") || fields.contains("--use_host_auth"))
                        ? "Running Gemini app"
                        : "Running Antigravity app"
                    result.append(Server(
                        pid: String(pid),
                        csrfToken: token,
                        ports: hubPort.map { [$0] } ?? [],
                        credentialSource: source
                    ))
                }
            }
            return result
        }

        private static func flagValue(_ name: String, in fields: [Substring]) -> String? {
            let prefix = "\(name)="
            for (index, field) in fields.enumerated() {
                if field == name, index + 1 < fields.count {
                    return String(fields[index + 1])
                }
                if field.hasPrefix(prefix) {
                    return String(field.dropFirst(prefix.count))
                }
            }
            return nil
        }

        /// `agy --hub` serves its generated CSRF token in `<script>window.__APP_CONFIG__ = {...};</script>`.
        static func csrfToken(inHTML text: String) -> String? {
            guard let marker = text.range(of: "window.__APP_CONFIG__"),
                  let start = text[marker.upperBound...].firstIndex(of: "{"),
                  let end = text[start...].range(of: "};")?.lowerBound,
                  let json = try? JSON(string: String(text[start...end])),
                  let token = json["csrfToken"].string,
                  !token.isEmpty
            else { return nil }
            return token
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

    /// Gemini's 5-hour and weekly limits, one cell each. Other model pools are left out.
    public static func parse(quotaSummary json: JSON) -> [UsageMetric] {
        var metrics: [UsageMetric] = []

        for group in json["groups"].array {
            let name = group["displayName"].string ?? ""
            let buckets = group["buckets"].array.filter { $0["disabled"].bool != true }
            let bucketIDs = buckets.compactMap { $0["bucketId"].string }
            let isGemini = name.lowercased().hasPrefix("gemini") || bucketIDs.contains { $0.hasPrefix("gemini") }
            guard isGemini else { continue }

            for bucket in buckets {
                guard let remaining = bucket["remainingFraction"].double else { continue }
                let window = window(bucket["window"].string)
                guard window == .fiveHour || window == .weekly else { continue }
                metrics.append(UsageMetric(
                    id: "antigravity.\(bucket["bucketId"].string ?? "gemini.\(window.rawValue)")",
                    title: window.title,
                    usedPercent: (1 - min(max(remaining, 0), 1)) * 100,
                    // An untouched window reports "now + its length", which would restart on every refresh.
                    resetsAt: remaining < 1 ? ISODate.parse(bucket["resetTime"].string) : nil,
                    window: window
                ))
            }
        }
        return metrics.sorted { $0.window.sortOrder < $1.window.sortOrder }
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
