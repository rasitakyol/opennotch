import Foundation
import Testing
@testable import OpenNotch
import OpenNotchCore

@Suite("Provider order and grid cells")
@MainActor
struct ProviderOrderTests {
    @Test func defaultsToTheBuiltInOrderAndPersistsMoves() {
        let domain = "app.opennotch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.providerOrder == ProviderID.allCases)
        settings.providerOrder = [.amp] + ProviderID.allCases.filter { $0 != .amp }
        #expect(AppSettings(defaults: defaults).providerOrder.first == .amp)
    }

    @Test func draggingOntoARowTakesItsPlace() {
        let domain = "app.opennotch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        let settings = AppSettings(defaults: defaults)
        settings.moveProvider(.claude, to: .devin)
        #expect(settings.providerOrder == [.chatgpt, .cursor, .devin, .claude, .antigravity, .amp])
        settings.moveProvider(.amp, to: .chatgpt)
        #expect(settings.providerOrder == [.amp, .chatgpt, .cursor, .devin, .claude, .antigravity])
        settings.moveProvider(.amp, to: .amp)
        #expect(settings.providerOrder.first == .amp)
    }

    @Test func providersMissingFromASavedOrderKeepTheirDefaultNeighbour() {
        // Saved before Antigravity existed, with Amp moved to the top.
        let order = AppSettings.completeOrder([.amp, .claude, .chatgpt, .cursor, .devin])
        #expect(order == [.antigravity, .amp, .claude, .chatgpt, .cursor, .devin])
        #expect(AppSettings.completeOrder([.devin, .devin]) == ProviderID.allCases)
    }

    @Test func limitsOfOnePoolShareACell() {
        let snapshot = ProviderSnapshot(provider: .antigravity, plan: nil, metrics: [
            UsageMetric(id: "g5", title: "Gemini 5-hour", usedPercent: 10, window: .fiveHour),
            UsageMetric(id: "gw", title: "Gemini weekly", usedPercent: 20, window: .weekly),
            UsageMetric(id: "o5", title: "Other models 5-hour", usedPercent: 30, window: .fiveHour, group: "Other models"),
            UsageMetric(id: "ow", title: "Other models weekly", usedPercent: 40, window: .weekly, group: "Other models"),
        ])
        let cells = GridCell.cells(for: snapshot)
        #expect(cells.map(\.id) == ["g5", "gw", "group.Other models"])
        guard case .group(_, let members) = cells.last else {
            Issue.record("Expected the pool to be one cell")
            return
        }
        #expect(members.map(\.id) == ["o5", "ow"])
    }
}
