import Foundation

struct SettingsKeys {
    static let isFirstLaunch = "IsFirstLaunch"
    static let launchAtLogin = "LaunchAtLogin"
    static let showInMenuBar = "ShowInMenuBar"
    static let minimizeToTray = "MinimizeToTray"
    
    static let windowPositionX = "WindowPositionX"
    static let windowPositionY = "WindowPositionY"
    static let windowWidth = "WindowWidth"
    static let windowHeight = "WindowHeight"
    
    static let showProcessIcons = "ShowProcessIcons"
    static let autoRefreshProcessList = "AutoRefreshProcessList"
    static let refreshInterval = "RefreshInterval"
    
    static let lastUsedSpeed = "LastUsedSpeed"
    static let rememberSpeedPerProcess = "RememberSpeedPerProcess"
    
    static let hotkeyEnabled = "HotkeyEnabled"
    static let showSpeedNotifications = "ShowSpeedNotifications"
    
    static let maxHistoryCount = "MaxHistoryCount"
    static let autoCleanupInactive = "AutoCleanupInactive"
    
    static let settingsVersion = "SettingsVersion"
}

class SettingsStorage {
    static let shared = SettingsStorage()
    
    private let defaults = UserDefaults.standard
    private let currentVersion = 1
    
    private init() {
        registerDefaults()
    }
    
    private func registerDefaults() {
        let defaultValues: [String: Any] = [
            SettingsKeys.launchAtLogin: false,
            SettingsKeys.showInMenuBar: true,
            SettingsKeys.minimizeToTray: false,
            
            SettingsKeys.showProcessIcons: true,
            SettingsKeys.autoRefreshProcessList: true,
            SettingsKeys.refreshInterval: 5.0,
            
            SettingsKeys.lastUsedSpeed: 1.0,
            SettingsKeys.rememberSpeedPerProcess: true,
            
            SettingsKeys.hotkeyEnabled: true,
            SettingsKeys.showSpeedNotifications: true,
            
            SettingsKeys.maxHistoryCount: 100,
            SettingsKeys.autoCleanupInactive: true,
            
            SettingsKeys.settingsVersion: currentVersion
        ]
        
        defaults.register(defaults: defaultValues)
    }
    
    func save<T>(_ value: T, forKey key: String) {
        defaults.set(value, forKey: key)
        #if DEBUG
        print("[SettingsStorage] Saved key: \(key)")
        #endif
    }
    
    func load<T>(forKey key: String) -> T? {
        return defaults.object(forKey: key) as? T
    }
    
    func loadBool(forKey key: String) -> Bool {
        return defaults.bool(forKey: key)
    }
    
    func loadBool(forKey key: String, defaultValue: Bool) -> Bool {
        if let value = defaults.object(forKey: key) as? Bool {
            return value
        }
        return defaultValue
    }
    
    func loadDouble(forKey key: String) -> Double {
        return defaults.double(forKey: key)
    }
    
    func loadInt(forKey key: String) -> Int {
        return defaults.integer(forKey: key)
    }
    
    func loadString(forKey key: String) -> String? {
        return defaults.string(forKey: key)
    }
    
    func loadData(forKey key: String) -> Data? {
        return defaults.data(forKey: key)
    }
    
    func remove(forKey key: String) {
        defaults.removeObject(forKey: key)
        #if DEBUG
        print("[SettingsStorage] Removed key: \(key)")
        #endif
    }
    
    func saveWindowPosition(_ position: CGPoint) {
        save(position.x, forKey: SettingsKeys.windowPositionX)
        save(position.y, forKey: SettingsKeys.windowPositionY)
    }
    
    func loadWindowPosition() -> CGPoint? {
        let x = loadDouble(forKey: SettingsKeys.windowPositionX)
        let y = loadDouble(forKey: SettingsKeys.windowPositionY)
        
        guard x != 0 || y != 0 else {
            return nil
        }
        
        return CGPoint(x: x, y: y)
    }
    
    func saveWindowSize(_ size: CGSize) {
        save(size.width, forKey: SettingsKeys.windowWidth)
        save(size.height, forKey: SettingsKeys.windowHeight)
    }
    
    func loadWindowSize() -> CGSize? {
        let width = loadDouble(forKey: SettingsKeys.windowWidth)
        let height = loadDouble(forKey: SettingsKeys.windowHeight)
        
        guard width > 0 && height > 0 else {
            return nil
        }
        
        return CGSize(width: width, height: height)
    }
    
    func saveAll() {
        defaults.synchronize()
        #if DEBUG
        print("[SettingsStorage] All settings saved")
        #endif
    }
    
