import Foundation
import Observation
import OpenNotchCore
import os

@MainActor
@Observable
final class UsageStore {
    private(set) var states: [ProviderID: ProviderState] = [:]
    /// Providers whose credentials exist on this Mac.
    private(set) var detected: Set<ProviderID> = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var nextRefresh: Date?
    private(set) var hasDetected = false
    private(set) var isAuthorizingClaudeDesktop = false
    private(set) var claudeDesktopAccessIssue: ProviderIssue?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let providers: [ProviderID: any UsageProvider]
    @ObservationIgnored private let requestClaudeDesktopAccess: @Sendable () async throws -> Void
    @ObservationIgnored private let cache: SnapshotCache?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private let logger = Logger(subsystem: "app.opennotch.OpenNotch", category: "store")

    /// Automatic refreshes never run closer together than this, even around window resets.
    private static let minimumGap: TimeInterval = 60

    init(
        settings: AppSettings,
        providers: [ProviderID: any UsageProvider]? = nil,
        loadCache: Bool = true,
        requestClaudeDesktopAccess: @escaping @Sendable () async throws -> Void = {
            try await ClaudeDesktopCredentials().requestAccessFromSettings()
        }
    ) {
        self.settings = settings
        self.requestClaudeDesktopAccess = requestClaudeDesktopAccess
        self.providers = providers ?? ProviderRegistry.makeAll(
            claudeDesktopFallbackEnabled: {
                await MainActor.run { settings.claudeDesktopFallbackEnabled && settings.isEnabled(.claude) }
            }
        )
        // Demo/test stores must not read or write the real usage cache.
        cache = loadCache ? SnapshotCache() : nil
        if let cache { states = cache.load() }
    }

    /// Called only by the Settings toggle. Loading preferences, detection, probes and refreshes never
    /// use this interactive path. Persist the opt-in only after the user permits a successful read.
    func setClaudeDesktopFallbackEnabled(_ enabled: Bool) async {
        guard !isAuthorizingClaudeDesktop else { return }
        claudeDesktopAccessIssue = nil
        guard enabled else {
            settings.claudeDesktopFallbackEnabled = false
            return
        }
        guard !settings.claudeDesktopFallbackEnabled else { return }
        isAuthorizingClaudeDesktop = true
        defer { isAuthorizingClaudeDesktop = false }
        do {
            try await requestClaudeDesktopAccess()
            settings.claudeDesktopFallbackEnabled = true
        } catch let issue as ProviderIssue {
            claudeDesktopAccessIssue = issue
        } catch {
            claudeDesktopAccessIssue = .claudeDesktop(.keychainUnavailable)
        }
    }

    /// A store filled with invented numbers, for rendering documentation images.
    static func demo(settings: AppSettings, now: Date = Date()) -> UsageStore {
        let store = UsageStore(settings: settings, providers: [:], loadCache: false)
        store.states = DemoData.states(now: now)
        store.detected = Set(ProviderID.allCases)
        store.hasDetected = true
        store.lastRefresh = now.addingTimeInterval(-120)
        return store
    }

    /// Enabled providers that have a session on this Mac, in the order chosen in Settings.
    var visibleProviders: [ProviderID] {
        settings.providerOrder.filter { detected.contains($0) && settings.isEnabled($0) }
    }

    var critical: CriticalMetric? {
        UsageSummary.mostCritical(states, providers: visibleProviders)
    }

    func start() {
        settings.onFetchSettingsChange = { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    /// Re-reads every enabled provider. Cards update one by one as each backend answers.
    func refresh() {
        // A request that arrives mid-refresh (e.g. a provider was just enabled) runs right after it.
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        timer?.cancel()

        Task {
            await detect()
            let targets = visibleProviders
            for provider in targets {
                states[provider, default: ProviderState()].isLoading = true
            }

            await withTaskGroup(of: (ProviderID, Result<ProviderSnapshot, ProviderIssue>).self) { group in
                for provider in targets {
                    guard let client = providers[provider] else { continue }
                    group.addTask {
                        do {
                            return (provider, .success(try await client.fetch()))
                        } catch let issue as ProviderIssue {
                            return (provider, .failure(issue))
                        } catch {
                            return (provider, .failure(.unexpected(error.localizedDescription)))
                        }
                    }
                }
                for await (provider, result) in group {
                    apply(result, to: provider)
                }
            }

            lastRefresh = Date()
            isRefreshing = false
            cache?.save(states)
            if refreshQueued {
                refreshQueued = false
                refresh()
            } else {
                scheduleNext()
            }
        }
    }

    /// After sleep the timer may be long overdue; catch up immediately in that case.
    func handleWake() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < settings.refreshInterval {
            scheduleNext()
        } else {
            refresh()
        }
    }

    private func detect() async {
        var found: Set<ProviderID> = []
        for (id, provider) in providers {
            if await provider.detect() { found.insert(id) }
        }
        detected = found
        hasDetected = true
    }

    private func apply(_ result: Result<ProviderSnapshot, ProviderIssue>, to provider: ProviderID) {
        var state = states[provider] ?? ProviderState()
        state.isLoading = false
        state.lastAttempt = Date()
        switch result {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.issue = nil
        case .failure(let issue):
            // Keep the previous numbers; the UI marks them as stale instead of going blank.
            state.issue = issue
            logger.notice("\(provider.rawValue, privacy: .public) refresh failed: \(issue.title, privacy: .public)")
        }
        states[provider] = state
    }

    /// Next tick is the regular interval, pulled earlier to just after the next window reset so a
    /// freshly reset 5-hour limit shows up without waiting a full interval.
    private func scheduleNext() {
        timer?.cancel()
        let now = Date()
        var next = now.addingTimeInterval(settings.refreshInterval)
        if let reset = UsageSummary.upcomingResets(states).min() {
            let afterReset = reset.addingTimeInterval(45)
            if afterReset < next { next = afterReset }
        }
        next = max(next, now.addingTimeInterval(Self.minimumGap))
        nextRefresh = next

        let delay = next.timeIntervalSince(now)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
