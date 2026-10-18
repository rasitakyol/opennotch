import CryptoKit
import Foundation
import os

/// Google Gemini macOS app (`com.google.GeminiMacOS`) usage limits (5-hour and weekly pools).
///
/// Unlike Antigravity (which queries `cloudcode-pa.googleapis.com`), the native Gemini macOS app
/// queries `robinfrontend-pa.googleapis.com/$rpc/assistant.mobile.robin.RobinService/GetUsageInfo`
/// using the Google account stored in `~/Library/Application Support/com.google.GeminiMacOS`.
public struct GeminiProvider: UsageProvider {
    public let id = ProviderID.gemini
    private let requestJSON: @Sendable (URLRequest) async throws -> JSON
    private let loadKeystore: @Sendable () async -> Data?
    private let appSupportDirectory: @Sendable () -> String

    static let usageURL = URL(string: "https://robinfrontend-pa.googleapis.com/$rpc/assistant.mobile.robin.RobinService/GetUsageInfo")!
    static let tokenURL = URL(string: "https://www.googleapis.com/oauth2/v4/token")!
    static let clientID = "839509190550-l232s7lupkp6f57818eshd7u4sl4920h.apps.googleusercontent.com"
    static let encodedClientSecret: [UInt8] = [
        0x1d, 0x15, 0x19, 0x09, 0x0a, 0x02, 0x77, 0x39, 0x3e, 0x3f, 0x38, 0x6a,
        0x1d, 0x19, 0x31, 0x0e, 0x17, 0x16, 0x03, 0x1c, 0x0e, 0x1f, 0x32, 0x11,
        0x1b, 0x69, 0x6b, 0x2a, 0x32, 0x1c, 0x19, 0x18, 0x08, 0x29, 0x34,
    ]
    static let containerMagic: [UInt8] = [0x2e, 0xba, 0xfe, 0xca, 0x2e, 0xba, 0xfe, 0xca]

    private static let tokenCache = OSAllocatedUnfairLock<CachedToken?>(initialState: nil)
    private static let keystoreCache = OSAllocatedUnfairLock<Data?>(initialState: nil)
    private static let hasPromptedKeychain = OSAllocatedUnfairLock<Bool>(initialState: false)

    private struct CachedToken: Sendable {
        let refreshToken: String
        let accessToken: String
        let expiresAt: Date
    }

    public init(http: HTTPClient = .shared) {
        self.init(
            requestJSON: { try await http.json($0) },
            loadKeystore: { await Self.defaultLoadKeystore() },
            appSupportDirectory: { Self.defaultAppSupportDirectory }
        )
    }

    init(
        requestJSON: @escaping @Sendable (URLRequest) async throws -> JSON,
        loadKeystore: @escaping @Sendable () async -> Data?,
        appSupportDirectory: @escaping @Sendable () -> String
    ) {
        self.requestJSON = requestJSON
        self.loadKeystore = loadKeystore
        self.appSupportDirectory = appSupportDirectory
    }

    private static func defaultLoadKeystore() async -> Data? {
        if let cached = keystoreCache.withLock({ $0 }) {
            return cached
        }
        let service = "Gemini Safe Storage"
        let account = "Gemini Keys"
        let reason = "Read Gemini usage limits in OpenNotch"

        switch await DesktopKeychain.readData(service: service, account: account, interaction: .forbidden, reason: reason) {
        case .success(let data):
            keystoreCache.withLock { $0 = data }
            return data
        case .interactionRequired:
            let shouldPrompt = hasPromptedKeychain.withLock { prompted -> Bool in
                guard !prompted else { return false }
                prompted = true
                return true
            }
            guard shouldPrompt else { return nil }
            if case .success(let data) = await DesktopKeychain.readData(service: service, account: account, interaction: .userInitiated, reason: reason) {
                keystoreCache.withLock { $0 = data }
                return data
            }
            return nil
        case .unavailable:
            return nil
        }
    }

    static var defaultAppSupportDirectory: String {
        LocalFiles.path("Library", "Application Support", "com.google.GeminiMacOS")
    }

    static var clientSecret: String {
        String(decoding: encodedClientSecret.map { $0 ^ 0x5a }, as: UTF8.self)
    }

