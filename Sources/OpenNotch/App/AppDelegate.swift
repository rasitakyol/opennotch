import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: UsageStore!
    private var notch: NotchController!
    private var settingsWindow: SettingsWindowController?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installKeyboardShortcuts()
        settings = AppSettings()
        store = UsageStore(settings: settings)

        let model = NotchViewModel(store: store, settings: settings)
        model.openSettings = { [weak self] in self?.showSettings() }
        notch = NotchController(model: model)

        store.start()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.handleWake() }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows settings, since there is no Dock icon or window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, store: store)
        }
        settingsWindow?.show()
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        showSettings()
    }

    /// Agent apps show no menu bar, but a main menu still provides ⌘, ⌘W and ⌘Q while settings is open.
    private func installKeyboardShortcuts() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsFromMenu(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit OpenNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }
}
