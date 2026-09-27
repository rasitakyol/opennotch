import Foundation
import os
import Testing
@testable import OpenNotchCore

@Suite("Claude Desktop fallback")
struct ClaudeFallbackTests {
    private let usage = #"{"five_hour":{"utilization":25},"seven_day":{"utilization":40}}"#

    private func credentials(expired: Bool = false) -> ClaudeProvider.Credentials {
        .init(accessToken: "fake-cli-token", expiresAt: expired ? .distantPast : .distantFuture, subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
    }

    @Test func disabledByDefaultDoesNotDetectReadOrSendDesktopSession() async {
        let accesses = OSAllocatedUnfairLock(initialState: 0)
        let reader = ClaudeDesktopCredentials(configExists: { accesses.withLock { $0 += 1 }; return true }, readConfig: {
            accesses.withLock { $0 += 1 }; return DesktopFixture.config
        }, readPassword: { _ in accesses.withLock { $0 += 1 }; return DesktopFixture.password })
        let provider = ClaudeProvider(requestUsage: { _ in
            Issue.record("Unexpected HTTP request")
            return try JSON(string: "{}")
        }, codeCredentials: { nil }, detectCode: { false }, desktop: reader)
        #expect(await !provider.detect())
        await #expect(throws: ProviderIssue.notConfigured) { try await provider.fetch() }
        #expect(accesses.withLock { $0 } == 0)
    }

    @Test func healthyCLIStaysPrimaryWithoutReadingDesktop() async throws {
        let code = credentials()
        let body = usage
        let provider = ClaudeProvider(requestUsage: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-cli-token")
            return try JSON(string: body)
        }, codeCredentials: { code }, detectCode: { true }, desktop: DesktopFixture.reader { _ in
            Issue.record("Healthy CLI should not read Desktop's key")
            return DesktopFixture.password
        }, desktopFallbackEnabled: { true })
        let snapshot = try await provider.fetch()
        #expect(snapshot.plan == "Max 20x")
        #expect(snapshot.credentialSource == "Claude Code session")
    }

    @Test(arguments: [false, true]) func missingOrExpiredCLIFallsBackWithoutRefresh(missing: Bool) async throws {
        let code = missing ? nil : credentials(expired: true)
        let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
        let body = usage
        let provider = ClaudeProvider(requestUsage: { request in
            requests.withLock { $0.append(request) }
            return try JSON(string: body)
        }, codeCredentials: { code }, detectCode: { !missing }, desktop: DesktopFixture.reader { mode in
            #expect(mode == .forbidden)
            return DesktopFixture.password
        }, desktopFallbackEnabled: { true })
        #expect(await provider.detect())
        let snapshot = try await provider.fetch()
        #expect(snapshot.metrics.map(\.usedPercent) == [25, 40])
        #expect(snapshot.plan == nil) // Desktop may be a different account; never reuse CLI plan metadata.
        #expect(snapshot.credentialSource == "Claude Desktop session")
        let request = try #require(requests.withLock { $0.first })
        #expect(requests.withLock { $0.count } == 1)
        #expect(request.url == ClaudeProvider.usageURL)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-desktop-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func rejectedCLIRetriesExactlyOnceWithDesktop() async throws {
        let code = credentials()
        let body = usage
        let tokens = OSAllocatedUnfairLock(initialState: [String]())
        let provider = ClaudeProvider(requestUsage: { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            tokens.withLock { $0.append(auth) }
            if auth == "Bearer fake-cli-token" { throw ProviderIssue.unauthorized }
            return try JSON(string: body)
        }, codeCredentials: { code }, detectCode: { true }, desktop: DesktopFixture.reader(), desktopFallbackEnabled: { true })
        _ = try await provider.fetch()
        #expect(tokens.withLock { $0 } == ["Bearer fake-cli-token", "Bearer fake-desktop-token"])
    }

    @Test(arguments: [ProviderIssue.offline, .timeout, .rateLimited, .server(status: 500), .unexpected("bad data")])
    func nonAuthFailuresDoNotSwitchSessions(issue: ProviderIssue) async {
        let code = credentials()
        let provider = ClaudeProvider(requestUsage: { _ in throw issue }, codeCredentials: { code }, detectCode: { true }, desktop: DesktopFixture.reader { _ in
            Issue.record("Non-authentication failures must not read Desktop's key")
            return DesktopFixture.password
        }, desktopFallbackEnabled: { true })
        await #expect(throws: issue) { try await provider.fetch() }
    }

    @Test func optOutDuringCredentialReadPreventsDesktopRequest() async {
        let enabled = OSAllocatedUnfairLock(initialState: true)
        let provider = ClaudeProvider(requestUsage: { _ in
            Issue.record("Opt-out must prevent a Desktop request")
            return try JSON(string: "{}")
        }, codeCredentials: { nil }, detectCode: { false }, desktop: DesktopFixture.reader { _ in
            enabled.withLock { $0 = false }
            return DesktopFixture.password
        }, desktopFallbackEnabled: { enabled.withLock { $0 } })
        await #expect(throws: ProviderIssue.notConfigured) { try await provider.fetch() }
    }

