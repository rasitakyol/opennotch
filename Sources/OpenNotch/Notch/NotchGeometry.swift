import AppKit

/// Where the notch is on the chosen screen, in global screen coordinates.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var notchCenterX: CGFloat
    var hasHardwareNotch: Bool

    var top: CGFloat { screenFrame.maxY }

    static let placeholder = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchWidth: 185,
        notchHeight: 32,
        notchCenterX: 756,
        hasHardwareNotch: true
    )

    /// Prefers the built-in display with a camera housing; otherwise uses the main screen with a virtual notch.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func resolve(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // Derived from widths only, so it holds regardless of which coordinate space the areas use.
            let width = frame.width - left.width - right.width
            return NotchGeometry(
                screenFrame: frame,
                notchWidth: width,
                notchHeight: screen.safeAreaInsets.top,
                notchCenterX: frame.minX + left.width + width / 2,
                hasHardwareNotch: true
            )
        }
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(
            screenFrame: frame,
            notchWidth: 160,
            notchHeight: menuBar > 12 ? menuBar : 24,
            notchCenterX: frame.midX,
            hasHardwareNotch: false
        )
    }
}
