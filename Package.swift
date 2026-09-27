// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenNotch", targets: ["OpenNotch"]),
    ],
    targets: [
        // Credential discovery, provider clients and response parsing. No UI code so it stays testable.
        .target(
            name: "OpenNotchCore",
            path: "Sources/OpenNotchCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The notch app itself (AppKit window management + SwiftUI views).
        .executableTarget(
            name: "OpenNotch",
            dependencies: ["OpenNotchCore"],
            path: "Sources/OpenNotch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenNotchCoreTests",
            dependencies: ["OpenNotchCore"],
            path: "Tests/OpenNotchCoreTests"
        ),
        .testTarget(
            name: "OpenNotchAppTests",
            dependencies: ["OpenNotch"],
            path: "Tests/OpenNotchAppTests"
        ),
    ]
)
