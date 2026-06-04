import Foundation
import Combine
import AppKit

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private let storage = SettingsStorage.shared
    private var cancellables = Set<AnyCancellable>()
    
    @Published var isFirstLaunch: Bool {
        didSet {
            storage.save(isFirstLaunch, forKey: SettingsKeys.isFirstLaunch)
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            storage.save(launchAtLogin, forKey: SettingsKeys.launchAtLogin)
            LaunchAtLoginManager.setLaunchAtLogin(enabled: launchAtLogin)
        }
    }
    
    @Published var showInMenuBar: Bool {
        didSet {
            storage.save(showInMenuBar, forKey: SettingsKeys.showInMenuBar)
            NotificationCenter.default.post(name: .showInMenuBarChanged, object: nil)
        }
    }
    
    @Published var minimizeToTray: Bool {
        didSet {
            storage.save(minimizeToTray, forKey: SettingsKeys.minimizeToTray)
        }
    }
    
    @Published var windowPosition: CGPoint? {
        didSet {
            if let position = windowPosition {
                storage.saveWindowPosition(position)
            }
        }
    }
    
    @Published var windowSize: CGSize? {
        didSet {
            if let size = windowSize {
                storage.saveWindowSize(size)
            }
        }
    }
    
    @Published var showProcessIcons: Bool {
        didSet {
            storage.save(showProcessIcons, forKey: SettingsKeys.showProcessIcons)
        }
    }
    
    @Published var autoRefreshProcessList: Bool {
        didSet {
            storage.save(autoRefreshProcessList, forKey: SettingsKeys.autoRefreshProcessList)
        }
    }
    
    @Published var refreshInterval: TimeInterval {
        didSet {
            storage.save(refreshInterval, forKey: SettingsKeys.refreshInterval)
        }
    }
    
    @Published var lastUsedSpeed: Double {
        didSet {
            storage.save(lastUsedSpeed, forKey: SettingsKeys.lastUsedSpeed)
        }
    }
    
    @Published var rememberSpeedPerProcess: Bool {
        didSet {
            storage.save(rememberSpeedPerProcess, forKey: SettingsKeys.rememberSpeedPerProcess)
        }
    }
    
    @Published var hotkeyEnabled: Bool {
        didSet {
            storage.save(hotkeyEnabled, forKey: SettingsKeys.hotkeyEnabled)
            if hotkeyEnabled {
                HotkeyService.shared.registerHotkeys()
            } else {
                HotkeyService.shared.unregisterHotkeys()
            }
        }
    }
    
    @Published var showSpeedNotifications: Bool {
        didSet {
            storage.save(showSpeedNotifications, forKey: SettingsKeys.showSpeedNotifications)
        }
    }
    
    @Published var maxHistoryCount: Int {
        didSet {
            storage.save(maxHistoryCount, forKey: SettingsKeys.maxHistoryCount)
        }
    }
    
    @Published var autoCleanupInactive: Bool {
        didSet {
            storage.save(autoCleanupInactive, forKey: SettingsKeys.autoCleanupInactive)
        }
    }
    
    private init() {
        isFirstLaunch = storage.loadBool(forKey: SettingsKeys.isFirstLaunch, defaultValue: true)
        launchAtLogin = storage.loadBool(forKey: SettingsKeys.launchAtLogin)
        showInMenuBar = storage.loadBool(forKey: SettingsKeys.showInMenuBar)
        minimizeToTray = storage.loadBool(forKey: SettingsKeys.minimizeToTray)
        
        windowPosition = storage.loadWindowPosition()
        windowSize = storage.loadWindowSize()
        
        showProcessIcons = storage.loadBool(forKey: SettingsKeys.showProcessIcons)
        autoRefreshProcessList = storage.loadBool(forKey: SettingsKeys.autoRefreshProcessList)
        refreshInterval = storage.loadDouble(forKey: SettingsKeys.refreshInterval)
        
        lastUsedSpeed = storage.loadDouble(forKey: SettingsKeys.lastUsedSpeed)
        rememberSpeedPerProcess = storage.loadBool(forKey: SettingsKeys.rememberSpeedPerProcess)
        
        hotkeyEnabled = storage.loadBool(forKey: SettingsKeys.hotkeyEnabled)
        showSpeedNotifications = storage.loadBool(forKey: SettingsKeys.showSpeedNotifications)
        
        maxHistoryCount = storage.loadInt(forKey: SettingsKeys.maxHistoryCount)
        autoCleanupInactive = storage.loadBool(forKey: SettingsKeys.autoCleanupInactive)
        
        setupBindings()
        storage.migrateIfNeeded()
        
        #if DEBUG
        print("[AppSettings] Initialized with launchAtLogin: \(launchAtLogin)")
        #endif
    }
    
    private func setupBindings() {
        $launchAtLogin
            .dropFirst()
            .sink { [weak self] value in
                self?.storage.save(value, forKey: SettingsKeys.launchAtLogin)
            }
            .store(in: &cancellables)
        
        $showInMenuBar
            .dropFirst()
            .sink { [weak self] value in
                self?.storage.save(value, forKey: SettingsKeys.showInMenuBar)
            }
            .store(in: &cancellables)
    }
    
    func save() {
        storage.saveAll()
        #if DEBUG
        print("[AppSettings] Settings saved")
        #endif
    }
    
    func load() {
        launchAtLogin = storage.loadBool(forKey: SettingsKeys.launchAtLogin)
        showInMenuBar = storage.loadBool(forKey: SettingsKeys.showInMenuBar)
        minimizeToTray = storage.loadBool(forKey: SettingsKeys.minimizeToTray)
        
        windowPosition = storage.loadWindowPosition()
        windowSize = storage.loadWindowSize()
        
        showProcessIcons = storage.loadBool(forKey: SettingsKeys.showProcessIcons)
        autoRefreshProcessList = storage.loadBool(forKey: SettingsKeys.autoRefreshProcessList)
        refreshInterval = storage.loadDouble(forKey: SettingsKeys.refreshInterval)
        
        lastUsedSpeed = storage.loadDouble(forKey: SettingsKeys.lastUsedSpeed)
        rememberSpeedPerProcess = storage.loadBool(forKey: SettingsKeys.rememberSpeedPerProcess)
        
        hotkeyEnabled = storage.loadBool(forKey: SettingsKeys.hotkeyEnabled)
        showSpeedNotifications = storage.loadBool(forKey: SettingsKeys.showSpeedNotifications)
        
        maxHistoryCount = storage.loadInt(forKey: SettingsKeys.maxHistoryCount)
        autoCleanupInactive = storage.loadBool(forKey: SettingsKeys.autoCleanupInactive)
        
        #if DEBUG
        print("[AppSettings] Settings loaded")
        #endif
    }
    
    func resetToDefaults() {
        storage.reset()
        load()
        
        #if DEBUG
        print("[AppSettings] Settings reset to defaults")
        #endif
    }
    
    func exportConfiguration() -> Data? {
        let config = ConfigurationExportData(
            appSettings: exportAppSettings(),
            hotkeyConfigs: HotkeyStorage.shared.load()
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(config)
        } catch {
            #if DEBUG
            print("[AppSettings] Failed to export configuration: \(error)")
            #endif
            return nil
        }
    }
    
    func importConfiguration(from data: Data) throws {
        let decoder = JSONDecoder()
        let config = try decoder.decode(ConfigurationExportData.self, from: data)
        
        importAppSettings(config.appSettings)
        
        HotkeyStorage.shared.save(config.hotkeyConfigs)
        HotkeyService.shared.loadConfigurations()
        
        #if DEBUG
        print("[AppSettings] Configuration imported successfully")
        #endif
    }
    
    private func exportAppSettings() -> AppSettingsExportData {
        return AppSettingsExportData(
            launchAtLogin: launchAtLogin,
            showInMenuBar: showInMenuBar,
            minimizeToTray: minimizeToTray,
            showProcessIcons: showProcessIcons,
            autoRefreshProcessList: autoRefreshProcessList,
            refreshInterval: refreshInterval,
            lastUsedSpeed: lastUsedSpeed,
            rememberSpeedPerProcess: rememberSpeedPerProcess,
            hotkeyEnabled: hotkeyEnabled,
            showSpeedNotifications: showSpeedNotifications,
            maxHistoryCount: maxHistoryCount,
            autoCleanupInactive: autoCleanupInactive
        )
    }
    
    private func importAppSettings(_ settings: AppSettingsExportData) {
        launchAtLogin = settings.launchAtLogin
        showInMenuBar = settings.showInMenuBar
        minimizeToTray = settings.minimizeToTray
        showProcessIcons = settings.showProcessIcons
        autoRefreshProcessList = settings.autoRefreshProcessList
        refreshInterval = settings.refreshInterval
        lastUsedSpeed = settings.lastUsedSpeed
        rememberSpeedPerProcess = settings.rememberSpeedPerProcess
        hotkeyEnabled = settings.hotkeyEnabled
        showSpeedNotifications = settings.showSpeedNotifications
        maxHistoryCount = settings.maxHistoryCount
        autoCleanupInactive = settings.autoCleanupInactive
        
        save()
    }
}

struct AppSettingsExportData: Codable {
    var launchAtLogin: Bool
    var showInMenuBar: Bool
    var minimizeToTray: Bool
    var showProcessIcons: Bool
    var autoRefreshProcessList: Bool
    var refreshInterval: Double
    var lastUsedSpeed: Double
    var rememberSpeedPerProcess: Bool
    var hotkeyEnabled: Bool
    var showSpeedNotifications: Bool
    var maxHistoryCount: Int
    var autoCleanupInactive: Bool
}

struct ConfigurationExportData: Codable {
    var appSettings: AppSettingsExportData
    var hotkeyConfigs: [HotkeyConfig]
}

extension Notification.Name {
    static let showInMenuBarChanged = Notification.Name("showInMenuBarChanged")
    static let settingsDidChange = Notification.Name("settingsDidChange")
    static let settingsDidReset = Notification.Name("settingsDidReset")
    static let windowMinimizedToTray = Notification.Name("windowMinimizedToTray")
}
