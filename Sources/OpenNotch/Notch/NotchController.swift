import AppKit
import SwiftUI

/// Owns the notch windows and turns the pointer into open/close.
///
/// Closed: the drawing panel ignores the mouse entirely and a small hot zone over the notch listens with a
/// tracking area, so nothing runs while the pointer is elsewhere. Open: the pointer is followed globally
/// until it leaves the panel, and the panel only captures clicks inside its drawn shape.
@MainActor
final class NotchController {
    /// Fixed canvas the SwiftUI content draws into; big enough for the widest expanded layout plus shadow.
    private static let canvas = CGSize(width: 760, height: 560)
    private static let openDelay: TimeInterval = 0.1
    private static let closeDelay: TimeInterval = 0.28
    /// How far the pointer may stray past the open panel's edge before it counts as having left.
    private static let leaveTolerance: CGFloat = 10

    private let panel = NotchPanel()
    private let hotZone = HotZonePanel()
    private let model: NotchViewModel
    private var expandedMonitors: [Any] = []
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pendingOpen: DispatchWorkItem?
    private var pendingClose: DispatchWorkItem?
    private var menuIsOpen = false
    /// Development aid (`--preview`): keeps the panel open so layout can be inspected and captured.
    private let pinnedOpen = CommandLine.arguments.contains("--preview")
    /// The drawn body in screen coordinates, cached and refreshed when state, size or geometry changes.
    private var bodyRect: NSRect = .zero

    init(model: NotchViewModel) {
        self.model = model
        if pinnedOpen { model.isExpanded = true }

        let host = NSHostingView(rootView: NotchRootView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.canvas)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        hotZone.onEnter = { [weak self] in self?.hotZoneEntered() }
        hotZone.onExit = { [weak self] in self?.cancelOpen() }
        hotZone.onClick = { [weak self] in
            self?.cancelOpen()
            self?.model.expand()
        }
        hotZone.menuProvider = { [weak self] in self?.contextMenu() }
        model.onExpansionChange = { [weak self] in self?.expansionChanged() }

        reposition()
        trackBodyRect()
        panel.orderFrontRegardless()
        installLocalMonitor()
        installObservers()
        applyMode()
    }

    // MARK: Placement

    func reposition() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry.resolve(for: screen)
        model.geometry = geometry
        panel.setFrame(
            NSRect(
                x: geometry.notchCenterX - Self.canvas.width / 2,
                y: geometry.top - Self.canvas.height,
                width: Self.canvas.width,
                height: Self.canvas.height
            ),
            display: true
        )
        bodyRect = computeBodyRect()
        updateHotZoneFrame()
    }

    private func computeBodyRect() -> NSRect {
        let size = model.bodySize
        let geometry = model.geometry
        return NSRect(x: geometry.notchCenterX - size.width / 2, y: geometry.top - size.height, width: size.width, height: size.height)
    }

    private func trackBodyRect() {
        bodyRect = withObservationTracking {
            computeBodyRect()
        } onChange: { [weak self] in
            // Fires before the new value is stored; read it on the next turn of the run loop.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trackBodyRect()
                    self.updateHotZoneFrame()
                }
            }
        }
    }

    private func updateHotZoneFrame() {
        guard !model.isExpanded else { return }
        let frame = bodyRect.insetBy(dx: -2, dy: 0)
        if hotZone.frame != frame { hotZone.setFrame(frame, display: false) }
    }

    // MARK: Open / closed modes

    private func expansionChanged() {
        // Use the new state's outline right away; the cached one refreshes asynchronously.
        bodyRect = computeBodyRect()
        applyMode()
        pointerMoved()
    }

    private func applyMode() {
        if model.isExpanded {
            hotZone.orderOut(nil)
            installExpandedMonitors()
        } else {
            removeExpandedMonitors()
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            updateHotZoneFrame()
            hotZone.orderFrontRegardless()
        }
    }

    private func hotZoneEntered() {
        guard model.settings.hoverToOpen, !model.isExpanded else { return }
        scheduleOpen()
    }

    // MARK: Pointer while open

    private func installExpandedMonitors() {
        guard expandedMonitors.isEmpty else { return }
        if let moves = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            expandedMonitors.append(moves)
        }
        // Clicks delivered to other apps mean the user moved on; close right away.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) {
            expandedMonitors.append(clicks)
        }
    }

    private func removeExpandedMonitors() {
        expandedMonitors.forEach(NSEvent.removeMonitor)
        expandedMonitors.removeAll()
    }

    /// Movement over our own windows never reaches global monitors, so follow it locally too.
    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
    }

    private func pointerMoved() {
        guard model.isExpanded else { return }
        let point = NSEvent.mouseLocation
        // Only the drawn shape takes clicks; everything around it stays click-through.
        let overPanel = bodyRect.contains(point)
        if panel.ignoresMouseEvents == overPanel { panel.ignoresMouseEvents = !overPanel }

        let nearPanel = bodyRect.insetBy(dx: -Self.leaveTolerance, dy: -Self.leaveTolerance).contains(point)
        if nearPanel || menuIsOpen || pinnedOpen { cancelClose() } else { scheduleClose() }
    }

    private func clickedOutside() {
        guard model.isExpanded, !menuIsOpen, !pinnedOpen else { return }
        cancelOpen()
        cancelClose()
        model.collapse()
    }

    private func scheduleOpen() {
        guard pendingOpen == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingOpen = nil
                self.model.expand()
            }
        }
        pendingOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDelay, execute: work)
    }

    private func scheduleClose() {
        guard pendingClose == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingClose = nil
                guard !self.menuIsOpen else { return }
                self.model.collapse()
            }
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
    }

    private func cancelOpen() {
        pendingOpen?.cancel()
        pendingOpen = nil
    }

    private func cancelClose() {
        pendingClose?.cancel()
        pendingClose = nil
    }

    // MARK: Menu & system events

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Refresh Now") { [weak self] in self?.model.store.refresh() })
        menu.addItem(ClosureMenuItem("Settings…") { [weak self] in self?.model.showSettings() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit OpenNotch") { NSApp.terminate(nil) })
        return menu
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        // Menus live in their own window; keep the panel open while one is showing.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuIsOpen = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuIsOpen = false
                self?.pointerMoved()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderFrontRegardless()
                if !self.model.isExpanded { self.hotZone.orderFrontRegardless() }
            }
        })
    }
}

/// Menu item that runs a closure, for menus built in code.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
