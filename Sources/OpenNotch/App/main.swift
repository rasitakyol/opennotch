import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--probe") {
    Probe.run()
}

MainActor.assumeIsolated {
    if let flag = arguments.firstIndex(of: "--render-docs") {
        DocsRenderer.run(outputDirectory: arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "docs/images")
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
