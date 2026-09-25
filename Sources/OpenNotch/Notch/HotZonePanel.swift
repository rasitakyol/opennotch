import AppKit

/// Invisible strip exactly over the closed notch (and its ears).
///
/// While the notch is closed this is the only thing listening to the pointer: a tracking area reports
/// enter/exit and clicks, so nothing runs while the pointer is elsewhere on screen. It never extends
/// below the menu bar, so clicks on windows under the notch (tab bars, toolbars) are never swallowed.
final class HotZonePanel: NSPanel {
    var onEnter: @MainActor () -> Void = {}
    var onExit: @MainActor () -> Void = {}
    var onClick: @MainActor () -> Void = {}
    var menuProvider: @MainActor () -> NSMenu? = { nil }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = HotZoneView(owner: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HotZoneView: NSView {
    private unowned let owner: HotZonePanel

    init(owner: HotZonePanel) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        // Practically invisible, but non-zero alpha guarantees the window server routes events here.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("OpenNotch usage")
        setAccessibilityHelp("Opens AI usage limits")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { owner.onEnter() }
    override func mouseExited(with event: NSEvent) { owner.onExit() }
    override func mouseDown(with event: NSEvent) { owner.onClick() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = owner.menuProvider() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        owner.onClick()
        return true
    }
}
