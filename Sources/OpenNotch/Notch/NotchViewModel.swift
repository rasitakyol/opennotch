import AppKit
import Observation
import OpenNotchCore
import SwiftUI

enum Layout {
    static let padding: CGFloat = 12
    static let rowInset: CGFloat = 12
    static let rowSpacing: CGFloat = 6
    static let providerColumn: CGFloat = 112
    static let columnGap: CGFloat = 14
    static let metricWidth: CGFloat = 140
    static let metricGap: CGFloat = 12
    static let maxMetricColumns = 3

    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 10
    static let expandedTopRadius: CGFloat = 14
    static let expandedBottomRadius: CGFloat = 26

    static let criticalEarWidth: CGFloat = 44
    static let ringSize: CGFloat = 20
    static let ringSpacing: CGFloat = 5
}

extension Animation {
    static let notchOpen = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let notchClose = Animation.spring(response: 0.34, dampingFraction: 0.95)
}

@MainActor
@Observable
final class NotchViewModel {
    var isExpanded = false
    var geometry = NotchGeometry.placeholder
    /// Natural size of the expanded content, measured by the view.
    var measuredExpandedSize: CGSize = .zero

    let store: UsageStore
    let settings: AppSettings
    @ObservationIgnored var openSettings: () -> Void = {}
    /// Lets the window controller re-evaluate click-through as soon as the panel opens or closes.
    @ObservationIgnored var onExpansionChange: (() -> Void)?

    init(store: UsageStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    // MARK: Collapsed

    /// Providers that have something to draw in the ears.
    var providersWithData: [ProviderID] {
        store.visibleProviders.filter { store.states[$0]?.snapshot != nil }
    }

    var earWidth: CGFloat {
        switch settings.collapsedStyle {
        case .minimal:
            return 0
        case .critical:
            return store.critical == nil ? 0 : Layout.criticalEarWidth
        case .all:
            let perSide = (providersWithData.count + 1) / 2
            guard perSide > 0 else { return 0 }
            return CGFloat(perSide) * Layout.ringSize + CGFloat(perSide - 1) * Layout.ringSpacing + 16
        }
    }

    var collapsedSize: CGSize {
        CGSize(width: geometry.notchWidth + 2 * earWidth, height: geometry.notchHeight)
    }

    // MARK: Expanded

    var metricColumns: Int {
        let counts = store.visibleProviders.map { provider -> Int in
            guard let snapshot = store.states[provider]?.snapshot else { return 1 }
            return GridCell.cells(for: snapshot).count
        }
        return min(Layout.maxMetricColumns, max(1, counts.max() ?? 1))
    }

    var expandedWidth: CGFloat {
        let columns = CGFloat(metricColumns)
        let row = 2 * Layout.rowInset + Layout.providerColumn + Layout.columnGap
            + columns * Layout.metricWidth + (columns - 1) * Layout.metricGap
        return max(row + 2 * Layout.padding, geometry.notchWidth + 2 * 170)
    }

    var expandedSize: CGSize {
        measuredExpandedSize.height > 0
            ? CGSize(width: expandedWidth, height: measuredExpandedSize.height)
            : CGSize(width: expandedWidth, height: geometry.notchHeight + 200)
    }

    /// The black body currently drawn, excluding the small top flares.
    var bodySize: CGSize {
        isExpanded ? expandedSize : collapsedSize
    }

    func expand() {
        guard !isExpanded else { return }
        withAnimation(.notchOpen) { isExpanded = true }
        if settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        onExpansionChange?()
    }

    func collapse() {
        guard isExpanded else { return }
        withAnimation(.notchClose) { isExpanded = false }
        onExpansionChange?()
    }

    /// The panel floats above every window, so it closes first to keep the settings window unobstructed.
    func showSettings() {
        collapse()
        openSettings()
    }
}
