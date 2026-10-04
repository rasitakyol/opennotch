import Foundation
import os
import Testing
@testable import OpenNotchCore

@Suite("Antigravity running-app fallback")
struct AntigravityFallbackTests {
    private let summary = #"{"groups": [{"displayName": "Gemini Models", "buckets": [{"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.75}]}]}"#
    private let app = AntigravityProvider.RunningApp(csrfToken: "fake-csrf", ports: [63193, 63194])

    private func credentials(expired: Bool) -> AntigravityProvider.Credentials {
        .init(accessToken: "fake-google-token", expiresAt: expired ? .distantPast : .distantFuture)
    }

    @Test func liveSessionAsksGoogleWithoutLookingForTheApp() async throws {
        let session = credentials(expired: false)
        let body = summary
        let provider = AntigravityProvider(requestJSON: { request in
            #expect(request.url?.host == "cloudcode-pa.googleapis.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-google-token")
            return try JSON(string: body)
        }, loadCredentials: { session }, findApp: {
            Issue.record("A live session should not inspect processes")
            return .notRunning
        })
        let snapshot = try await provider.fetch()
        #expect(snapshot.metrics.map(\.usedPercent) == [25])
        #expect(snapshot.credentialSource == "Antigravity session (~/.gemini)")
    }

    @Test func expiredSessionAsksTheRunningAppOnLoopback() async throws {
        let session = credentials(expired: true)
        let runningApp = app
        let body = summary
        let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
        let provider = AntigravityProvider(requestJSON: { request in
            requests.withLock { $0.append(request) }
            // The first port is the TLS-only one and rejects plain HTTP.
            if request.url?.port == 63193 { throw ProviderIssue.server(status: 400) }
            if request.url?.lastPathComponent == "GetLoadCodeAssist" {
                return try JSON(string: #"{"response": {"paidTier": {"id": "g1-pro-tier"}}}"#)
            }
            return try JSON(string: #"{"response": \#(body)}"#)
        }, loadCredentials: { session }, findApp: { .running(runningApp) })

        let snapshot = try await provider.fetch()
        #expect(snapshot.metrics.map(\.usedPercent) == [25])
        #expect(snapshot.plan == "Pro")
        #expect(snapshot.credentialSource == "Running Antigravity app")

        let sent = requests.withLock { $0 }
        #expect(sent.allSatisfy { $0.url?.host == "127.0.0.1" })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == "fake-csrf" })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let quota = try #require(sent.last { $0.url?.lastPathComponent == "RetrieveUserQuotaSummary" })
        #expect(quota.url?.port == 63194)
        #expect(quota.httpBody == Data(#"{"forceRefresh":true}"#.utf8))
    }

    @Test func rejectedSessionAlsoFallsBack() async throws {
        let session = credentials(expired: false)
        let runningApp = app
        let body = summary
        let provider = AntigravityProvider(requestJSON: { request in
            if request.url?.host == "cloudcode-pa.googleapis.com" { throw ProviderIssue.unauthorized }
            return try JSON(string: #"{"response": \#(body)}"#)
        }, loadCredentials: { session }, findApp: { .running(runningApp) })
        #expect(try await provider.fetch().credentialSource == "Running Antigravity app")
    }

    @Test func expiredSessionWithoutTheAppReportsClosedApp() async {
        let session = credentials(expired: true)
        let provider = AntigravityProvider(requestJSON: { _ in
            Issue.record("Unexpected request")
            return try JSON(string: "{}")
        }, loadCredentials: { session }, findApp: { .notRunning })
        await #expect(throws: ProviderIssue.appNotRunning) { try await provider.fetch() }
    }

    @Test func networkErrorsDoNotSwitchSource() async {
        let session = credentials(expired: false)
        let provider = AntigravityProvider(requestJSON: { _ in throw ProviderIssue.offline }, loadCredentials: { session }, findApp: {
            Issue.record("Only a stale session should switch source")
            return .notRunning
        })
        await #expect(throws: ProviderIssue.offline) { try await provider.fetch() }
    }

    @Test func runningAppIsDetectedAndFetchedWithoutASessionFile() async throws {
        let runningApp = app
        let body = summary
        let provider = AntigravityProvider(requestJSON: { request in
            #expect(request.url?.host == "127.0.0.1")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return try JSON(string: #"{"response": \#(body)}"#)
        }, loadCredentials: { nil }, findApp: { .running(runningApp) })
        #expect(await provider.detect())
        #expect(try await provider.fetch().credentialSource == "Running Antigravity app")
    }

    @Test func noSessionAndNoAppRemainsNotConfigured() async {
        let provider = AntigravityProvider(requestJSON: { _ in
            Issue.record("Unexpected request")
            return try JSON(string: "{}")
        }, loadCredentials: { nil }, findApp: { .notRunning })
        #expect(await !provider.detect())
        await #expect(throws: ProviderIssue.notConfigured) { try await provider.fetch() }
    }

    @Test func runningAppWithoutAConnectionIsNotReportedAsClosed() async {
        let session = credentials(expired: true)
        let provider = AntigravityProvider(requestJSON: { _ in
            Issue.record("Unexpected request")
            return try JSON(string: "{}")
        }, loadCredentials: { session }, findApp: { .unavailable })
        await #expect(throws: ProviderIssue.appUnavailable) { try await provider.fetch() }
    }

    @Test func appConnectionFailureDoesNotMasqueradeAsAnExpiredSession() async {
        let session = credentials(expired: true)
        let runningApp = app
        let provider = AntigravityProvider(requestJSON: { _ in throw ProviderIssue.offline }, loadCredentials: { session }, findApp: { .running(runningApp) })
        await #expect(throws: ProviderIssue.appUnavailable) { try await provider.fetch() }
    }

    @Test func localRateLimitSurvivesARejectedTLSPort() async {
        let session = credentials(expired: true)
        let runningApp = AntigravityProvider.RunningApp(csrfToken: "fake-csrf", ports: [63194, 63193])
        let provider = AntigravityProvider(requestJSON: { request in
            if request.url?.port == 63193 { throw ProviderIssue.server(status: 400) }
            throw ProviderIssue.rateLimited
        }, loadCredentials: { session }, findApp: { .running(runningApp) })
        await #expect(throws: ProviderIssue.rateLimited) { try await provider.fetch() }
    }

    @Test func emptyAppResponseHasAnActionableError() async {
        let session = credentials(expired: true)
        let runningApp = app
        let provider = AntigravityProvider(requestJSON: { _ in try JSON(string: "{}") }, loadCredentials: { session }, findApp: { .running(runningApp) })
        await #expect(throws: ProviderIssue.unexpected("Antigravity returned no usage limits. Reopen the app and refresh OpenNotch.")) { try await provider.fetch() }
    }

    @Test func cachedLegacyAndNewIssuesRemainDecodable() throws {
        let legacy = Data(#"{"issue":{"expired":{}},"isLoading":false}"#.utf8)
        #expect(try JSONDecoder().decode(ProviderState.self, from: legacy).issue == .expired)
        for issue in [ProviderIssue.appNotRunning, .appUnavailable] {
            let state = ProviderState(issue: issue)
            let encoded = try JSONEncoder().encode(state)
            #expect(try JSONDecoder().decode(ProviderState.self, from: encoded) == state)
        }
    }

    @Test func findsTheAntigravityServerAndItsLoopbackPorts() {
        let processes = """
          512 /Applications/Devin.app/Contents/Resources/app/extensions/windsurf/bin/language_server_macos_arm --csrf_token devin-token --ide_name windsurf
        71334 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        71763 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --https_server_port 0 --csrf_token fake-csrf --app_data_dir antigravity
        """
        let server = AntigravityProvider.RunningApp.languageServer(inProcessList: processes)
        #expect(AntigravityProvider.RunningApp.isAppRunning(inProcessList: processes))
        #expect(AntigravityProvider.RunningApp.isAppRunning(inProcessList: "42 /Applications/Antigravity.app/Contents/MacOS/Antigravity"))
        #expect(!AntigravityProvider.RunningApp.isAppRunning(inProcessList: "42 /Applications/Devin.app/Contents/MacOS/Devin"))
        let shell = "42 /bin/zsh -c ps language_server antigravity --csrf_token fake /Applications/Antigravity.app/Contents/MacOS/Antigravity"
        #expect(!AntigravityProvider.RunningApp.isAppRunning(inProcessList: shell))
        #expect(AntigravityProvider.RunningApp.languageServer(inProcessList: shell) == nil)
        #expect(server?.pid == "71763")
        #expect(server?.csrfToken == "fake-csrf")
        #expect(AntigravityProvider.RunningApp.languageServer(inProcessList: "1 /bin/language_server --csrf_token=x antigravity")?.csrfToken == "x")

        let sockets = """
        COMMAND     PID       USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        language_ 71763 rasit    7u  IPv4 0xab858a0f01fa0416      0t0  TCP 127.0.0.1:63193 (LISTEN)
        language_ 71763 rasit    8u  IPv4 0xf6d41c4b2e682378      0t0  TCP 127.0.0.1:63194 (LISTEN)
        language_ 71763 rasit    9u  IPv4 0xf6d41c4b2e682379      0t0  TCP *:7000 (LISTEN)
        """
        #expect(AntigravityProvider.RunningApp.loopbackPorts(lsofOutput: sockets) == [63193, 63194])
    }
}
