import Foundation
import AppKit
import ServiceManagement

class LaunchAtLoginManager {
    static func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            setLaunchAtLoginModern(enabled: enabled)
        } else {
            setLaunchAtLoginLegacy(enabled: enabled)
        }
        
        #if DEBUG
        print("[LaunchAtLoginManager] Launch at login set to: \(enabled)")
        #endif
    }
    
    @available(macOS 13.0, *)
    private static func setLaunchAtLoginModern(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            #if DEBUG
            print("[LaunchAtLoginManager] Failed to set launch at login: \(error)")
            #endif
        }
    }
    
    private static func setLaunchAtLoginLegacy(enabled: Bool) {
        let identifier = "com.openspeedy.app" as CFString
        
        if !SMLoginItemSetEnabled(identifier, enabled) {
            #if DEBUG
            print("[LaunchAtLoginManager] Failed to set login item enabled status")
            #endif
        }
    }
    
    static func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return isLaunchAtLoginEnabledModern()
        } else {
            return isLaunchAtLoginEnabledLegacy()
        }
    }
    
    @available(macOS 13.0, *)
    private static func isLaunchAtLoginEnabledModern() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled
    }
    
    private static func isLaunchAtLoginEnabledLegacy() -> Bool {
        let identifier = "com.openspeedy.app" as CFString
        return SMLoginItemSetEnabled(identifier, false)
    }
    
    static func getLoginItemsList() -> [String] {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return []
        }
        
        var loginItems: [String] = []
        
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                loginItems.append(bundleID)
            }
        }
        
        return loginItems
    }
    
    static func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
