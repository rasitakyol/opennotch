import Foundation

/// Devin plan quota (weekly, plus daily when the plan exposes it), read with the Devin CLI key or the
/// Devin Desktop (formerly Windsurf) session.
public struct DevinProvider: UsageProvider {
    public let id = ProviderID.devin
    private let http: HTTPClient

    static let defaultServer = URL(string: "https://server.codeium.com")!
    static let userStatusPath = "exa.seat_management_pb.SeatManagementService/GetUserStatus"

    struct Credentials: Sendable {
        let apiKey: String
        let server: URL
    }

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    static var cliCredentials: String {
        LocalFiles.path(".local", "share", "devin", "credentials.toml")
    }

    static var desktopDatabases: [String] {
        ["Devin", "Windsurf"].map {
            LocalFiles.path("Library", "Application Support", $0, "User", "globalStorage", "state.vscdb")
        }
    }

    public func detect() async -> Bool {
        LocalFiles.exists(Self.cliCredentials) || Self.desktopDatabases.contains(where: LocalFiles.exists)
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let credentials = Self.loadCredentials() else { throw ProviderIssue.notConfigured }
        let body: [String: Any] = [
            "metadata": [
                "apiKey": credentials.apiKey,
                "ideName": "opennotch",
                "ideVersion": AppInfo.version,
                "extensionName": "opennotch",
                "extensionVersion": AppInfo.version,
                "locale": "tr",
            ],
        ]
        let json = try await http.connect(
            credentials.server.appendingPathComponent(Self.userStatusPath),
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let parsed = Self.parse(json)
        guard !parsed.metrics.isEmpty else { throw ProviderIssue.unexpected("No quota data found") }
        return ProviderSnapshot(provider: id, plan: parsed.plan, metrics: parsed.metrics, balance: parsed.balance)
    }

    static func loadCredentials() -> Credentials? {
        if let text = LocalFiles.data(cliCredentials).flatMap({ String(data: $0, encoding: .utf8) }) {
            let values = SimpleTOML.parse(text)
            if let key = values["windsurf_api_key"] ?? values["api_key"], !key.isEmpty {
                let server = values["api_server_url"].flatMap(URL.init(string:)) ?? defaultServer
                return Credentials(apiKey: key, server: server)
            }
        }
        for database in desktopDatabases {
            if let status = SQLiteKV.value(forKey: "windsurfAuthStatus", databaseAt: database),
               let key = (try? JSON(string: status))?["apiKey"].string, !key.isEmpty {
                return Credentials(apiKey: key, server: defaultServer)
            }
        }
        return nil
    }

    public static func parse(_ json: JSON) -> (plan: String?, metrics: [UsageMetric], balance: UsageBalance?) {
        let status = json["userStatus"]["planStatus"]
        let info = status["planInfo"].isNull ? json["planInfo"] : status["planInfo"]
        var metrics: [UsageMetric] = []

        // proto3 JSON omits zero values: a reset time without a percentage means 0% remaining.
        func quota(_ prefix: String, window: UsageWindow, hidden: Bool) {
            guard !hidden else { return }
            let reset = ISODate.fromUnix(status["\(prefix)QuotaResetAtUnix"].double)
            let remaining = status["\(prefix)QuotaRemainingPercent"].double ?? (reset != nil ? 0 : nil)
            guard let remaining else { return }
            metrics.append(UsageMetric(
                id: "devin.\(prefix)",
                title: window.title,
                usedPercent: 100 - remaining,
                resetsAt: reset,
                window: window
            ))
        }
        quota("daily", window: .daily, hidden: info["hideDailyQuota"].bool == true)
        quota("weekly", window: .weekly, hidden: info["hideWeeklyQuota"].bool == true)

        let planEnd = ISODate.parse(status["planEnd"].string)
        if metrics.isEmpty, let limit = status["acuLimit"].double, limit > 0 {
            let used = status["acuConsumed"].double ?? 0
            metrics.append(UsageMetric(
                id: "devin.acu",
                title: "ACU",
                usedPercent: used / limit * 100,
                resetsAt: planEnd,
                detail: "\(UsageFormat.number(used)) / \(UsageFormat.number(limit)) ACU",
                window: .monthly
            ))
        }
        if metrics.isEmpty, let available = status["availablePromptCredits"].double, available > 0 {
            let used = status["usedPromptCredits"].double ?? 0
            metrics.append(UsageMetric(id: "devin.credits", title: "Credits", usedPercent: used / available * 100, resetsAt: planEnd, window: .monthly))
        }

        var balance: UsageBalance?
        if let micros = status["overageBalanceMicros"].double, micros > 0 {
            balance = UsageBalance(title: "Extra usage", amount: micros / 1_000_000)
        }
        return (info["planName"].string, metrics, balance)
    }
}
