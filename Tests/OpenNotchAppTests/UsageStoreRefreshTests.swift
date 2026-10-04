import Foundation
import os
import Testing
@testable import OpenNotch
import OpenNotchCore

@Suite("Usage refresh status")
@MainActor
struct UsageStoreRefreshTests {
    @Test func failedChecksPreserveSuccessfulDataAndRecoveryReplacesIt() async throws {
        let domain = "app.opennotch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = ProviderSnapshot(provider: .claude, plan: "Max", metrics: [
            UsageMetric(id: "five", title: "5-hour", usedPercent: 35, window: .fiveHour),
        ], fetchedAt: Date().addingTimeInterval(-3_600))
        let result = OSAllocatedUnfairLock(initialState: Result<ProviderSnapshot, ProviderIssue>.success(first))
        let provider = StubProvider { try result.withLock { try $0.get() } }
        let store = UsageStore(settings: AppSettings(defaults: defaults), providers: [.claude: provider], loadCache: false, requestClaudeDesktopAccess: {
            Issue.record("Checks must never request Keychain permission")
        })

        store.start()
        while store.isRefreshing { await Task.yield() }
        #expect(store.states[.claude]?.snapshot == first)

        result.withLock { $0 = .failure(.claudeDesktop(.accessRequired)) }
        store.refresh()
        while store.isRefreshing { await Task.yield() }
        #expect(store.states[.claude]?.snapshot == first)
        #expect(store.states[.claude]?.issue == .claudeDesktop(.accessRequired))
        #expect(store.states[.claude]?.lastAttempt != nil)
        #expect(try #require(store.lastCheck) > first.fetchedAt)

        let recovered = ProviderSnapshot(provider: .claude, plan: nil, metrics: [
            UsageMetric(id: "five", title: "5-hour", usedPercent: 45, window: .fiveHour),
        ], credentialSource: "Claude Desktop session")
        result.withLock { $0 = .success(recovered) }
        store.refresh()
        while store.isRefreshing { await Task.yield() }
        #expect(store.states[.claude]?.snapshot == recovered)
        #expect(store.states[.claude]?.issue == nil)
    }

    @Test(arguments: [ProviderIssue.appNotRunning, .appUnavailable])
    func undetectedAppProviderKeepsCachedReadingAndRecovers(failure: ProviderIssue) async throws {
        let domain = "app.opennotch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.setEnabled(.antigravity, true)
        settings.setEnabled(.chatgpt, true)
        settings.setEnabled(.cursor, true)

        let isDetected = OSAllocatedUnfairLock(initialState: true)
        let shouldFail = OSAllocatedUnfairLock(initialState: false)
        let antigravitySnapshot = ProviderSnapshot(provider: .antigravity, plan: nil, metrics: [
            UsageMetric(id: "antigravity-five", title: "5-hour", usedPercent: 35, window: .fiveHour),
        ])
        let reading = OSAllocatedUnfairLock(initialState: antigravitySnapshot)
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let chatGPTSnapshot = ProviderSnapshot(provider: .chatgpt, plan: nil, metrics: [
            UsageMetric(id: "chatgpt-five", title: "5-hour", usedPercent: 45, window: .fiveHour),
        ])
        let antigravity = StubProvider(
            id: .antigravity,
            detected: { isDetected.withLock { $0 } },
            keepsCached: true
        ) {
            fetches.withLock { $0 += 1 }
            if shouldFail.withLock({ $0 }) { throw failure }
            return reading.withLock { $0 }
        }
        let chatgpt = StubProvider(
            id: .chatgpt,
            detected: { isDetected.withLock { $0 } }
        ) {
            if shouldFail.withLock({ $0 }) { throw failure }
            return chatGPTSnapshot
        }
        let cursor = StubProvider(id: .cursor, detected: { false }, keepsCached: true) {
            Issue.record("An undetected provider without a cached reading must never be fetched")
            throw ProviderIssue.notConfigured
        }
        let store = UsageStore(
            settings: settings,
            providers: [.antigravity: antigravity, .chatgpt: chatgpt, .cursor: cursor],
            loadCache: false,
            requestClaudeDesktopAccess: {
                Issue.record("Refreshes must never request Keychain permission")
            }
        )

        store.start()
        while store.isRefreshing { await Task.yield() }
        #expect(store.states[.antigravity]?.snapshot == antigravitySnapshot)
        #expect(store.states[.chatgpt]?.snapshot == chatGPTSnapshot)
        #expect(store.visibleProviders.contains(.antigravity))
        #expect(store.visibleProviders.contains(.chatgpt))

        isDetected.withLock { $0 = false }
        shouldFail.withLock { $0 = true }
        store.refresh()
        while store.isRefreshing { await Task.yield() }
        #expect(store.visibleProviders == [.antigravity])
        #expect(store.states[.antigravity]?.snapshot == antigravitySnapshot)
        #expect(store.states[.antigravity]?.issue == failure)
        #expect(!store.visibleProviders.contains(.chatgpt))
        #expect(!store.visibleProviders.contains(.cursor))

        // An explicit disable still hides a retained reading and stops its fetches.
        let fetchesBeforeDisable = fetches.withLock { $0 }
        settings.setEnabled(.antigravity, false)
        while store.isRefreshing { await Task.yield() }
        #expect(store.visibleProviders.isEmpty)
        #expect(store.states[.antigravity]?.snapshot == antigravitySnapshot)
        #expect(fetches.withLock { $0 } == fetchesBeforeDisable)

        let recovered = ProviderSnapshot(provider: .antigravity, plan: nil, metrics: [
            UsageMetric(id: "antigravity-five", title: "5-hour", usedPercent: 55, window: .fiveHour),
        ])
        reading.withLock { $0 = recovered }
        isDetected.withLock { $0 = true }
        shouldFail.withLock { $0 = false }
        settings.setEnabled(.antigravity, true)
        while store.isRefreshing { await Task.yield() }
        #expect(store.visibleProviders.contains(.antigravity))
        #expect(store.states[.antigravity]?.snapshot == recovered)
        #expect(store.states[.antigravity]?.issue == nil)
    }
}

private struct StubProvider: UsageProvider {
    let id: ProviderID
    let keepsCachedReadingWhenUndetected: Bool
    let detected: @Sendable () -> Bool
    let reading: @Sendable () throws -> ProviderSnapshot

    init(
        id: ProviderID = .claude,
        detected: @escaping @Sendable () -> Bool = { true },
        keepsCached: Bool = false,
        reading: @escaping @Sendable () throws -> ProviderSnapshot
    ) {
        self.id = id
        self.detected = detected
        keepsCachedReadingWhenUndetected = keepsCached
        self.reading = reading
    }

    func detect() async -> Bool { detected() }
    func fetch() async throws -> ProviderSnapshot { try reading() }
}
