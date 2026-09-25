import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(settings: AppSettings, store: UsageStore) {
        let host = NSHostingController(rootView: SettingsView(settings: settings, store: store))
        window = NSWindow(contentViewController: host)
        window.title = "OpenNotch Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OpenNotchSettings")
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
