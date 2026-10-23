import Foundation

/// Access tokens saved by Cursor and Grok Bot, unwrapped from Electron safe storage when needed.
///
/// Cursor stores `cursorAuth/accessToken` as `cursor-safe-storage:v1:` plus a base64 v10 blob.
/// Grok Bot stores `cursor-accounts` in `sand-secrets.json`: a raw JWT, `plaintext:v1:` base64,
/// `scoped:v1:<account>:` ciphertext, or bare safe-storage ciphertext. OpenNotch only reads the
/// access token the app already saved. It never uses a refresh token.
enum CursorSessions {
    static let cursorSource = "Cursor session"
    static let grokSource = "Grok Bot session"

    static let safeStoragePrefix = "cursor-safe-storage:v1:"
    static let plaintextPrefix = "plaintext:v1:"
    static let scopedPrefix = "scoped:v1:"

    struct Candidate: Equatable, Sendable {
        var token: String
        var source: String
        /// Lower ranks are preferred when two tokens expire together. Cursor's own token is 0,
        /// Grok Bot's active account is 1, and other saved accounts follow.
        var rank: Int
        var expiry: Date?
    }

    struct Material: Equatable, Sendable {
        var tokens: [Candidate]
        var sawExpired: Bool
        var lockedCursor: Bool
        var lockedGrok: Bool
    }

    static func isSealed(_ stored: String?) -> Bool {
        guard let value = trimmed(stored) else { return false }
        if value.hasPrefix(plaintextPrefix) { return false }
        if value.hasPrefix(safeStoragePrefix) || value.hasPrefix(scopedPrefix) { return true }
        return JWT.claims(value) == nil
    }

    static func material(
        ideValue: String?,
        grokSecrets: JSON?,
        decryptCursor: @Sendable (Data) -> String?,
        decryptGrok: @Sendable (Data) -> String?
    ) -> Material {
        var tokens: [Candidate] = []
        var sawExpired = false
        var lockedCursor = false
        var lockedGrok = false

        func add(_ stored: String?, source: String, rank: Int, locked: inout Bool, decrypt: @Sendable (Data) -> String?) {
            guard let stored = trimmed(stored) else { return }
            switch unwrap(stored, decrypt: decrypt) {
            case .token(let token):
                if JWT.isExpired(token) {
                    sawExpired = true
                    return
                }
                guard !tokens.contains(where: { $0.token == token }) else { return }
                tokens.append(Candidate(token: token, source: source, rank: rank, expiry: JWT.expiry(token)))
            case .locked:
                locked = true
            case .skip:
                break
            }
        }

        add(ideValue, source: cursorSource, rank: 0, locked: &lockedCursor, decrypt: decryptCursor)

        if let secrets = grokSecrets {
            if let accountsText = secrets["cursor-accounts"].string,
               let accounts = try? JSON(string: accountsText) {
                let active = accounts["active"].string
                let ordered = accounts["accounts"].dictionary.sorted {
                    ($0.key == active ? 0 : 1, $0.key) < ($1.key == active ? 0 : 1, $1.key)
                }
                for (offset, entry) in ordered.enumerated() {
                    let rank = entry.key == active ? 1 : 100 + offset
                    add(entry.value["cursor-access-token"].string, source: grokSource, rank: rank, locked: &lockedGrok, decrypt: decryptGrok)
                }
            }
            add(secrets["cursor-access-token"].string, source: grokSource, rank: 50, locked: &lockedGrok, decrypt: decryptGrok)
        }

        return Material(tokens: tokens, sawExpired: sawExpired, lockedCursor: lockedCursor, lockedGrok: lockedGrok)
    }

    /// Longest-lived token first. A rejected session falls through to the next saved token.
    static func attemptOrder(_ tokens: [Candidate]) -> [Candidate] {
        tokens.sorted { lhs, rhs in
            let left = lhs.expiry ?? .distantPast
            let right = rhs.expiry ?? .distantPast
            if left != right { return left > right }
            return lhs.rank < rhs.rank
        }
    }

    static func resolve(
        _ material: Material,
        fetch: (Candidate) async throws -> ProviderSnapshot
    ) async throws -> ProviderSnapshot {
        let ordered = attemptOrder(material.tokens)
        guard !ordered.isEmpty else {
            if material.lockedCursor || material.lockedGrok {
                throw ProviderIssue.unexpected(lockedHint(material))
            }
            throw material.sawExpired ? ProviderIssue.expired : ProviderIssue.notConfigured
        }

        var rejected = false
        for candidate in ordered {
            do {
                return try await fetch(candidate)
            } catch ProviderIssue.unauthorized {
                rejected = true
            }
        }
        throw rejected ? ProviderIssue.unauthorized : ProviderIssue.notConfigured
    }

    private static func lockedHint(_ material: Material) -> String {
        switch (material.lockedCursor, material.lockedGrok) {
        case (true, false):
            "Allow OpenNotch to read “Cursor Safe Storage” in Keychain, then refresh."
        case (false, true):
            "Allow OpenNotch to read “Grok Bot Safe Storage” in Keychain, then refresh."
        default:
            "Allow OpenNotch to read Cursor or Grok Bot in Keychain, then refresh."
        }
    }

    private enum Unwrapped {
        case token(String)
        case locked
        case skip
    }

    private static func unwrap(_ stored: String, decrypt: @Sendable (Data) -> String?) -> Unwrapped {
        if stored.hasPrefix(safeStoragePrefix) {
            return openCiphertext(String(stored.dropFirst(safeStoragePrefix.count)), decrypt: decrypt)
        }
        if stored.hasPrefix(plaintextPrefix) {
            guard let data = base64(String(stored.dropFirst(plaintextPrefix.count))),
                  let text = String(data: data, encoding: .utf8) else { return .skip }
            return accept(text)
        }
        if stored.hasPrefix(scopedPrefix) {
            let rest = stored.dropFirst(scopedPrefix.count)
            guard let colon = rest.firstIndex(of: ":") else { return .locked }
            let scope = rest[..<colon]
            guard scope.count == 64, scope.allSatisfy(\.isHexDigit) else { return .locked }
            return openCiphertext(String(rest[rest.index(after: colon)...]), decrypt: decrypt)
        }
        if JWT.claims(stored) != nil { return .token(stored) }
        return openCiphertext(stored, decrypt: decrypt)
    }

    private static func openCiphertext(_ encoded: String, decrypt: @Sendable (Data) -> String?) -> Unwrapped {
        guard let data = base64(encoded), let text = decrypt(data) else { return .locked }
        return accept(text)
    }

    private static func accept(_ text: String) -> Unwrapped {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard JWT.claims(token) != nil else { return .skip }
        return .token(token)
    }

    private static func trimmed(_ stored: String?) -> String? {
        guard let value = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func base64(_ encoded: String) -> Data? {
        var text = encoded
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !text.isEmpty else { return nil }
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }
}
