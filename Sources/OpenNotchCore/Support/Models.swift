import Foundation

public enum AppInfo {
    public static let name = "OpenNotch"
    public static let version = "1.0.0"
    public static let userAgent = "OpenNotch/\(version) (macOS)"
}

/// The tools OpenNotch knows how to read usage for, in the order they are shown.
public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case claude
    case chatgpt
    case cursor
    case devin
    case antigravity
    case amp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .cursor: "Cursor"
        case .devin: "Devin"
        case .antigravity: "Antigravity"
        case .amp: "Amp"
        }
    }

    /// Where the credentials come from, shown in settings so the user knows what is being read.
    public var credentialSource: String {
        switch self {
        case .claude: "Claude Code session (Keychain)"
        case .chatgpt: "Codex session (~/.codex/auth.json)"
        case .cursor: "Cursor / Grok Bot session"
        case .devin: "Devin CLI / Devin Desktop session"
        case .antigravity: "Antigravity / agy CLI session"
        case .amp: "Amp CLI session"
        }
    }

    /// How to fix a missing or rejected session.
    public var signInHint: String {
        switch self {
        case .claude: "Sign in with `claude` in Terminal."
        case .chatgpt: "Run `codex login` and sign in with ChatGPT."
        case .cursor: "Sign in to Cursor or Grok Bot."
        case .devin: "Run `devin auth login` in Terminal."
        case .antigravity: "Sign in to Antigravity or run `agy`."
        case .amp: "Run `amp login` in Terminal."
        }
    }

    /// The tool that owns (and refreshes) the token.
    public var refreshHint: String {
        switch self {
        case .claude: "Open Claude Code once to refresh the session."
        case .chatgpt: "Run Codex once to refresh the session."
        case .cursor: "Open Cursor to refresh the session."
        case .devin: "Open Devin to refresh the session."
        case .antigravity: "Open the Antigravity app to update its limits."
        case .amp: "Run Amp to refresh the session."
        }
    }

    public var dashboardURL: URL? {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")
        case .chatgpt: URL(string: "https://chatgpt.com/codex/settings/usage")
        case .cursor: URL(string: "https://cursor.com/dashboard?tab=usage")
        case .devin: URL(string: "https://app.devin.ai")
        // Antigravity shows its limits only inside the app.
        case .antigravity: nil
        case .amp: URL(string: "https://ampcode.com/settings")
        }
    }
}

public enum UsageWindow: String, Codable, Sendable, Hashable {
    case fiveHour
    case daily
    case weekly
    case monthly
    case other

    /// Classifies a rolling window by its length in seconds.
    public init(seconds: Double?) {
        guard let seconds, seconds > 0 else { self = .other; return }
        switch seconds {
        case ..<(7 * 3600): self = .fiveHour
        case ..<(36 * 3600): self = .daily
        case ..<(10 * 86400): self = .weekly
        case (25 * 86400)...: self = .monthly
        default: self = .other
        }
    }

    public var title: String {
        switch self {
        case .fiveHour: "5-hour"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .other: "Period"
        }
    }

    var sortOrder: Int {
        switch self {
        case .fiveHour: 0
        case .daily: 1
        case .weekly: 2
        case .monthly: 3
        case .other: 4
        }
    }
}