    @Test func desktopAccessDenialAndRejectionHaveDesktopRecoveryHints() async {
        let denied = ClaudeProvider(requestUsage: { _ in
            Issue.record("Denied credential must not reach the network")
            return try JSON(string: "{}")
        }, codeCredentials: { nil }, detectCode: { false }, desktop: DesktopFixture.reader { _ in
            throw ProviderIssue.claudeDesktop(.accessRequired)
        }, desktopFallbackEnabled: { true })
        await #expect(throws: ProviderIssue.claudeDesktop(.accessRequired)) { try await denied.fetch() }
        let rejected = ClaudeProvider(requestUsage: { _ in throw ProviderIssue.unauthorized }, codeCredentials: { nil }, detectCode: { false }, desktop: DesktopFixture.reader(), desktopFallbackEnabled: { true })
        await #expect(throws: ProviderIssue.claudeDesktop(.rejected)) { try await rejected.fetch() }
        #expect(ProviderIssue.claudeDesktop(.rejected).hint(for: .claude).contains("Claude Desktop"))
    }

    @Test func expiredDesktopIsNotSentAndItsOwnersNextRotationIsReread() async throws {
        // Independently encrypted synthetic cache, using the same test key as DesktopFixture.
        let expired = "djEwHi6IXZ+HFkDu4XleT9gX+yritu2+JNtBn1iRyim5+pnZ0SJXEQpez/g4YgolYSeq8Jg7rLnHS5AW+LDa8KuwEp87GsSAXWRfXB7hxrkqGmBuod3hQwx+pZP7kUPBCXxZ90iG1yet5cayf9ghknYNhaTutLN/DVeD6NnWWQDVFd+Pb/XWh/ckv5XVRqbn6J/iQgBCJcAAqqZLTd8fJb31LXufCI+sJNZbo929/XxgPAigQQWIolbCtgupdCqGQ+jd"
        let config = OSAllocatedUnfairLock(initialState: Data("{\"oauth:tokenCacheV2\":\"\(expired)\"}".utf8))
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let keyReads = OSAllocatedUnfairLock(initialState: 0)
        let body = usage
        let reader = ClaudeDesktopCredentials(configExists: { true }, readConfig: { config.withLock { $0 } }, readPassword: { mode in
            #expect(mode == .forbidden)
            keyReads.withLock { $0 += 1 }
            return DesktopFixture.password
        })
        let provider = ClaudeProvider(requestUsage: { request in
            requests.withLock { $0 += 1 }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-desktop-token")
            return try JSON(string: body)
        }, codeCredentials: { nil }, detectCode: { false }, desktop: reader, desktopFallbackEnabled: { true })
        await #expect(throws: ProviderIssue.claudeDesktop(.expired)) { try await provider.fetch() }
        #expect(requests.withLock { $0 } == 0)
        config.withLock { $0 = DesktopFixture.config } // Simulate a rotation performed by Desktop itself.
        _ = try await provider.fetch()
        #expect(requests.withLock { $0 } == 1)
        #expect(keyReads.withLock { $0 } == 2)
    }

    @Test(arguments: [true, false]) func disabledFallbackPreservesCLIAuthError(expired: Bool) async {
        let code = credentials(expired: expired)
        let provider = ClaudeProvider(requestUsage: { _ in throw ProviderIssue.unauthorized }, codeCredentials: { code }, detectCode: { true }, desktop: DesktopFixture.reader { _ in
            Issue.record("Disabled fallback must not read Desktop even after a CLI auth failure")
            return DesktopFixture.password
        })
        await #expect(throws: expired ? ProviderIssue.expired : .unauthorized) { try await provider.fetch() }
    }

    @Test func legacySnapshotsRemainDecodableAndNewSnapshotsContainNoSecrets() async throws {
        let legacy = Data(#"{"provider":"claude","plan":"Pro","metrics":[],"fetchedAt":0}"#.utf8)
        #expect(try JSONDecoder().decode(ProviderSnapshot.self, from: legacy).credentialSource == nil)
        let body = usage
        let provider = ClaudeProvider(requestUsage: { _ in try JSON(string: body) }, codeCredentials: { nil }, detectCode: { false }, desktop: DesktopFixture.reader(), desktopFallbackEnabled: { true })
        let encoded = try JSONEncoder().encode(await provider.fetch())
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("fake-desktop-token"))
        #expect(!text.contains("fake-refresh-token"))
        #expect(!text.contains(DesktopFixture.password))
        #expect(try JSONDecoder().decode(ProviderSnapshot.self, from: encoded).credentialSource == "Claude Desktop session")
    }
}
