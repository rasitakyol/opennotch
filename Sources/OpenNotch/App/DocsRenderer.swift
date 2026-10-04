import AppKit
import OpenNotchCore
import SwiftUI

/// `OpenNotch --render-docs <dir>`: renders the README images from made-up demo data.
/// Runs offscreen, touches no credentials and makes no network calls.
@MainActor
enum DocsRenderer {
    private static let suite = "app.opennotch.docs"

    static func run(outputDirectory: String) -> Never {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore.demo(settings: settings)
        let model = NotchViewModel(store: store, settings: settings)

        write(expanded(model), to: directory.appendingPathComponent("notch-open.png"))
        settings.collapsedStyle = .critical
        write(closed(model), to: directory.appendingPathComponent("notch-closed.png"))
        settings.collapsedStyle = .all
        write(closed(model), to: directory.appendingPathComponent("notch-closed-all.png"))

        // Recovery previews use invented readings and never invoke the interactive authorization path.
        settings.claudeDesktopFallbackEnabled = true
        let staleStore = UsageStore.demo(settings: settings, issues: [
            .claude: .claudeDesktop(.accessRequired),
            .antigravity: .appNotRunning,
        ])
        write(expanded(NotchViewModel(store: staleStore, settings: settings)), to: directory.appendingPathComponent("notch-stale.png"))
        writeHosted(SettingsView(settings: settings, store: staleStore).environment(\.colorScheme, .dark), to: directory.appendingPathComponent("claude-recovery.png"))
        let errors = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderIssue.offline) })
        let failedStore = UsageStore.demo(settings: settings, issues: errors)
        write(expanded(NotchViewModel(store: failedStore, settings: settings)), to: directory.appendingPathComponent("notch-all-stale.png"))

        defaults.removePersistentDomain(forName: suite)
        print("✓ \(directory.path)")
        exit(0)
    }

    private static func expanded(_ model: NotchViewModel) -> some View {
        ExpandedView(model: model)
            .padding(.horizontal, Layout.expandedTopRadius)
            .background(NotchShape(topRadius: Layout.expandedTopRadius, bottomRadius: Layout.expandedBottomRadius).fill(Color.black))
            .environment(\.colorScheme, .dark)
    }

    /// The closed notch on a strip that suggests the menu bar and wallpaper around it.
    private static func closed(_ model: NotchViewModel) -> some View {
        let size = model.collapsedSize
        return ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.16, blue: 0.3), Color(red: 0.36, green: 0.2, blue: 0.38)],
                startPoint: .leading,
                endPoint: .trailing
            )
            Color.white.opacity(0.07)
                .frame(height: size.height)
            CollapsedView(model: model)
                .frame(width: size.width, height: size.height)
                .padding(.horizontal, Layout.collapsedTopRadius)
                .background(NotchShape(topRadius: Layout.collapsedTopRadius, bottomRadius: Layout.collapsedBottomRadius).fill(Color.black))
        }
        .frame(width: 560, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            print("✗ could not render \(url.lastPathComponent)")
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Form uses AppKit-backed controls that ImageRenderer cannot draw. Host an offscreen window instead.
    private static func writeHosted(_ view: some View, to url: URL) {
        let host = NSHostingView(rootView: view)
        let bounds = NSRect(x: 0, y: 0, width: 480, height: 720)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("✗ could not render \(url.lastPathComponent)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

enum DemoData {
    /// Plausible but invented numbers, chosen to show every severity colour.
    static func states(now: Date) -> [ProviderID: ProviderState] {
        func later(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3_600) }
        let snapshots = [
            ProviderSnapshot(provider: .claude, plan: "Max 5x", metrics: [
                UsageMetric(id: "claude.fiveHour", title: "5-hour", usedPercent: 42, resetsAt: later(2.3), window: .fiveHour),
                UsageMetric(id: "claude.weekly", title: "Weekly", usedPercent: 68, resetsAt: later(61), window: .weekly),
                UsageMetric(id: "claude.weekly.fable", title: "Weekly · Fable", usedPercent: 57, resetsAt: later(61), window: .weekly),
            ], fetchedAt: now),
            ProviderSnapshot(provider: .chatgpt, plan: "Plus", metrics: [
                UsageMetric(id: "chatgpt.fiveHour", title: "5-hour", usedPercent: 18, resetsAt: later(3.8), window: .fiveHour),
                UsageMetric(id: "chatgpt.weekly", title: "Weekly", usedPercent: 35, resetsAt: later(98), window: .weekly),
            ], fetchedAt: now),
            ProviderSnapshot(provider: .cursor, plan: "Pro", metrics: [
                UsageMetric(id: "cursor.auto", title: "Grok & Composer", usedPercent: 24, resetsAt: later(19 * 24), window: .monthly),
                UsageMetric(id: "cursor.api", title: "Other models", usedPercent: 79, resetsAt: later(19 * 24), window: .monthly),
                UsageMetric(id: "cursor.grokbot", title: "Grok Bot", usedPercent: 12, resetsAt: later(4 * 24 + 5), window: .weekly),
            ], fetchedAt: now),
            ProviderSnapshot(provider: .devin, plan: "Pro", metrics: [
                UsageMetric(id: "devin.weekly", title: "Weekly", usedPercent: 91, resetsAt: later(30), window: .weekly),
            ], balance: UsageBalance(title: "Extra usage", amount: 12.5), fetchedAt: now),
            ProviderSnapshot(provider: .antigravity, plan: "Pro", metrics: [
                UsageMetric(id: "antigravity.gemini-5h", title: "Gemini 5-hour", usedPercent: 37, resetsAt: later(3.1), window: .fiveHour),
                UsageMetric(id: "antigravity.gemini-weekly", title: "Gemini weekly", usedPercent: 22, resetsAt: later(5 * 24 + 7), window: .weekly),
                UsageMetric(id: "antigravity.3p-5h", title: "Other models 5-hour", usedPercent: 64, resetsAt: later(1.4), detail: "Claude Opus, Claude Sonnet, GPT-OSS", window: .fiveHour, group: "Other models"),
                UsageMetric(id: "antigravity.3p-weekly", title: "Other models weekly", usedPercent: 48, resetsAt: later(5 * 24 + 7), detail: "Claude Opus, Claude Sonnet, GPT-OSS", window: .weekly, group: "Other models"),
            ], fetchedAt: now),
            ProviderSnapshot(provider: .amp, plan: "Megawatt", metrics: [
                UsageMetric(id: "amp.agent", title: "AI model", usedPercent: 23, resetsAt: later(22 * 24), detail: "$15.40 / $20 left", window: .monthly),
                UsageMetric(id: "amp.orb", title: "Orb", usedPercent: 41, resetsAt: later(22 * 24), detail: "443 / 750 h left", window: .monthly),
            ], balance: UsageBalance(title: "Credits", amount: 6.2), fetchedAt: now),
        ]
        return Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, ProviderState(snapshot: $0, lastAttempt: now)) })
    }
}