    static var envToken: String? {
        guard let raw = ProcessInfo.processInfo.environment["OPENNOTCH_GEMINI_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }

    public func detect() async -> Bool {
        if Self.envToken != nil { return true }
        return !Self.authFilePaths(in: appSupportDirectory()).isEmpty
    }

    public func fetch() async throws -> ProviderSnapshot {
        if let token = Self.envToken {
            return try await fetchUsage(accessToken: token, credentialSource: "OPENNOTCH_GEMINI_TOKEN")
        }

        let directory = appSupportDirectory()
        let candidates = Self.authFilePaths(in: directory)
        guard !candidates.isEmpty else { throw ProviderIssue.notConfigured }

        guard let keystoreData = await loadKeystore(),
              let key = Self.extractCredentialsKey(from: keystoreData)
        else {
            throw ProviderIssue.notConfigured
        }

        let authPath = Self.preferredAuthPath(in: directory, candidates: candidates, key: key)
        guard let container = LocalFiles.data(authPath),
              let decrypted = try? Self.decryptContainer(container, key: key),
              let refreshToken = Self.parseRefreshToken(from: decrypted),
              !refreshToken.isEmpty
        else {
            throw ProviderIssue.notConfigured
        }

        let accessToken = try await validAccessToken(for: refreshToken, forceRefresh: false)
        do {
            return try await fetchUsage(accessToken: accessToken, credentialSource: "Gemini app session")
        } catch ProviderIssue.unauthorized {
            let refreshed = try await validAccessToken(for: refreshToken, forceRefresh: true)
            return try await fetchUsage(accessToken: refreshed, credentialSource: "Gemini app session")
        }
    }

    private func validAccessToken(for refreshToken: String, forceRefresh: Bool) async throws -> String {
        if !forceRefresh,
           let cached = Self.tokenCache.withLock({ $0 }),
           cached.refreshToken == refreshToken,
           cached.expiresAt > Date().addingTimeInterval(60)
        {
            return cached.accessToken
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        .map { "\($0.key)=\(Self.formEncode($0.value))" }
        .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let json: JSON
        do {
            json = try await requestJSON(request)
        } catch ProviderIssue.unauthorized, ProviderIssue.server(status: 400) {
            Self.tokenCache.withLock { $0 = nil }
            throw ProviderIssue.expired
        }

        guard let token = json["access_token"].string, !token.isEmpty else {
            throw ProviderIssue.unexpected("Gemini token refresh returned no access token")
        }
        let expiresIn = json["expires_in"].double ?? 3_600
        let expiresAt = Date().addingTimeInterval(max(60, expiresIn))
        Self.tokenCache.withLock {
            $0 = CachedToken(refreshToken: refreshToken, accessToken: token, expiresAt: expiresAt)
        }
        return token
    }

    private func fetchUsage(accessToken: String, credentialSource: String) async throws -> ProviderSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let json = try await requestJSON(request)
        let parsed = Self.parse(usageInfo: json)
        guard !parsed.metrics.isEmpty else {
            throw ProviderIssue.unexpected("Gemini returned no usage limits")
        }
        return ProviderSnapshot(
            provider: id,
            plan: parsed.plan,
            metrics: parsed.metrics,
            credentialSource: credentialSource
        )
    }

    private static func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    // MARK: Response parsing

    public static func parse(usageInfo json: JSON) -> (plan: String?, metrics: [UsageMetric]) {
        let plan = planName(json["userTier"].string)
        var metrics: [UsageMetric] = []
        var creditsDetail: String?

        for entry in json["usage"].array {
            let poolType = entry["budgetPoolType"].string ?? ""
            if poolType == "OVERAGE_CREDITS",
               let remainingDouble = entry["credits"]["creditsRemaining"].double
                   ?? entry["credits"]["creditsRemaining"].string.flatMap(Double.init)
            {
                let remaining = Int(remainingDouble)
                if entry["credits"]["useOverageAiCredits"].bool == true || remaining > 0 {
                    creditsDetail = "\(remaining) credits left"
                }
            }
        }

        for entry in json["usage"].array {
            let poolType = entry["budgetPoolType"].string ?? ""
            guard let pctUsed = entry["gxu"]["pctUsed"].double else { continue }

            let clamped = min(max(pctUsed, 0), 1)
            let (metricID, title, window): (String, String, UsageWindow) = switch poolType {
            case "GXU_FIVE_HOURLY":
                ("gemini.fiveHour", "5-hour", .fiveHour)
            case "GXU_WEEKLY":
                ("gemini.weekly", "Weekly", .weekly)
            default:
                ("gemini.\(poolType.lowercased())", entry["gxu"]["title"].string ?? "Period", .other)
            }

            metrics.append(UsageMetric(
                id: metricID,
                title: title,
                usedPercent: clamped * 100,
                resetsAt: clamped > 0 ? ISODate.parse(entry["gxu"]["windowRefreshesAt"].string) : nil,
                detail: creditsDetail,
                window: window
            ))
        }

        metrics.sort { $0.window.sortOrder < $1.window.sortOrder }
        return (plan, metrics)
    }

    /// Maps `ROBINQuotaUserTier` (`TIER_BASIC`, `TIER_PRO`, `TIER_ULTRA`, `TIER_LITE`, `TIER_EXPANDED`, `TIER_NEON`)
    /// to the user-facing Google AI subscription plan name, matching `Gemini.app`'s sidebar badge logic.
    public static func planName(_ userTier: String?) -> String? {
        guard let raw = userTier?.uppercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "TIER_ULTRA", "TIER_NEON", "TIER2":
            return "Ultra"
        case "TIER_PRO", "TIER_PREMIUM", "TIER1":
            return "Pro"
        case "TIER_PLUS", "TIER_LITE", "TIER_HELIUM":
            return "Plus"
        case "TIER_BASIC", "TIER_FREE", "TIER0":
            return "Free"
        case "TIER_EXPANDED":
            return "Expanded"
        default:
            if raw.contains("ULTRA") || raw.contains("NEON") { return "Ultra" }
            if raw.contains("PRO") { return "Pro" }
            if raw.contains("PLUS") || raw.contains("LITE") || raw.contains("HELIUM") { return "Plus" }
            if raw.contains("FREE") || raw.contains("BASIC") { return "Free" }
            return nil
        }
    }

    // MARK: Local container & protobuf decoding

    static func authFilePaths(in appSupportDirectory: String) -> [String] {
        let dataDir = (appSupportDirectory as NSString).appendingPathComponent("Data")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dataDir) else { return [] }
        return entries.sorted().compactMap { entry in
            let authPath = ((dataDir as NSString).appendingPathComponent(entry) as NSString).appendingPathComponent("auth")
            return LocalFiles.exists(authPath) ? authPath : nil
        }
    }

