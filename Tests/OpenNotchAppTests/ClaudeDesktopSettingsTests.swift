import Foundation
import os
import Testing
@testable import OpenNotch
import OpenNotchCore

@Suite("Claude Desktop opt-in settings")
@MainActor
struct ClaudeDesktopSettingsTests {
    // Each test uses its own preference domain and never constructs a disk-backed SnapshotCache.
    private func defaults() -> (String, UserDefaults) {
        let domain = "app.opennotch.tests.\(UUID().uuidString)"
        return (domain, UserDefaults(suiteName: domain)!)
    }

    @Test func startsOffAndRestoresOptInWithoutRequestingAccess() {
        let (domain, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.claudeDesktopFallbackEnabled)
        settings.claudeDesktopFallbackEnabled = true
        let restored = AppSettings(defaults: defaults)
        #expect(restored.claudeDesktopFallbackEnabled)
        _ = UsageStore(settings: restored, providers: [:], loadCache: false, requestClaudeDesktopAccess: {
            Issue.record("Restoring preferences must never authorize Keychain access")
        })
    }

    @Test func successfulExplicitEnablePersistsAndRefreshesThenDisablesWithoutAccess() async {
        let (domain, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        let authorizations = OSAllocatedUnfairLock(initialState: 0)
        let store = UsageStore(settings: settings, providers: [:], loadCache: false, requestClaudeDesktopAccess: {
            authorizations.withLock { $0 += 1 }
        })
        var fetchChanges = 0
        settings.onFetchSettingsChange = { fetchChanges += 1 }
        await store.setClaudeDesktopFallbackEnabled(true)
        #expect(settings.claudeDesktopFallbackEnabled)
        #expect(AppSettings(defaults: defaults).claudeDesktopFallbackEnabled)
        #expect(store.claudeDesktopAccessIssue == nil)
        #expect(!store.isAuthorizingClaudeDesktop)
        await store.setClaudeDesktopFallbackEnabled(true) // Already enabled; do not prompt twice.
        await store.setClaudeDesktopFallbackEnabled(false)
        #expect(!AppSettings(defaults: defaults).claudeDesktopFallbackEnabled)
        #expect(authorizations.withLock { $0 } == 1)
        #expect(fetchChanges == 2)
    }

    @Test func deniedEnableKeepsOptInOffAndDoesNotFetch() async {
        let (domain, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore(settings: settings, providers: [:], loadCache: false, requestClaudeDesktopAccess: {
            throw ProviderIssue.claudeDesktop(.accessRequired)
        })
        settings.onFetchSettingsChange = { Issue.record("Denied access must not enable fetching") }
        await store.setClaudeDesktopFallbackEnabled(true)
        #expect(!settings.claudeDesktopFallbackEnabled)
        #expect(!AppSettings(defaults: defaults).claudeDesktopFallbackEnabled)
        #expect(store.claudeDesktopAccessIssue == .claudeDesktop(.accessRequired))
        #expect(!store.isAuthorizingClaudeDesktop)
    }

    @Test func explicitReauthorizationKeepsOptInAndRefreshesOnlyOnSuccess() async {
        let (domain, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.claudeDesktopFallbackEnabled = true
        let denied = OSAllocatedUnfairLock(initialState: true)
        let authorizations = OSAllocatedUnfairLock(initialState: 0)
        let store = UsageStore(settings: settings, providers: [:], loadCache: false, requestClaudeDesktopAccess: {
            authorizations.withLock { $0 += 1 }
            if denied.withLock({ $0 }) { throw ProviderIssue.claudeDesktop(.accessRequired) }
        })
        var fetchChanges = 0
        settings.onFetchSettingsChange = { fetchChanges += 1 }

        await store.reauthorizeClaudeDesktop()
        #expect(settings.claudeDesktopFallbackEnabled)
        #expect(store.claudeDesktopAccessIssue == .claudeDesktop(.accessRequired))
        #expect(fetchChanges == 0)

        denied.withLock { $0 = false }
        await store.reauthorizeClaudeDesktop()
        #expect(store.claudeDesktopAccessIssue == nil)
        #expect(!store.isAuthorizingClaudeDesktop)
        #expect(AppSettings(defaults: defaults).claudeDesktopFallbackEnabled)
        #expect(fetchChanges == 1)
        #expect(authorizations.withLock { $0 } == 2)
    }

    @Test func reauthorizationCannotEnableAnOptedOutIntegration() async {
        let (domain, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore(settings: settings, providers: [:], loadCache: false, requestClaudeDesktopAccess: {
            Issue.record("Reauthorization must not read Keychain before opting in")
        })
        await store.reauthorizeClaudeDesktop()
        #expect(!settings.claudeDesktopFallbackEnabled)
    }

    @Test func reauthorizationCannotPromptTwiceWhilePending() async {
        let (domain, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.claudeDesktopFallbackEnabled = true
        let gate = AuthorizationGate()
        let store = UsageStore(settings: settings, providers: [:], loadCache: false, requestClaudeDesktopAccess: {
            await gate.wait()
        })
        let authorizing = Task { await store.reauthorizeClaudeDesktop() }
        while !store.isAuthorizingClaudeDesktop { await Task.yield() }
        await store.reauthorizeClaudeDesktop()
        await store.setClaudeDesktopFallbackEnabled(true)
        await gate.finish()
        await authorizing.value
        #expect(await gate.calls == 1)
    }

    @Test func preferenceIsNotEnabledWhileAuthorizationIsPending() async {
        let (domain, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        let gate = AuthorizationGate()
        let store = UsageStore(settings: settings, providers: [:], loadCache: false, requestClaudeDesktopAccess: {
            await gate.wait()
        })
        let enabling = Task { await store.setClaudeDesktopFallbackEnabled(true) }
        while !store.isAuthorizingClaudeDesktop { await Task.yield() }
        #expect(!settings.claudeDesktopFallbackEnabled)
        await store.setClaudeDesktopFallbackEnabled(true) // Duplicate action is ignored while pending.
        await gate.finish()
        await enabling.value
        #expect(settings.claudeDesktopFallbackEnabled)
        #expect(await gate.calls == 1)
    }
}

private actor AuthorizationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    private(set) var calls = 0

    func wait() async {
        calls += 1
        guard !finished else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}