    func reset() {
        let domain = Bundle.main.bundleIdentifier ?? "com.openspeedy.app"
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
        
        registerDefaults()
        
        #if DEBUG
        print("[SettingsStorage] All settings reset to defaults")
        #endif
    }
    
    func migrateIfNeeded() {
        let version = loadInt(forKey: SettingsKeys.settingsVersion)
        
        if version < currentVersion {
            #if DEBUG
            print("[SettingsStorage] Migrating from version \(version) to \(currentVersion)")
            #endif
            migrate(fromVersion: version, toVersion: currentVersion)
            save(currentVersion, forKey: SettingsKeys.settingsVersion)
        }
    }
    
    private func migrate(fromVersion: Int, toVersion: Int) {
        if fromVersion < 1 && toVersion >= 1 {
            migrateToV1()
        }
    }
    
    private func migrateToV1() {
        #if DEBUG
        print("[SettingsStorage] Running migration to V1")
        #endif
    }
    
    func exportAllSettings() -> [String: Any] {
        var settings: [String: Any] = [:]
        
        settings[SettingsKeys.launchAtLogin] = loadBool(forKey: SettingsKeys.launchAtLogin)
        settings[SettingsKeys.showInMenuBar] = loadBool(forKey: SettingsKeys.showInMenuBar)
        settings[SettingsKeys.minimizeToTray] = loadBool(forKey: SettingsKeys.minimizeToTray)
        
        settings[SettingsKeys.showProcessIcons] = loadBool(forKey: SettingsKeys.showProcessIcons)
        settings[SettingsKeys.autoRefreshProcessList] = loadBool(forKey: SettingsKeys.autoRefreshProcessList)
        settings[SettingsKeys.refreshInterval] = loadDouble(forKey: SettingsKeys.refreshInterval)
        
        settings[SettingsKeys.lastUsedSpeed] = loadDouble(forKey: SettingsKeys.lastUsedSpeed)
        settings[SettingsKeys.rememberSpeedPerProcess] = loadBool(forKey: SettingsKeys.rememberSpeedPerProcess)
        
        settings[SettingsKeys.hotkeyEnabled] = loadBool(forKey: SettingsKeys.hotkeyEnabled)
        settings[SettingsKeys.showSpeedNotifications] = loadBool(forKey: SettingsKeys.showSpeedNotifications)
        
        settings[SettingsKeys.maxHistoryCount] = loadInt(forKey: SettingsKeys.maxHistoryCount)
        settings[SettingsKeys.autoCleanupInactive] = loadBool(forKey: SettingsKeys.autoCleanupInactive)
        
        return settings
    }
    
    func importAllSettings(_ settings: [String: Any]) {
        if let value = settings[SettingsKeys.launchAtLogin] as? Bool {
            save(value, forKey: SettingsKeys.launchAtLogin)
        }
        if let value = settings[SettingsKeys.showInMenuBar] as? Bool {
            save(value, forKey: SettingsKeys.showInMenuBar)
        }
        if let value = settings[SettingsKeys.minimizeToTray] as? Bool {
            save(value, forKey: SettingsKeys.minimizeToTray)
        }
        
        if let value = settings[SettingsKeys.showProcessIcons] as? Bool {
            save(value, forKey: SettingsKeys.showProcessIcons)
        }
        if let value = settings[SettingsKeys.autoRefreshProcessList] as? Bool {
            save(value, forKey: SettingsKeys.autoRefreshProcessList)
        }
        if let value = settings[SettingsKeys.refreshInterval] as? Double {
            save(value, forKey: SettingsKeys.refreshInterval)
        }
        
        if let value = settings[SettingsKeys.lastUsedSpeed] as? Double {
            save(value, forKey: SettingsKeys.lastUsedSpeed)
        }
        if let value = settings[SettingsKeys.rememberSpeedPerProcess] as? Bool {
            save(value, forKey: SettingsKeys.rememberSpeedPerProcess)
        }
        
        if let value = settings[SettingsKeys.hotkeyEnabled] as? Bool {
            save(value, forKey: SettingsKeys.hotkeyEnabled)
        }
        if let value = settings[SettingsKeys.showSpeedNotifications] as? Bool {
            save(value, forKey: SettingsKeys.showSpeedNotifications)
        }
        
        if let value = settings[SettingsKeys.maxHistoryCount] as? Int {
            save(value, forKey: SettingsKeys.maxHistoryCount)
        }
        if let value = settings[SettingsKeys.autoCleanupInactive] as? Bool {
            save(value, forKey: SettingsKeys.autoCleanupInactive)
        }
        
        saveAll()
        #if DEBUG
        print("[SettingsStorage] Settings imported successfully")
        #endif
    }
}
