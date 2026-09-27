import Foundation
import Observation
import OpenNotchCore

/// What the notch shows while it is closed.
enum CollapsedStyle: String, CaseIterable, Identifiable {
    case critical
    case all
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .critical: "Most critical limit"
        case .all: "All services"
        case .minimal: "Notch only"
        }
    }

    var explanation: String {
        switch self {
        case .critical: "Shows the logo and percentage of the limit closest to running out next to the notch."
        case .all: "Shows a small usage ring for every service next to the notch."
        case .minimal: "Adds nothing while closed; details open from the notch."
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let refreshOptions = [5, 10, 15, 30, 60]

    private enum Keys {
        static let refreshMinutes = "refreshMinutes"
        static let collapsedStyle = "collapsedStyle"
        static let disabledProviders = "disabledProviders"
        static let hoverToOpen = "hoverToOpen"
        static let haptics = "haptics"
        static let claudeDesktopFallbackEnabled = "claudeDesktopFallbackEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Called when a setting that affects fetching changes (interval, enabled providers).
    @ObservationIgnored var onFetchSettingsChange: (() -> Void)?

    var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
            onFetchSettingsChange?()
        }
    }

    var collapsedStyle: CollapsedStyle {
        didSet { defaults.set(collapsedStyle.rawValue, forKey: Keys.collapsedStyle) }
    }

    var disabledProviders: Set<ProviderID> {
        didSet {
            defaults.set(disabledProviders.map(\.rawValue).sorted(), forKey: Keys.disabledProviders)
            onFetchSettingsChange?()
        }
    }

    var hoverToOpen: Bool {
        didSet { defaults.set(hoverToOpen, forKey: Keys.hoverToOpen) }
    }

    var haptics: Bool {
        didSet { defaults.set(haptics, forKey: Keys.haptics) }
    }

    var claudeDesktopFallbackEnabled: Bool {
        didSet {
            defaults.set(claudeDesktopFallbackEnabled, forKey: Keys.claudeDesktopFallbackEnabled)
            onFetchSettingsChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let minutes = defaults.integer(forKey: Keys.refreshMinutes)
        refreshMinutes = Self.refreshOptions.contains(minutes) ? minutes : 15
        collapsedStyle = CollapsedStyle(rawValue: defaults.string(forKey: Keys.collapsedStyle) ?? "") ?? .critical
        disabledProviders = Set((defaults.stringArray(forKey: Keys.disabledProviders) ?? []).compactMap(ProviderID.init(rawValue:)))
        hoverToOpen = defaults.object(forKey: Keys.hoverToOpen) as? Bool ?? true
        haptics = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        claudeDesktopFallbackEnabled = defaults.bool(forKey: Keys.claudeDesktopFallbackEnabled)
    }

    var refreshInterval: TimeInterval { TimeInterval(refreshMinutes * 60) }

    func isEnabled(_ provider: ProviderID) -> Bool {
        !disabledProviders.contains(provider)
    }

    func setEnabled(_ provider: ProviderID, _ enabled: Bool) {
        if enabled {
            disabledProviders.remove(provider)
        } else {
            disabledProviders.insert(provider)
        }
    }
}
