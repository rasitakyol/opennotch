import OpenNotchCore
import SwiftUI

/// The notch is always black, so colours are tuned for a dark surface regardless of system appearance.
enum Palette {
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)
    static let row = Color.white.opacity(0.055)
    static let rowHover = Color.white.opacity(0.085)
    static let track = Color.white.opacity(0.1)
    static let warning = Color(red: 1.0, green: 0.78, blue: 0.2)

    static func severity(_ severity: Severity) -> Color {
        switch severity {
        case .normal: Color(red: 0.2, green: 0.84, blue: 0.4)
        case .elevated: Color(red: 1.0, green: 0.82, blue: 0.1)
        case .high: Color(red: 1.0, green: 0.6, blue: 0.1)
        case .critical: Color(red: 1.0, green: 0.3, blue: 0.26)
        }
    }

    static func forPercent(_ percent: Double) -> Color {
        severity(Severity(percent: percent))
    }
}
