import Foundation
import os
import Testing
@testable import OpenNotchCore

@Suite("Cursor sessions")
struct CursorSessionTests {
    private let cursorToken = jwt(exp: 1_800_000_000)
    private let grokToken = jwt(exp: 1_900_000_000)
    private let expiredToken = jwt(exp: 1_000)

    @Test func plaintextIdeTokenIsUsedAsIs() {
        let material = CursorSessions.material(
            ideValue: cursorToken,
            grokSecrets: nil,
            decryptCursor: { _ in nil },
            decryptGrok: { _ in nil }
        )
        #expect(material.tokens.map(\.source) == [CursorSessions.cursorSource])
        #expect(material.tokens.map(\.token) == [cursorToken])
        #expect(!material.lockedCursor)
    }

    @Test func sealedIdeTokenIsDecryptedAndCiphertextIsNeverSent() {
        let cipher = Data("cursor-cipher".utf8)
        let material = CursorSessions.material(
            ideValue: CursorSessions.safeStoragePrefix + cipher.base64EncodedString(),
            grokSecrets: nil,
            decryptCursor: { $0 == cipher ? cursorToken : nil },
            decryptGrok: { _ in Issue.record("Grok Bot key unused"); return nil }
        )
        #expect(material.tokens.map(\.token) == [cursorToken])
        #expect(material.tokens.map(\.source) == [CursorSessions.cursorSource])

        let locked = CursorSessions.material(
            ideValue: CursorSessions.safeStoragePrefix + cipher.base64EncodedString(),
            grokSecrets: nil,
            decryptCursor: { _ in nil },
            decryptGrok: { _ in nil }
        )
        #expect(locked.tokens.isEmpty)
        #expect(locked.lockedCursor)
        #expect(!locked.tokens.contains { $0.token.contains("cursor-safe-storage") })
    }

    @Test func grokBotActiveAccountComesBeforeOtherAccounts() throws {
        let inactive = jwt(exp: 1_800_000_000)
        let secrets = try JSON(string: """
        {"cursor-accounts":"{\\"active\\":\\"home\\",\\"accounts\\":{\\"other\\":{\\"cursor-access-token\\":\\"\(inactive)\\"},\\"home\\":{\\"cursor-access-token\\":\\"\(grokToken)\\"}}}"}
        """)
        let material = CursorSessions.material(
            ideValue: nil,
            grokSecrets: secrets,
            decryptCursor: { _ in nil },
            decryptGrok: { _ in nil }
        )
        #expect(material.tokens.map(\.rank) == [1, 101])
        #expect(material.tokens.map(\.token) == [grokToken, inactive])
        #expect(material.tokens.allSatisfy { $0.source == CursorSessions.grokSource })
    }

    @Test func grokBotPlaintextAndScopedCiphertextUnwrap() throws {
        let cipher = Data("grok-cipher".utf8)
        let plain = CursorSessions.plaintextPrefix + Data(cursorToken.utf8).base64EncodedString()
        let scope = String(repeating: "ab", count: 32)
        let scoped = CursorSessions.scopedPrefix + scope + ":" + cipher.base64EncodedString()
        let secrets = try JSON(string: """
        {"cursor-accounts":"{\\"active\\":\\"home\\",\\"accounts\\":{\\"home\\":{\\"cursor-access-token\\":\\"\(scoped)\\"}}}","cursor-access-token":"\(plain)"}
        """)
        let material = CursorSessions.material(
            ideValue: nil,
            grokSecrets: secrets,
            decryptCursor: { _ in nil },
            decryptGrok: { $0 == cipher ? grokToken : nil }
        )
        #expect(material.tokens.map(\.token) == [grokToken, cursorToken])
        #expect(!material.lockedGrok)
    }

    @Test func duplicateTokensAreReadOnce() throws {
        let secrets = try JSON(string: """
        {"cursor-accounts":"{\\"active\\":\\"home\\",\\"accounts\\":{\\"home\\":{\\"cursor-access-token\\":\\"\(cursorToken)\\"}}}"}
        """)
        let material = CursorSessions.material(
            ideValue: cursorToken,
            grokSecrets: secrets,
            decryptCursor: { _ in nil },
            decryptGrok: { _ in nil }
        )
        #expect(material.tokens.map(\.source) == [CursorSessions.cursorSource])
    }

    @Test func longestLivedTokenIsTriedFirstAndARejectionUsesTheNext() async throws {
        let shorter = CursorSessions.Candidate(token: cursorToken, source: CursorSessions.cursorSource, rank: 0, expiry: Date(timeIntervalSince1970: 1_800_000_000))
        let longer = CursorSessions.Candidate(token: grokToken, source: CursorSessions.grokSource, rank: 1, expiry: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(CursorSessions.attemptOrder([shorter, longer]).map(\.token) == [grokToken, cursorToken])

        let tried = OSAllocatedUnfairLock<[String]>(initialState: [])
        let snapshot = try await CursorSessions.resolve(CursorSessions.Material(tokens: [shorter, longer], sawExpired: false, lockedCursor: false, lockedGrok: false)) { candidate in
            tried.withLock { $0.append(candidate.source) }
            if candidate.source == CursorSessions.grokSource { throw ProviderIssue.unauthorized }
            return ProviderSnapshot(provider: .cursor, plan: "Ultra", metrics: [
                UsageMetric(id: "cursor.weekly", title: "Weekly", usedPercent: 10, window: .weekly),
            ], credentialSource: candidate.source)
        }
        #expect(tried.withLock { $0 } == [CursorSessions.grokSource, CursorSessions.cursorSource])
        #expect(snapshot.credentialSource == CursorSessions.cursorSource)
        #expect(snapshot.metrics.map(\.title) == ["Weekly"])
    }

    @Test func equalExpiryPrefersTheCursorToken() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let ordered = CursorSessions.attemptOrder([
            CursorSessions.Candidate(token: grokToken, source: CursorSessions.grokSource, rank: 1, expiry: expiry),
            CursorSessions.Candidate(token: cursorToken, source: CursorSessions.cursorSource, rank: 0, expiry: expiry),
        ])
        #expect(ordered.map(\.source) == [CursorSessions.cursorSource, CursorSessions.grokSource])
    }

    @Test func expiredOrMissingSessionsStayDistinctFromALockedKeychain() async {
        let expired = CursorSessions.material(
            ideValue: expiredToken,
            grokSecrets: nil,
            decryptCursor: { _ in nil },
            decryptGrok: { _ in nil }
        )
        await #expect(throws: ProviderIssue.expired) {
            try await CursorSessions.resolve(expired) { _ in
                Issue.record("Expired token must not be sent")
                throw ProviderIssue.unauthorized
            }
        }

        let missing = CursorSessions.Material(tokens: [], sawExpired: false, lockedCursor: false, lockedGrok: false)
        await #expect(throws: ProviderIssue.notConfigured) {
            try await CursorSessions.resolve(missing) { _ in throw ProviderIssue.unauthorized }
        }

        let locked = CursorSessions.Material(tokens: [], sawExpired: false, lockedCursor: true, lockedGrok: false)
        await #expect(throws: ProviderIssue.unexpected("Allow OpenNotch to read “Cursor Safe Storage” in Keychain, then refresh.")) {
            try await CursorSessions.resolve(locked) { _ in throw ProviderIssue.unauthorized }
        }
    }
}

private func jwt(exp: Int) -> String {
    func part(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(part("{}")).\(part("{\"exp\":\(exp)}")).sig"
}