/// One limit of one tool, normalised to "percent used".
public struct UsageMetric: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var detail: String?
    public var window: UsageWindow
    /// Limits of one shared pool (e.g. Antigravity's 5-hour and weekly for non-Gemini models) carry the
    /// pool's name here and are drawn together in a single cell titled with it.
    public var group: String?

    public init(id: String, title: String, usedPercent: Double, resetsAt: Date? = nil, detail: String? = nil, window: UsageWindow, group: String? = nil) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.detail = detail
        self.window = window
        self.group = group
    }

    /// Once a window has reset the cached number is no longer true, so it reads as empty until the next fetch.
    public func effectivePercent(now: Date = Date()) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(max(usedPercent, 0), 100)
    }

    public func hasReset(now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// Money on the account beyond the plan's limits (Devin extra usage, Amp credits), in US dollars.
public struct UsageBalance: Codable, Sendable, Hashable {
    public var title: String
    public var amount: Double

    public init(title: String, amount: Double) {
        self.title = title
        self.amount = amount
    }
}

public struct ProviderSnapshot: Codable, Sendable, Equatable {
    public var provider: ProviderID
    public var plan: String?
    public var metrics: [UsageMetric]
    public var balance: UsageBalance?
    public var credentialSource: String?
    public var fetchedAt: Date

    public init(provider: ProviderID, plan: String?, metrics: [UsageMetric], balance: UsageBalance? = nil, credentialSource: String? = nil, fetchedAt: Date = Date()) {
        self.provider = provider
        self.plan = plan
        self.metrics = metrics
        self.balance = balance
        self.credentialSource = credentialSource
        self.fetchedAt = fetchedAt
    }

    public func peakPercent(now: Date = Date()) -> Double {
        metrics.map { $0.effectivePercent(now: now) }.max() ?? 0
    }
}

/// Why a provider could not be refreshed. Thrown by providers and kept in state for the UI.
public enum ProviderIssue: Error, Codable, Sendable, Equatable {
    case notConfigured
    case expired
    case unauthorized
    case rateLimited
    case offline
    case timeout
    case server(status: Int)
    case unexpected(String)
    case claudeDesktop(ClaudeDesktopIssue)

    public var title: String {
        switch self {
        case .notConfigured: "Not signed in"
        case .expired: "Session expired"
        case .unauthorized: "Session rejected"
        case .rateLimited: "Rate limited"
        case .offline: "Offline"
        case .timeout: "Timed out"
        case .server(let status): "Server error (\(status))"
        case .unexpected: "Unexpected response"
        case .claudeDesktop(let issue): issue.title
        }
    }

    public func hint(for provider: ProviderID) -> String {
        switch self {
        case .notConfigured: provider.signInHint
        case .expired: provider.refreshHint
        case .unauthorized: provider.signInHint
        case .rateLimited, .timeout, .server: "Will retry on the next refresh."
        case .offline: "Will refresh when you're back online."
        case .unexpected(let detail): detail
        case .claudeDesktop(let issue): issue.hint
        }
    }
}

public struct ProviderState: Codable, Sendable, Equatable {
    /// Last successful reading. Kept when a later refresh fails so the notch never goes blank.
    public var snapshot: ProviderSnapshot?
    public var issue: ProviderIssue?
    public var lastAttempt: Date?
    public var isLoading: Bool

    public init(snapshot: ProviderSnapshot? = nil, issue: ProviderIssue? = nil, lastAttempt: Date? = nil, isLoading: Bool = false) {
        self.snapshot = snapshot
        self.issue = issue
        self.lastAttempt = lastAttempt
        self.isLoading = isLoading
    }
}

public enum Severity: Int, Comparable, Sendable {
    case normal
    case elevated
    case high
    case critical

    public init(percent: Double) {
        switch percent {
        case ..<50: self = .normal
        case ..<75: self = .elevated
        case ..<90: self = .high
        default: self = .critical
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct CriticalMetric: Sendable, Equatable {
    public let provider: ProviderID
    public let metric: UsageMetric
    public let percent: Double
}

public enum UsageSummary {
    /// The single limit closest to running out across the given providers.
    public static func mostCritical(_ states: [ProviderID: ProviderState], providers: [ProviderID], now: Date = Date()) -> CriticalMetric? {
        var best: CriticalMetric?
        for provider in providers {
            guard let snapshot = states[provider]?.snapshot else { continue }
            for metric in snapshot.metrics {
                let percent = metric.effectivePercent(now: now)
                if best == nil || percent > best!.percent {
                    best = CriticalMetric(provider: provider, metric: metric, percent: percent)
                }
            }
        }
        return best
    }

    /// Future reset moments, used to refresh right after a window rolls over.
    public static func upcomingResets(_ states: [ProviderID: ProviderState], now: Date = Date()) -> [Date] {
        states.values.flatMap { $0.snapshot?.metrics.compactMap(\.resetsAt) ?? [] }.filter { $0 > now }
    }
}
