import Foundation
import OpenNotchCore
import os

/// Keeps the last readings on disk so the notch has numbers immediately after launch.
/// Only usage figures and plan names are stored — never credentials.
struct SnapshotCache {
    private let url: URL
    private let logger = Logger(subsystem: "app.opennotch.OpenNotch", category: "cache")

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("usage-cache.json")
    }

    func load() -> [ProviderID: ProviderState] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([String: ProviderState].self, from: data) else { return [:] }
        var states: [ProviderID: ProviderState] = [:]
        for (key, var state) in stored {
            guard let provider = ProviderID(rawValue: key) else { continue }
            state.isLoading = false
            states[provider] = state
        }
        return states
    }

    func save(_ states: [ProviderID: ProviderState]) {
        var stored: [String: ProviderState] = [:]
        for (provider, var state) in states {
            state.isLoading = false
            stored[provider.rawValue] = state
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(stored).write(to: url, options: .atomic)
        } catch {
            logger.error("Could not write the cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
