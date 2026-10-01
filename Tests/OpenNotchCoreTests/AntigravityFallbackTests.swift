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
            return nil
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
        }, loadCredentials: { session }, findApp: { runningApp })

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
        }, loadCredentials: { session }, findApp: { runningApp })
        #expect(try await provider.fetch().credentialSource == "Running Antigravity app")
    }

    @Test func expiredSessionWithoutTheAppStaysExpired() async {
        let session = credentials(expired: true)
        let provider = AntigravityProvider(requestJSON: { _ in
            Issue.record("Unexpected request")
            return try JSON(string: "{}")
        }, loadCredentials: { session }, findApp: { nil })
        await #expect(throws: ProviderIssue.expired) { try await provider.fetch() }
    }

    @Test func networkErrorsDoNotSwitchSource() async {
        let session = credentials(expired: false)
        let provider = AntigravityProvider(requestJSON: { _ in throw ProviderIssue.offline }, loadCredentials: { session }, findApp: {
            Issue.record("Only a stale session should switch source")
            return nil
        })
        await #expect(throws: ProviderIssue.offline) { try await provider.fetch() }
    }

    @Test func findsTheAntigravityServerAndItsLoopbackPorts() {
        let processes = """
          512 /Applications/Devin.app/Contents/Resources/app/extensions/windsurf/bin/language_server_macos_arm --csrf_token devin-token --ide_name windsurf
        71334 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        71763 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --https_server_port 0 --csrf_token fake-csrf --app_data_dir antigravity
        """
        let server = AntigravityProvider.RunningApp.languageServer(inProcessList: processes)
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
