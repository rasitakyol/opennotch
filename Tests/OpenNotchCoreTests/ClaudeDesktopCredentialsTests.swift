import Foundation
import os
import Security
import Testing
@testable import OpenNotchCore

enum DesktopFixture {
    // Synthetic cache encrypted independently with Python hashlib + OpenSSL AES-128-CBC.
    // No real credentials. Includes a fake refresh token to ensure only the access token is selected.
    static let password = "opennotch-test-password"
    static let sealed = Data(base64Encoded: "djEwHi6IXZ+HFkDu4XleT9gX+yritu2+JNtBn1iRyim5+pnZ0SJXEQpez/g4YgolYSeq8Jg7rLnHS5AW+LDa8KuwEp87GsSAXWRfXB7hxrkqGmBuod3hQwx+pZP7kUPBCXxZmTUnqvijh9QDVjmUMyXf1cbyRX7oppu0+6JKTK898/tn6L2fsZE8ZSk4Iawmqj/KFHLjgaSSQx/gLgpznSQ0v0NDhsf6BRSk6dmH7YBU6rj2eSFIU/anIaKr81ssRCcQuTth1tPOqXSLAT7KRy10jnW2D+idaRv8UzhO0876QpPtvhEq2Bdj13lYZ6MwsTRhY6NvBmq8z980QvRqf3m7ow==")!
    static var config: Data { Data("{\"oauth:tokenCacheV2\":\"\(sealed.base64EncodedString())\"}".utf8) }

    static func reader(
        readPassword: @escaping @Sendable (DesktopKeychain.Interaction) async throws -> String = { _ in password }
    ) -> ClaudeDesktopCredentials {
        ClaudeDesktopCredentials(configExists: { true }, readConfig: { config }, readPassword: readPassword)
    }

    static func identity(_ account: String, scopes: String = "user:inference user:profile") -> String {
        "acct:\(account)|\(ClaudeDesktopCredentials.clientID):org-test:https://api.anthropic.com:\(scopes)"
    }
}

@Suite("Claude Desktop cache")
struct ClaudeDesktopCredentialsTests {
    @Test func decryptsIndependentElectronFixture() async throws {
        let token = try await DesktopFixture.reader().readWithoutInteraction()
        #expect(token.accessToken == "fake-desktop-token")
        #expect(token.expiresAt == Date(timeIntervalSince1970: 4_102_444_800))
    }

