import OpenNotchCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: UsageStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginNeedsApproval = LaunchAtLogin.needsApproval

    var body: some View {
        Form {
            Section {
                Picker("Auto refresh", selection: $settings.refreshMinutes) {
                    ForEach(AppSettings.refreshOptions, id: \.self) { minutes in
                        Text(minutes == 60 ? "Every hour" : "Every \(minutes) minutes").tag(minutes)
                    }
                }
                Picker("When closed", selection: $settings.collapsedStyle) {
                    ForEach(CollapsedStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Open on hover", isOn: $settings.hoverToOpen)
                Toggle("Haptic feedback", isOn: $settings.haptics)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLogin.set(enabled)
                        launchAtLogin = LaunchAtLogin.isEnabled || (enabled && LaunchAtLogin.needsApproval)
                        loginNeedsApproval = LaunchAtLogin.needsApproval
                    }
            } header: {
                Text("General")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.collapsedStyle.explanation)
                    if !settings.hoverToOpen {
                        Text("Click the notch to open it.")
                    }
                    if loginNeedsApproval {
                        Text("Allow OpenNotch in System Settings › General › Login Items.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ProviderID.allCases) { provider in
                    ProviderSettingRow(
                        provider: provider,
                        detected: store.detected.contains(provider),
                        state: store.states[provider],
                        isOn: Binding(
                            get: { settings.isEnabled(provider) },
                            set: { settings.setEnabled(provider, $0) }
                        )
                    )
                }
            } header: {
                HStack {
                    Text("Services")
                    Spacer()
                    Button {
                        store.refresh()
                    } label: {
                        Label("Refresh Now", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(store.isRefreshing)
                }
            } footer: {
                Text("OpenNotch only reads sessions these tools already keep on your Mac. Credentials are never copied, stored or refreshed — they are only sent to each service's own server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use Claude Desktop when needed", isOn: Binding(
                    get: { settings.claudeDesktopFallbackEnabled || store.isAuthorizingClaudeDesktop },
                    set: { enabled in Task { await store.setClaudeDesktopFallbackEnabled(enabled) } }
                ))
                .disabled(store.isAuthorizingClaudeDesktop)

                if store.isAuthorizingClaudeDesktop {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Keychain access…").font(.caption)
                    }
                }
                if let issue = store.claudeDesktopAccessIssue {
                    Text("\(issue.title). \(issue.hint(for: .claude))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Claude Desktop fallback")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Off by default. Uses Desktop's Code session when Claude Code is missing, expired or rejected. OpenNotch only reads it; Desktop renews it.")
                    Text("Turning this on may ask for the “Claude Safe Storage” Keychain item. “Always Allow” permits future reads. This key also protects Desktop cookies, so grant access only if you trust OpenNotch with that access.")
                    Text("Background refreshes never ask for permission. After rebuilding OpenNotch, you may need to turn this off and on to allow access again. Desktop's undocumented format may change.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenNotch \(AppInfo.version)")
                        Text("AI usage limits in your notch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            loginNeedsApproval = LaunchAtLogin.needsApproval
        }
    }
}

private struct ProviderSettingRow: View {
    let provider: ProviderID
    let detected: Bool
    let state: ProviderState?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            BrandLogo(provider: provider, size: 20, tint: .primary)
                .frame(width: 28, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!detected)
        }
        .padding(.vertical, 2)
        .help(credentialSource)
    }

    private var status: String {
        guard detected else { return "Not found · \(provider.signInHint)" }
        if let issue = state?.issue { return "\(issue.title) · \(issue.hint(for: provider))" }
        if let snapshot = state?.snapshot {
            let plan = snapshot.plan.map { " · \($0)" } ?? ""
            return "Connected\(plan) · \(credentialSource)"
        }
        return "Waiting · \(provider.credentialSource)"
    }

    private var statusColor: Color {
        guard detected else { return .secondary }
        return state?.issue != nil ? .orange : .secondary
    }

    private var credentialSource: String {
        state?.snapshot?.credentialSource ?? provider.credentialSource
    }
}
