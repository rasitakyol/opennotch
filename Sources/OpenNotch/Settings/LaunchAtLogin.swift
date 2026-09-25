import Foundation
import ServiceManagement
import os

enum LaunchAtLogin {
    private static let logger = Logger(subsystem: "app.opennotch.OpenNotch", category: "login-item")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            logger.error("Could not update the login item: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
