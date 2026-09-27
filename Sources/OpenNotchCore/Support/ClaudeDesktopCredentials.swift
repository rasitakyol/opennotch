import CommonCrypto
import Foundation
import LocalAuthentication
import Security

public enum ClaudeDesktopIssue: String, Error, Codable, Sendable {
    case noSession
    case accessRequired
    case keychainUnavailable
    case unsupportedFormat
    case expired
    case rejected

    public var title: String {
        switch self {
        case .noSession: "Claude Desktop session not found"
        case .accessRequired: "Claude Desktop access needed"
        case .keychainUnavailable: "Claude Desktop key unavailable"
        case .unsupportedFormat: "Claude Desktop cache unreadable"
        case .expired: "Claude Desktop session expired"
        case .rejected: "Claude Desktop session rejected"
        }
    }

    public var hint: String {
        switch self {
        case .noSession, .expired, .rejected:
            "Open Claude Desktop's Code tab and sign in, then refresh OpenNotch."
        case .accessRequired:
            "In Settings, turn Claude Desktop fallback off and on to allow access. Background refreshes cannot ask for permission."
        case .keychainUnavailable:
            "Open Claude Desktop and unlock your login Keychain, then try again."
        case .unsupportedFormat:
            "Open Claude Desktop's Code tab and retry. If this persists, its storage format may have changed; use Claude Code instead."
        }
    }
}

/// Reads only Desktop's Code OAuth cache. Never reads cookies, refreshes tokens, or writes credentials.
/// No secret is retained between reads. Desktop remains responsible for rotating its own session.
public struct ClaudeDesktopCredentials: Sendable {
    struct Token: Equatable, Sendable {
        let accessToken: String
        let expiresAt: Date
    }

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static var configPath: String { LocalFiles.path("Library", "Application Support", "Claude", "config.json") }

    private let configExists: @Sendable () -> Bool
    private let readConfig: @Sendable () -> Data?
    private let readPassword: @Sendable (DesktopKeychain.Interaction) async throws -> String

    public init() {
        self.init(
            configExists: { LocalFiles.exists(Self.configPath) },
            readConfig: { LocalFiles.data(Self.configPath) },
            readPassword: { try await DesktopKeychain.password(interaction: $0) }
        )
    }

    init(
        configExists: @escaping @Sendable () -> Bool,
        readConfig: @escaping @Sendable () -> Data?,
        readPassword: @escaping @Sendable (DesktopKeychain.Interaction) async throws -> String
    ) {
        self.configExists = configExists
        self.readConfig = readConfig
        self.readPassword = readPassword
    }

    /// Detection checks only the file's existence, never the Keychain or decrypted contents.
    var isPresent: Bool { configExists() }

    /// The only interactive entry point. Call only in response to enabling the Settings toggle.
    public func requestAccessFromSettings() async throws {
        _ = try await read(interaction: .userInitiated)
    }

    func readWithoutInteraction() async throws -> Token {
        try await read(interaction: .forbidden)
    }

    private func read(interaction: DesktopKeychain.Interaction) async throws -> Token {
        struct Config: Decodable {
            let cache: String?
            enum CodingKeys: String, CodingKey { case cache = "oauth:tokenCacheV2" }
        }

        guard let data = readConfig() else { throw ProviderIssue.claudeDesktop(.noSession) }
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else {
            throw ProviderIssue.claudeDesktop(.unsupportedFormat)
        }
        guard let encoded = config.cache else { throw ProviderIssue.claudeDesktop(.noSession) }
        guard let encrypted = Data(base64Encoded: encoded), Self.isSupportedEnvelope(encrypted) else {
            throw ProviderIssue.claudeDesktop(.unsupportedFormat)
        }

        let password = try await readPassword(interaction)
        guard let cleartext = Self.decrypt(encrypted, password: password),
              let cache = try? JSONSerialization.jsonObject(with: cleartext) as? [String: Any] else {
            throw ProviderIssue.claudeDesktop(.unsupportedFormat)
        }
        guard let token = Self.selectToken(in: cache) else { throw ProviderIssue.claudeDesktop(.noSession) }
        return token
    }

    static func isSupportedEnvelope(_ data: Data) -> Bool {
        data.starts(with: Data("v10".utf8)) && data.count > 3 && (data.count - 3) % kCCBlockSizeAES128 == 0
    }

