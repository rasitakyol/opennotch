import Foundation
import OpenNotchCore

/// `OpenNotch --probe`: prints what each provider returns, for diagnosing a setup from Terminal.
/// Only usage figures and error titles are printed — never credentials.
enum Probe {
    static func run() -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let providers = ProviderRegistry.makeAll()
            for id in ProviderID.allCases {
                guard let provider = providers[id] else { continue }
                guard await provider.detect() else {
                    print("\(id.displayName): not signed in")
                    continue
                }
                do {
                    let snapshot = try await provider.fetch()
                    print("\(id.displayName)\(snapshot.plan.map { " (\($0))" } ?? "")")
                    for metric in snapshot.metrics {
                        let reset = metric.resetsAt.map { "↻ \(UsageFormat.countdown(to: $0))" } ?? ""
                        let detail = metric.detail.map { " · \($0)" } ?? ""
                        let title = metric.title.padding(toLength: 22, withPad: " ", startingAt: 0)
                        let percent = UsageFormat.percent(metric.usedPercent).padding(toLength: 6, withPad: " ", startingAt: 0)
                        print("  \(title)\(percent)\(reset)\(detail)")
                    }
                    if let note = snapshot.note { print("  \(note)") }
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
