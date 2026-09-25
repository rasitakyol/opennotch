import OpenNotchCore
import SwiftUI

/// The open notch: a header aligned with the camera housing and one row per tool.
struct ExpandedView: View {
    let model: NotchViewModel

    private var store: UsageStore { model.store }

    var body: some View {
        VStack(spacing: 8) {
            header
                .frame(height: model.geometry.notchHeight)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                if store.visibleProviders.isEmpty {
                    EmptyStateView(isSearching: !store.hasDetected)
                } else {
                    VStack(spacing: Layout.rowSpacing) {
                        ForEach(store.visibleProviders) { provider in
                            ProviderRow(
                                provider: provider,
                                state: store.states[provider],
                                columns: model.metricColumns,
                                now: context.date
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Layout.padding)
        .padding(.bottom, Layout.padding)
        .frame(width: model.expandedWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                Text("Usage")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(statusText(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(scheduleHelp)

            // Keep the camera housing clear.
            Color.clear.frame(width: model.geometry.notchWidth + 16)

            HStack(spacing: 2) {
                HeaderButton(symbol: "arrow.clockwise", help: "Refresh now", busy: store.isRefreshing) {
                    store.refresh()
                }
                HeaderButton(symbol: "gearshape.fill", help: "Settings") {
                    model.showSettings()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func statusText(now: Date) -> String {
        if store.isRefreshing { return "· refreshing…" }
        guard let last = store.lastRefresh else { return "" }
        return "· \(UsageFormat.ago(last, now: now))"
    }

    private var scheduleHelp: String {
        guard let next = store.nextRefresh else { return "Refreshes automatically every \(model.settings.refreshMinutes) minutes" }
        return "Next automatic refresh: \(UsageFormat.absolute(next))"
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    var busy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Palette.secondary)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(hovering ? Palette.primary : Palette.secondary)
                }
            }
            .frame(width: 26, height: 22)
            .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)).frame(width: 24, height: 24))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct EmptyStateView: View {
    let isSearching: Bool

    var body: some View {
        VStack(spacing: 6) {
            if isSearching {
                ProgressView().controlSize(.small)
                Text("Looking for sessions…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.secondary)
                Text("No sessions to track")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Text("Sign in to Claude Code, Codex, Cursor, Devin or Amp, or turn services on in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.row))
    }
}