    @Test func wrongKeyAndUnsupportedOrTruncatedEnvelopesFailClosed() async {
        await #expect(throws: ProviderIssue.claudeDesktop(.unsupportedFormat)) {
            try await DesktopFixture.reader { _ in "wrong-password" }.readWithoutInteraction()
        }
        for bytes in [Data(), Data("v10".utf8), Data("v10broken".utf8), Data("v11".utf8) + DesktopFixture.sealed.dropFirst(3)] {
            #expect(ClaudeDesktopCredentials.decrypt(bytes, password: DesktopFixture.password) == nil)
        }
    }

    @Test func validCodeScopeWinsRegardlessOfScopeOrder() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let cache: [String: Any] = [
            DesktopFixture.identity("sibling"): ["token": "sibling", "expiresAt": 9_000_000],
            DesktopFixture.identity("code", scopes: "user:sessions:claude_code user:profile user:inference"):
                ["token": "code", "expiresAt": 2_000_000],
            DesktopFixture.identity("older-code", scopes: "user:inference user:sessions:claude_code"):
                ["token": "older-code", "expiresAt": 1_500_000],
        ]
        #expect(try #require(ClaudeDesktopCredentials.selectToken(in: cache, now: now)).accessToken == "code")
    }

    @Test func expiredPreferredTokenDoesNotHideLiveSibling() throws {
        let cache: [String: Any] = [
            DesktopFixture.identity("code", scopes: "user:inference user:sessions:claude_code"):
                ["token": "expired-code", "expiresAt": 1_020_000],
            DesktopFixture.identity("sibling"): ["token": "live-sibling", "expiresAt": 9_000_000],
        ]
        #expect(try #require(ClaudeDesktopCredentials.selectToken(in: cache, now: Date(timeIntervalSince1970: 1_000))).accessToken == "live-sibling")
        // Keeping the expired candidate lets the caller report an expired session rather than a missing one.
        #expect(ClaudeDesktopCredentials.selectToken(in: cache, now: Date(timeIntervalSince1970: 10_000))?.expiresAt != nil)
    }

    @Test func ignoresOtherClientsHostsScopesAndMalformedEntries() {
        let cache: [String: Any] = [
            DesktopFixture.identity("other-client").replacingOccurrences(of: ClaudeDesktopCredentials.clientID, with: "other-client"):
                ["token": "other-client", "expiresAt": 9_000_000],
            DesktopFixture.identity("other-host").replacingOccurrences(of: "api.anthropic.com", with: "example.com"):
                ["token": "other-host", "expiresAt": 9_000_000],
            DesktopFixture.identity("scope", scopes: "user:profile"): ["token": "profile-only", "expiresAt": 9_000_000],
            DesktopFixture.identity("null"): NSNull(),
            DesktopFixture.identity("empty"): ["token": "", "expiresAt": 9_000_000],
            DesktopFixture.identity("newline"): ["token": "token\nheader", "expiresAt": 9_000_000],
            DesktopFixture.identity("boolean"): ["token": "bool", "expiresAt": true],
            DesktopFixture.identity("string"): ["token": "str", "expiresAt": "9000000"],
            DesktopFixture.identity("missing"): ["refreshToken": "not-an-access-token", "expiresAt": 9_000_000],
            DesktopFixture.identity("infinity"): ["token": "inf", "expiresAt": Double.infinity],
        ]
        #expect(ClaudeDesktopCredentials.selectToken(in: cache) == nil)
        #expect(ClaudeDesktopCredentials.selectToken(in: [:]) == nil)
    }

    @Test func malformedOrMissingCacheNeverReachesKeychainEvenOnEnable() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let cases: [(Data?, ProviderIssue)] = [
            (nil, .claudeDesktop(.noSession)),
            (Data("{}".utf8), .claudeDesktop(.noSession)),
            (Data("[]".utf8), .claudeDesktop(.unsupportedFormat)),
            (Data("{\"oauth:tokenCacheV2\":\"not-base64\"}".utf8), .claudeDesktop(.unsupportedFormat)),
            (Data("{\"oauth:tokenCacheV2\":\"djExc29tZXRoaW5n\"}".utf8), .claudeDesktop(.unsupportedFormat)),
        ]
        for (data, issue) in cases {
            let reader = ClaudeDesktopCredentials(configExists: { true }, readConfig: { data }, readPassword: { _ in
                reads.withLock { $0 += 1 }
                return DesktopFixture.password
            })
            await #expect(throws: issue) { try await reader.requestAccessFromSettings() }
        }
        #expect(reads.withLock { $0 } == 0)
    }

    @Test func onlyExplicitSettingsRequestAllowsInteractionAndSecretsAreNotCached() async throws {
        let reads = OSAllocatedUnfairLock(initialState: [DesktopKeychain.Interaction]())
        let reader = DesktopFixture.reader { mode in
            reads.withLock { $0.append(mode) }
            return DesktopFixture.password
        }
        #expect(reader.isPresent)
        #expect(reads.withLock { $0.isEmpty })
        try await reader.requestAccessFromSettings()
        _ = try await reader.readWithoutInteraction()
        _ = try await reader.readWithoutInteraction()
        #expect(reads.withLock { $0 } == [.userInitiated, .forbidden, .forbidden])
    }

    @Test func deniedAccessIsReportedWithoutInteractiveRetry() async {
        let modes = OSAllocatedUnfairLock(initialState: [DesktopKeychain.Interaction]())
        let reader = DesktopFixture.reader { mode in
            modes.withLock { $0.append(mode) }
            throw ProviderIssue.claudeDesktop(.accessRequired)
        }
        await #expect(throws: ProviderIssue.claudeDesktop(.accessRequired)) { try await reader.readWithoutInteraction() }
        #expect(modes.withLock { $0 } == [.forbidden])
    }
}

@Suite("Claude Desktop Keychain interaction guard")
struct DesktopKeychainPolicyTests {
    @Test(arguments: [false, true]) func backgroundReadDisablesAndRestoresInteraction(previous: Bool) throws {
        var policy: [Bool] = []
        let result = try DesktopKeychain.withInteractionPolicy(.forbidden, get: {
            $0.pointee = DarwinBoolean(previous)
            return errSecSuccess
        }, set: {
            policy.append($0)
            return errSecSuccess
        }, read: {
            #expect(policy == [false])
            return "synthetic-password"
        })
        #expect(result == "synthetic-password")
        #expect(policy == [false, previous])
    }

    @Test func explicitEnableAllowsInteractionAndRestoresOnDenial() {
        var policy: [Bool] = []
        #expect(throws: ProviderIssue.claudeDesktop(.accessRequired)) {
            try DesktopKeychain.withInteractionPolicy(.userInitiated, get: {
                $0.pointee = false
                return errSecSuccess
            }, set: {
                policy.append($0)
                return errSecSuccess
            }, read: {
                #expect(policy == [true])
                throw ProviderIssue.claudeDesktop(.accessRequired)
            })
        }
        #expect(policy == [true, false])
    }

    @Test(arguments: [false, true]) func failedInteractionGuardAbortsBeforeReading(failGet: Bool) {
        var didRead = false
        #expect(throws: ProviderIssue.claudeDesktop(.keychainUnavailable)) {
            try DesktopKeychain.withInteractionPolicy(.forbidden, get: { _ in
                failGet ? errSecNotAvailable : errSecSuccess
            }, set: { _ in errSecNotAvailable }, read: { didRead = true })
        }
        #expect(!didRead)
    }
}