    private static func preferredAuthPath(in appSupportDirectory: String, candidates: [String], key: Data) -> String {
        let configPath = (appSupportDirectory as NSString).appendingPathComponent("account_config")
        if let configData = LocalFiles.data(configPath) {
            let plaintext = (try? decryptContainer(configData, key: key)) ?? configData
            if let activeAlias = parseActiveUserAlias(from: plaintext), !activeAlias.isEmpty {
                let preferred = (((appSupportDirectory as NSString).appendingPathComponent("Data") as NSString)
                    .appendingPathComponent(activeAlias) as NSString).appendingPathComponent("auth")
                if candidates.contains(preferred) {
                    return preferred
                }
            }
        }
        return candidates[0]
    }

    /// Extracts the 32-byte AES-256-GCM key (`key_id == 1`, `KEY_ID_CREDENTIALS`) from `argo.crypt.Keystore`.
    static func extractCredentialsKey(from keystore: Data) -> Data? {
        var offset = 0
        while offset < keystore.count {
            guard let tag = readVarint(keystore, offset: &offset) else { return nil }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            switch wireType {
            case 0:
                guard readVarint(keystore, offset: &offset) != nil else { return nil }
            case 2:
                guard let length = readVarint(keystore, offset: &offset),
                      let subdata = slice(keystore, offset: &offset, length: Int(length))
                else { return nil }
                if fieldNumber == 2, let key = parseKeyData(subdata), key.id == 1, key.payload.count == 32 {
                    return key.payload
                }
            default:
                guard skipField(wireType: wireType, in: keystore, offset: &offset) else { return nil }
            }
        }
        return nil
    }

