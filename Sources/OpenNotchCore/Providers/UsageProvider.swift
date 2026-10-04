import Foundation

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Keep showing a cached reading when detection fails, so fetch can explain why (e.g. a closed app).
    var keepsCachedReadingWhenUndetected: Bool { get }

    /// Cheap local check that the tool's credentials exist. Never touches the network.
    func detect() async -> Bool

    /// Reads the local session and asks the tool's own backend for current usage.
    /// Throws `ProviderIssue` for every expected failure.
    func fetch() async throws -> ProviderSnapshot
}

public extension UsageProvider {
    var keepsCachedReadingWhenUndetected: Bool { false }
}

public enum ProviderRegistry {
    public static func makeAll(
        http: HTTPClient = .shared,
        claudeDesktop: ClaudeDesktopCredentials = .init(),
        claudeDesktopFallbackEnabled: @escaping @Sendable () async -> Bool = { false }
    ) -> [ProviderID: any UsageProvider] {
        [
            .claude: ClaudeProvider(http: http, desktop: claudeDesktop, desktopFallbackEnabled: claudeDesktopFallbackEnabled),
            .chatgpt: ChatGPTProvider(http: http),
            .cursor: CursorProvider(http: http),
            .devin: DevinProvider(http: http),
            .antigravity: AntigravityProvider(http: http),
            .amp: AmpProvider(http: http),
        ]
    }
}
