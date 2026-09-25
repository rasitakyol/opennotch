import OpenNotchCore
import SwiftUI

/// The closed notch: the camera housing in the middle with optional "ears" on either side.
struct CollapsedView: View {
    let model: NotchViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 0) {
                leadingEar(now: context.date)
                    .frame(width: model.earWidth)
                Color.clear
                    .frame(width: model.geometry.notchWidth)
                trailingEar(now: context.date)
                    .frame(width: model.earWidth)
            }
            .frame(height: model.geometry.notchHeight)
        }
        // Clicks, hover and the context menu are handled by the hot zone window above this view.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func leadingEar(now: Date) -> some View {
        switch model.settings.collapsedStyle {
        case .minimal:
            EmptyView()
        case .critical:
            if let critical = model.store.critical {
                BrandLogo(provider: critical.provider, size: 15)
                    .padding(.leading, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        case .all:
            rings(Array(model.providersWithData.prefix((model.providersWithData.count + 1) / 2)), now: now)
        }
    }

    @ViewBuilder
    private func trailingEar(now: Date) -> some View {
        switch model.settings.collapsedStyle {
        case .minimal:
            EmptyView()
        case .critical:
            if let critical = model.store.critical {
                Text(UsageFormat.percent(critical.percent))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.forPercent(critical.percent))
                    .contentTransition(.numericText(value: critical.percent))
                    .padding(.trailing, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        case .all:
            rings(Array(model.providersWithData.dropFirst((model.providersWithData.count + 1) / 2)), now: now)
        }
    }

    private func rings(_ providers: [ProviderID], now: Date) -> some View {
        HStack(spacing: Layout.ringSpacing) {
            ForEach(providers) { provider in
                MiniRing(provider: provider, percent: model.store.states[provider]?.snapshot?.peakPercent(now: now) ?? 0)
            }
        }
    }

    private var accessibilitySummary: String {
        guard let critical = model.store.critical else { return "OpenNotch usage" }
        return "OpenNotch. Highest usage: \(critical.provider.displayName) \(critical.metric.title), \(Int(critical.percent.rounded())) percent"
    }
}

/// Tiny progress ring with the provider's logo inside, used when all providers are shown in the ears.
struct MiniRing: View {
    let provider: ProviderID
    let percent: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.track, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, min(percent / 100, 1)))
                .stroke(Palette.forPercent(percent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            BrandLogo(provider: provider, size: 9)
        }
        .frame(width: Layout.ringSize, height: Layout.ringSize)
        .help("\(provider.displayName) \(UsageFormat.percent(percent))")
    }
}