    private static func parseKeyData(_ data: Data) -> (id: UInt64, payload: Data)? {
        var offset = 0
        var keyID: UInt64 = 0
        var payload: Data?
        while offset < data.count {
            guard let tag = readVarint(data, offset: &offset) else { return nil }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            switch wireType {
            case 0:
                guard let value = readVarint(data, offset: &offset) else { return nil }
                if fieldNumber == 1 { keyID = value }
            case 2:
                guard let length = readVarint(data, offset: &offset),
                      let bytes = slice(data, offset: &offset, length: Int(length))
                else { return nil }
                if fieldNumber == 4 { payload = bytes }
            default:
                guard skipField(wireType: wireType, in: data, offset: &offset) else { return nil }
            }
        }
        guard let payload else { return nil }
        return (keyID, payload)
    }

    /// Decrypts a `Gemini.app` `container.proto` file (`0xcafeba2e` magic + length-prefixed `DataPreamble` + AES-256-GCM payload).
    static func decryptContainer(_ container: Data, key: Data) throws -> Data {
        guard container.count > 12 + 16,
              Array(container.prefix(8)) == containerMagic
        else {
            throw ProviderIssue.notConfigured
        }
        let preambleLength = Int(
            UInt32(container[8])
                | (UInt32(container[9]) << 8)
                | (UInt32(container[10]) << 16)
                | (UInt32(container[11]) << 24)
        )
        guard preambleLength > 0, preambleLength <= container.count - 28 else {
            throw ProviderIssue.notConfigured
        }
        let bodyStart = 12 + preambleLength

        let preamble = container.subdata(in: 12..<bodyStart)
        guard let nonceData = parseNonce(from: preamble), nonceData.count == 12 else {
            throw ProviderIssue.notConfigured
        }

        let payload = container.subdata(in: bodyStart..<container.count)
        let ciphertext = payload.prefix(payload.count - 16)
        let tag = payload.suffix(16)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(sealedBox, using: SymmetricKey(data: key))
    }

    private static func parseNonce(from preamble: Data) -> Data? {
        var offset = 0
        while offset < preamble.count {
            guard let tag = readVarint(preamble, offset: &offset) else { return nil }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            if wireType == 2 {
                guard let length = readVarint(preamble, offset: &offset),
                      let bytes = slice(preamble, offset: &offset, length: Int(length))
                else { return nil }
                if fieldNumber == 4 { return bytes }
            } else {
                guard skipField(wireType: wireType, in: preamble, offset: &offset) else { return nil }
            }
        }
        return nil
    }

    /// Reads field 4 (`refresh_token`) from `argo.auth.StoredCredentialData`.
    static func parseRefreshToken(from credentialData: Data) -> String? {
        parseStringField(4, in: credentialData)
    }

    /// Reads field 4 (`active_user_alias`) from `argo.auth.AccountManagerConfig`.
    static func parseActiveUserAlias(from accountConfig: Data) -> String? {
        parseStringField(4, in: accountConfig)
    }

    private static func parseStringField(_ targetField: UInt64, in data: Data) -> String? {
        var offset = 0
        while offset < data.count {
            guard let tag = readVarint(data, offset: &offset) else { return nil }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            if wireType == 2 {
                guard let length = readVarint(data, offset: &offset),
                      let bytes = slice(data, offset: &offset, length: Int(length))
                else { return nil }
                if fieldNumber == targetField,
                   let string = String(data: bytes, encoding: .utf8),
                   !string.isEmpty
                {
                    return string
                }
            } else {
                guard skipField(wireType: wireType, in: data, offset: &offset) else { return nil }
            }
        }
        return nil
    }

    private static func readVarint(_ data: Data, offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count && shift < 64 {
            let byte = data[data.startIndex + offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    private static func slice(_ data: Data, offset: inout Int, length: Int) -> Data? {
        guard length >= 0, offset + length <= data.count else { return nil }
        let start = data.startIndex + offset
        let sub = data.subdata(in: start..<(start + length))
        offset += length
        return sub
    }

    private static func skipField(wireType: UInt64, in data: Data, offset: inout Int) -> Bool {
        switch wireType {
        case 0:
            return readVarint(data, offset: &offset) != nil
        case 1:
            guard offset + 8 <= data.count else { return false }
            offset += 8
            return true
        case 2:
            guard let length = readVarint(data, offset: &offset),
                  Int(length) >= 0,
                  offset + Int(length) <= data.count
            else { return false }
            offset += Int(length)
            return true
        case 5:
            guard offset + 4 <= data.count else { return false }
            offset += 4
            return true
        default:
            return false
        }
    }
}
