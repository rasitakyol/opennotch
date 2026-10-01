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
        let cells = GridCell.cells(for: snapshot)
        let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: Layout.metricGap) {
                    ForEach(rows[index]) { cell in
                        switch cell {
                        case .metric(let metric):
                            MetricCell(provider: provider, metric: metric, now: now)
                        case .group(let title, let metrics):
                            MetricGroupCell(provider: provider, title: title, metrics: metrics, now: now)
                        case .balance(let balance):
                            BalanceCell(provider: provider, balance: balance)
                        }
                    }
                }
            }
        }
    }
}

enum GridCell: Identifiable {
    case metric(UsageMetric)
    /// Limits of one shared pool, drawn side by side in a single cell.
    case group(title: String, metrics: [UsageMetric])
    case balance(UsageBalance)

    var id: String {
        switch self {
        case .metric(let metric): metric.id
        case .group(let title, _): "group.\(title)"
        case .balance: "balance"
        }
    }

    /// One cell per limit, except that consecutive limits of the same pool share one. A balance (extra
    /// usage, credits…) takes the slot after the limits, like one more column.
    static func cells(for snapshot: ProviderSnapshot) -> [GridCell] {
        var cells: [GridCell] = []
        for metric in snapshot.metrics {
            if let group = metric.group, case .group(group, let members) = cells.last {
                cells[cells.count - 1] = .group(title: group, metrics: members + [metric])
            } else if let group = metric.group {
                cells.append(.group(title: group, metrics: [metric]))
            } else {
                cells.append(.metric(metric))
            }
        }
        if let balance = snapshot.balance { cells.append(.balance(balance)) }
        return cells
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
            CellHeader(title: metric.title, value: UsageFormat.percent(percent), color: color, numericValue: percent)
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
            .cellCaption()
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

/// Several limits of one pool (e.g. a 5-hour and a weekly limit) in the frame and rows of `MetricCell`:
/// the headline is the fullest of them, and the bar slot and caption split into one lane per limit.
struct MetricGroupCell: View {
    static let laneGap: CGFloat = 8

    let provider: ProviderID
    let title: String
    let metrics: [UsageMetric]
    let now: Date

    var body: some View {
        let peak = metrics.map { $0.effectivePercent(now: now) }.max() ?? 0

        VStack(alignment: .leading, spacing: 5) {
            CellHeader(title: title, value: UsageFormat.percent(peak), color: Palette.forPercent(peak), numericValue: peak)
            HStack(spacing: Self.laneGap) {
                ForEach(metrics) { metric in
                    let percent = metric.effectivePercent(now: now)
                    UsageBar(fraction: percent / 100, color: Palette.forPercent(percent))
                }
            }
            HStack(spacing: Self.laneGap) {
                ForEach(metrics) { metric in
                    HStack(spacing: 3) {
                        Text(metric.window.title)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(UsageFormat.percent(metric.effectivePercent(now: now)))
                            .monospacedDigit()
                    }
                }
            }
            .cellCaption()
        }
        .frame(width: Layout.metricWidth)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName), \(title)")
        .accessibilityValue(accessibilityValue)
    }

    private var tooltip: String {
        var lines = [metrics.compactMap(\.detail).first.map { "\(title): \($0)" } ?? title]
        for metric in metrics {
            var line = "\(metric.window.title): \(UsageFormat.percent(metric.effectivePercent(now: now))) used"
            if let reset = metric.resetsAt { line += " · \(UsageFormat.resetSentence(reset, now: now))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private var accessibilityValue: String {
        metrics.map { metric in
            var text = "\(metric.window.title) \(Int(metric.effectivePercent(now: now).rounded())) percent used"
            if let reset = metric.resetsAt, reset > now {
                text += ", resets in \(UsageFormat.spokenDuration(reset.timeIntervalSince(now)))"
            }
            return text
        }
        .joined(separator: "; ")
    }
}

/// Money left beyond the plan, drawn in the same frame and rows as `MetricCell` so it lines up with the
/// limits beside it. A balance has no ceiling to measure against, so the bar's slot stays empty.
struct BalanceCell: View {
    let provider: ProviderID
    let balance: UsageBalance

    var body: some View {
        let amount = UsageFormat.dollars(balance.amount)

        VStack(alignment: .leading, spacing: 5) {
            CellHeader(title: balance.title, value: amount, color: Palette.primary, numericValue: balance.amount)
            Color.clear
                .frame(height: UsageBar.height)
            HStack(spacing: 3) {
                Image(systemName: "creditcard")
                    .font(.system(size: 8, weight: .semibold))
                Text("Balance")
            }
            .cellCaption()
        }
        .frame(width: Layout.metricWidth)
        .help("\(balance.title): \(amount) left")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName), \(balance.title)")
        .accessibilityValue("\(amount) left")
    }
}

/// First line of every grid cell: what it is on the left, the headline figure on the right.
private struct CellHeader: View {
    let title: String
    let value: String
    let color: Color
    /// Drives the rolling-digits transition when the figure changes.
    let numericValue: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(value: numericValue))
        }
    }
}

private extension View {
    /// Last line of every grid cell (reset countdown, detail, balance label).
    func cellCaption() -> some View {
        font(.system(size: 9.5))
            .foregroundStyle(Palette.tertiary)
            .frame(height: 11)
    }
}

struct UsageBar: View {
    static let height: CGFloat = 4

    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                // Stays empty while the label still reads "0%".
                Capsule()
                    .fill(color.gradient)
                    .frame(width: UsageFormat.wholePercent(clamped * 100) > 0 ? max(4, proxy.size.width * clamped) : 0)
            }
        }
        .frame(height: Self.height)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)
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
