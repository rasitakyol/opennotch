import AppKit
import OpenNotchCore
import SwiftUI

extension ProviderID {
    /// Claude keeps its orange spark; the other marks are monochrome and follow the text colour.
    var keepsBrandColors: Bool { self == .claude }

    /// Optical balance: Amp is a wide wordmark, so it is drawn shorter than the square marks.
    var logoHeightScale: CGFloat { self == .amp ? 0.62 : 1 }
}

/// Official vector logos shipped as SVG in the app bundle (NSImage renders SVG natively, so they stay crisp at any size).
@MainActor
enum LogoLibrary {
    private static var cache: [ProviderID: NSImage] = [:]

    static func image(for provider: ProviderID) -> NSImage? {
        if let cached = cache[provider] { return cached }
        guard let url = url(for: provider), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = !provider.keepsBrandColors
        cache[provider] = image
        return image
    }

    private static func url(for provider: ProviderID) -> URL? {
        if let bundled = Bundle.main.url(forResource: provider.rawValue, withExtension: "svg", subdirectory: "Logos") {
            return bundled
        }
        // `swift run` during development: read straight from the repository.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = repository.appendingPathComponent("Resources/Logos/\(provider.rawValue).svg")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}

struct BrandLogo: View {
    let provider: ProviderID
    var size: CGFloat
    var tint: Color = Palette.primary

    var body: some View {
        let height = size * provider.logoHeightScale
        Group {
            if let image = LogoLibrary.image(for: provider) {
                let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
                if provider.keepsBrandColors {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(aspect, contentMode: .fit)
                } else {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(aspect, contentMode: .fit)
                        .foregroundStyle(tint)
                }
            } else {
                Text(provider.displayName.prefix(1))
                    .font(.system(size: size * 0.8, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
        .frame(height: height)
        .frame(minWidth: size, minHeight: size)
        .accessibilityHidden(true)
    }
}
