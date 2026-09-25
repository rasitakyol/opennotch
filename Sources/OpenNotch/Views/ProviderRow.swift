import OpenNotchCore
import SwiftUI

/// One tool: identity on the left, its limits in aligned columns on the right.
struct ProviderRow: View {
    let provider: ProviderID
    let state: ProviderState?
    let columns: Int
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Layout.columnGap) {
            identity
                .frame(width: Layout.providerColumn, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Layout.rowInset)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovering ? Palette.rowHover : Palette.row)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    // MARK: Identity

    private var identity: some View {
        HStack(alignment: .top, spacing: 8) {
            BrandLogo(provider: provider, size: 18)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                        .lineLimit(1)
                    statusBadge
                    if hovering, let url = provider.dashboardURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.secondary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open the \(provider.displayName) usage page in your browser")
                        .transition(.opacity)
                    }
                }
                if let plan = state?.snapshot?.plan {
                    Text(plan.uppercased(with: Locale(identifier: "en_US")))
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if state?.isLoading == true && state?.snapshot != nil {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 10, height: 10)
        } else if let issue = state?.issue, state?.snapshot != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Palette.warning)
                .help(staleHelp(issue))
                .accessibilityLabel("Data is stale: \(issue.title)")
        }
    }

    private func staleHelp(_ issue: ProviderIssue) -> String {
        var text = "\(issue.title) — \(issue.hint(for: provider))"
        if let fetched = state?.snapshot?.fetchedAt {
            text += "\nShowing data from \(UsageFormat.ago(fetched, now: now))."
        }
        return text
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let snapshot = state?.snapshot {
            metricGrid(snapshot)
                .opacity(state?.issue == nil ? 1 : 0.72)
        } else if let issue = state?.issue, state?.isLoading != true {
            IssueMessage(provider: provider, issue: issue)
        } else {
            HStack(spacing: Layout.metricGap) {
                ForEach(0..<columns, id: \.self) { _ in SkeletonMetric() }
            }
        }
    }

    private func metricGrid(_ snapshot: ProviderSnapshot) -> some View {
        let metrics = snapshot.metrics
        let rows = stride(from: 0, to: metrics.count, by: columns).map { Array(metrics[$0..<min($0 + columns, metrics.count)]) }
        // A short note (credit balance…) takes a free column instead of adding height.
        let noteFitsInline = snapshot.note != nil && (rows.last?.count ?? 0) < columns

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: Layout.metricGap) {
                    ForEach(rows[index]) { metric in
                        MetricCell(provider: provider, metric: metric, now: now)
                    }
                    if index == rows.count - 1, noteFitsInline, let note = snapshot.note {
                        NoteCell(text: note)
                    }
                }
            }
            if !noteFitsInline, let note = snapshot.note {
                NoteCell(text: note)
            }
        }
    }
}

struct MetricCell: View {
    let provider: ProviderID
    let metric: UsageMetric
    let now: Date

    var body: some View {
        let percent = metric.effectivePercent(now: now)
        let color = Palette.forPercent(percent)

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(metric.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Text(UsageFormat.percent(percent))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: percent))
            }
            UsageBar(fraction: percent / 100, color: color)
            HStack(spacing: 3) {
                if let reset = metric.resetsAt {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 7, weight: .bold))
                    Text(UsageFormat.countdown(to: reset, now: now))
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                if let detail = metric.detail {
                    Text(detail)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Palette.tertiary)
            .frame(height: 11)
        }
        .frame(width: Layout.metricWidth)
        .help(tooltip(percent: percent))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName), \(metric.title)")
        .accessibilityValue(accessibilityValue(percent: percent))
    }

    private func tooltip(percent: Double) -> String {
        var lines = ["\(metric.title): \(UsageFormat.percent(percent)) used"]
        if let detail = metric.detail { lines.append(detail) }
        if let reset = metric.resetsAt { lines.append(UsageFormat.resetSentence(reset, now: now)) }
        return lines.joined(separator: "\n")
    }

    private func accessibilityValue(percent: Double) -> String {
        var text = "\(Int(percent.rounded())) percent used"
        if let reset = metric.resetsAt, reset > now {
            text += ", resets in \(UsageFormat.spokenDuration(reset.timeIntervalSince(now)))"
        }
        return text
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: clamped > 0 ? max(4, proxy.size.width * clamped) : 0)
            }
        }
        .frame(height: 4)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)
    }
}

private struct NoteCell: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "creditcard")
                .font(.system(size: 9))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.tertiary)
        .frame(width: Layout.metricWidth, alignment: .leading)
        .padding(.top, 1)
    }
}

private struct IssueMessage: View {
    let provider: ProviderID
    let issue: ProviderIssue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue == .notConfigured ? "person.crop.circle.badge.questionmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(issue == .notConfigured ? Palette.secondary : Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.primary)
                Text(issue.hint(for: provider))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}

private struct SkeletonMetric: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Capsule().frame(width: 58, height: 8)
                Spacer()
                Capsule().frame(width: 24, height: 8)
            }
            Capsule().frame(height: 4)
            Capsule().frame(width: 44, height: 6)
        }
        .foregroundStyle(Color.white.opacity(pulse ? 0.12 : 0.06))
        .frame(width: Layout.metricWidth)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Loading")
    }
}
