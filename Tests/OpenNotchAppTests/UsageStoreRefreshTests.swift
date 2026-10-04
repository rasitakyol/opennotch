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
}

private struct StubProvider: UsageProvider {
    let id = ProviderID.claude
    let reading: @Sendable () throws -> ProviderSnapshot

    init(reading: @escaping @Sendable () throws -> ProviderSnapshot) { self.reading = reading }
    func detect() async -> Bool { true }
    func fetch() async throws -> ProviderSnapshot { try reading() }
}
