import Foundation
import ServiceManagement

/// "Launch at login" via SMAppService (macOS 13+). Registers the app bundle
/// itself as a login item — the same mechanism menu-bar apps use. The user
/// can also see/toggle it in System Settings → General → Login Items.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
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
            NSLog("Kenar: launch-at-login change failed: \(error.localizedDescription)")
            return false
        }
    }
}