    /// Electron's macOS v10 format: PBKDF2-SHA1, then AES-128-CBC with PKCS#7 padding.
    /// Unknown versions fail closed, so a Desktop update cannot trigger an unrelated credential read.
    static func decrypt(_ encrypted: Data, password: String) -> Data? {
        guard isSupportedEnvelope(encrypted), !password.isEmpty else { return nil }
        let passwordBytes = Array(password.utf8)
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derivation = passwordBytes.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, kCCKeySizeAES128
            )
        }
        guard derivation == kCCSuccess else { return nil }
        let ciphertext = Array(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = ciphertext.count + kCCBlockSizeAES128
        var plaintext = [UInt8](repeating: 0, count: capacity)
        var length = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, ciphertext, ciphertext.count, &plaintext, capacity, &length
        )
        guard status == kCCSuccess else { return nil }
        return Data(plaintext.prefix(length))
    }

    static func selectToken(in cache: [String: Any], now: Date = Date()) -> Token? {
        struct Candidate {
            let identity: String
            let token: Token
            let codeTab: Bool
            let valid: Bool
        }

        let candidates: [Candidate] = cache.compactMap { key, value in
            let identity = key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? key
            let hostSeparator = ":https://api.anthropic.com:"
            guard identity.hasPrefix(Self.clientID + ":"),
                  let hostRange = identity.range(of: hostSeparator),
                  let entry = value as? [String: Any],
                  let accessToken = entry["token"] as? String,
                  !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let expiry = entry["expiresAt"] as? NSNumber,
                  CFGetTypeID(expiry) != CFBooleanGetTypeID(),
                  expiry.doubleValue.isFinite, expiry.doubleValue > 0 else { return nil }
            let scopes = Set(identity[hostRange.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init))
            let codeTab = scopes.contains("user:sessions:claude_code")
            guard codeTab || scopes.contains("user:inference") else { return nil }
            let token = Token(accessToken: accessToken, expiresAt: Date(timeIntervalSince1970: expiry.doubleValue / 1000))
            return Candidate(identity: key, token: token, codeTab: codeTab, valid: token.expiresAt > now.addingTimeInterval(30))
        }
        // A live sibling beats an expired Code token; among live tokens prefer the Code tab Desktop rotates.
        return candidates.sorted { lhs, rhs in
            if lhs.valid != rhs.valid { return lhs.valid }
            if lhs.codeTab != rhs.codeTab { return lhs.codeTab }
            if lhs.token.expiresAt != rhs.token.expiresAt { return lhs.token.expiresAt > rhs.token.expiresAt }
            return lhs.identity < rhs.identity
        }.first?.token
    }
}

enum DesktopKeychain {
    enum Interaction: Sendable { case forbidden, userInitiated }

    // The legacy Keychain interaction flag is process-wide. Serialize every native read and restore it
    // before leaving this queue, including failures. Other providers use the separate `security` process.
    private static let queue = DispatchQueue(label: "app.opennotch.desktop-keychain", qos: .userInitiated)

    static func password(interaction: Interaction) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try withInteractionPolicy(interaction) {
                        let context = LAContext()
                        context.interactionNotAllowed = interaction == .forbidden
                        context.localizedReason = "Read Claude Desktop usage in OpenNotch"
                        let query: [String: Any] = [
                            kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: "Claude Safe Storage",
                            kSecAttrAccount as String: "Claude Key",
                            kSecMatchLimit as String: kSecMatchLimitOne,
                            kSecReturnData as String: true,
                            kSecUseAuthenticationContext as String: context,
                        ]
                        var result: CFTypeRef?
                        let status = SecItemCopyMatching(query as CFDictionary, &result)
                        guard status == errSecSuccess else {
                            let needsAccess = [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status)
                            throw ProviderIssue.claudeDesktop(needsAccess ? .accessRequired : .keychainUnavailable)
                        }
                        guard let data = result as? Data,
                              let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                            throw ProviderIssue.claudeDesktop(.keychainUnavailable)
                        }
                        return password
                    }
                })
            }
        }
    }

    /// LAContext alone does not suppress legacy login-Keychain ACL dialogs. The deprecated SecKeychain
    /// interaction API is still needed for Electron's legacy item. Abort if the guard cannot be set.
    static func withInteractionPolicy<T>(
        _ interaction: Interaction,
        get: (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus = { LegacyInteractionFlag.shared.get($0) },
        set: (Bool) -> OSStatus = { LegacyInteractionFlag.shared.set($0) },
        read: () throws -> T
    ) throws -> T {
        var previous: DarwinBoolean = false
        guard get(&previous) == errSecSuccess,
              set(interaction == .userInitiated) == errSecSuccess else {
            throw ProviderIssue.claudeDesktop(.keychainUnavailable)
        }
        defer { _ = set(previous.boolValue) }
        return try read()
    }
}

/// Calling the deprecated flag through a protocol keeps this deliberate use from warning on every build,
/// while any other deprecated call in the module still does.
private protocol InteractionFlag: Sendable {
    func get(_ allowed: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
    func set(_ allowed: Bool) -> OSStatus
}

private struct LegacyInteractionFlag: InteractionFlag {
    static let shared: any InteractionFlag = LegacyInteractionFlag()

    @available(macOS, deprecated: 10.10)
    func get(_ allowed: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus { SecKeychainGetUserInteractionAllowed(allowed) }

    @available(macOS, deprecated: 10.10)
    func set(_ allowed: Bool) -> OSStatus { SecKeychainSetUserInteractionAllowed(allowed) }
}
