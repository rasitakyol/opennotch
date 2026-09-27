import Foundation
import OpenNotchCore

/// `OpenNotch --probe`: prints what each provider returns, for diagnosing a setup from Terminal.
/// Only usage figures and error titles are printed — never credentials.
enum Probe {
    static func run() -> Never {
        // Capture UI-owned preferences before blocking the main thread on the probe's completion.
        let desktopEnabled = MainActor.assumeIsolated {
            let settings = AppSettings()
            return settings.claudeDesktopFallbackEnabled && settings.isEnabled(.claude)
        }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let providers = ProviderRegistry.makeAll(claudeDesktopFallbackEnabled: { desktopEnabled })
            for id in ProviderID.allCases {
                guard let provider = providers[id] else { continue }
                guard await provider.detect() else {
                    print("\(id.displayName): not signed in")
                    continue
                }
                do {
                    let snapshot = try await provider.fetch()
                    print("\(id.displayName)\(snapshot.plan.map { " (\($0))" } ?? "")")
                    if let source = snapshot.credentialSource { print("  Source: \(source)") }
                    for metric in snapshot.metrics {
                        let reset = metric.resetsAt.map { "↻ \(UsageFormat.countdown(to: $0))" } ?? ""
                        let detail = metric.detail.map { " · \($0)" } ?? ""
                        let title = metric.title.padding(toLength: 22, withPad: " ", startingAt: 0)
                        let percent = UsageFormat.percent(metric.usedPercent).padding(toLength: 6, withPad: " ", startingAt: 0)
                        print("  \(title)\(percent)\(reset)\(detail)")
                    }
                    if let balance = snapshot.balance {
                        print("  \(balance.title.padding(toLength: 22, withPad: " ", startingAt: 0))\(UsageFormat.dollars(balance.amount)) left")
                    }
                } catch let issue as ProviderIssue {
                    print("\(id.displayName): \(issue.title) — \(issue.hint(for: id))")
                } catch {
                    print("\(id.displayName): \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}
