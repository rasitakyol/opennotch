import Foundation

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }

    /// Cheap local check that the tool's credentials exist. Never touches the network.
    func detect() async -> Bool

    /// Reads the local session and asks the tool's own backend for current usage.
    /// Throws `ProviderIssue` for every expected failure.
    func fetch() async throws -> ProviderSnapshot
}

public enum ProviderRegistry {
    public static func makeAll(http: HTTPClient = .shared) -> [ProviderID: any UsageProvider] {
        [
            .claude: ClaudeProvider(http: http),
            .chatgpt: ChatGPTProvider(http: http),
            .cursor: CursorProvider(http: http),
            .devin: DevinProvider(http: http),
            .amp: AmpProvider(http: http),
        ]
    }
}
