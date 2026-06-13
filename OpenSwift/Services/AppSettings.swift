import Foundation
import Combine
import AppKit

// 关键修复: init 只做最轻量的操作
// 所有需要其他 singleton 或 heavy IO 的操作延迟到 finishInitialization()
// finishInitialization() 在窗口显示完成后由 AppDelegate 调用
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private let storage = SettingsStorage.shared
    private var cancellables = Set<AnyCancellable>()
    
    // 防止 init 中赋值触发 didSet 副作用
    private var isInitializing: Bool = true
    // 延迟初始化完成标志
    private var initializationFinished: Bool = false
    
    @Published var isFirstLaunch: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(isFirstLaunch, forKey: SettingsKeys.isFirstLaunch)
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(launchAtLogin, forKey: SettingsKeys.launchAtLogin)
            // LaunchAtLoginManager 延迟到 finishInitialization 之后
            if initializationFinished {
                LaunchAtLoginManager.setLaunchAtLogin(enabled: launchAtLogin)
            }
        }
    }
    
    @Published var showInMenuBar: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(showInMenuBar, forKey: SettingsKeys.showInMenuBar)
            if initializationFinished {
                NotificationCenter.default.post(name: .showInMenuBarChanged, object: nil)
            }
        }
    }
    
    @Published var minimizeToTray: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(minimizeToTray, forKey: SettingsKeys.minimizeToTray)
        }
    }
    
    @Published var windowPosition: CGPoint? {
        didSet {
            guard !isInitializing else { return }
            if let position = windowPosition {
                storage.saveWindowPosition(position)
            }
        }
    }
    
    @Published var windowSize: CGSize? {
        didSet {
            guard !isInitializing else { return }
            if let size = windowSize {
                storage.saveWindowSize(size)
            }
        }
    }
    
    @Published var showProcessIcons: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(showProcessIcons, forKey: SettingsKeys.showProcessIcons)
        }
    }
    
    @Published var autoRefreshProcessList: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(autoRefreshProcessList, forKey: SettingsKeys.autoRefreshProcessList)
        }
    }
    
    @Published var refreshInterval: TimeInterval {
        didSet {
            guard !isInitializing else { return }
            storage.save(refreshInterval, forKey: SettingsKeys.refreshInterval)
        }
    }
    
    @Published var lastUsedSpeed: Double {
        didSet {
            guard !isInitializing else { return }
            storage.save(lastUsedSpeed, forKey: SettingsKeys.lastUsedSpeed)
        }
    }
    
    @Published var rememberSpeedPerProcess: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(rememberSpeedPerProcess, forKey: SettingsKeys.rememberSpeedPerProcess)
        }
    }
    
    @Published var hotkeyEnabled: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(hotkeyEnabled, forKey: SettingsKeys.hotkeyEnabled)
            if initializationFinished {
                if hotkeyEnabled {
                    HotkeyService.shared.registerHotkeys()
                } else {
                    HotkeyService.shared.unregisterHotkeys()
                }
            }
        }
    }
    
    @Published var showSpeedNotifications: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(showSpeedNotifications, forKey: SettingsKeys.showSpeedNotifications)
        }
    }
    
    @Published var maxHistoryCount: Int {
        didSet {
            guard !isInitializing else { return }
            storage.save(maxHistoryCount, forKey: SettingsKeys.maxHistoryCount)
        }
    }
    
    @Published var autoCleanupInactive: Bool {
        didSet {
            guard !isInitializing else { return }
            storage.save(autoCleanupInactive, forKey: SettingsKeys.autoCleanupInactive)
        }
    }
    
    private init() {
        // 只做最轻量的配置读取，不触发任何副作用
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
        
        // init 完成，允许 didSet 生效（但还不允许 heavy 副作用）
        isInitializing = false
        
        // 注意: 不在这里调用 setupBindings / migrateIfNeeded
        // 这些延迟到 finishInitialization()
    }
    
    // 由 AppDelegate 在窗口显示完成后调用
    func finishInitialization() {
        guard !initializationFinished else { return }
        
        setupBindings()
        storage.migrateIfNeeded()
        
        // 应用设置值 (hotkey 等)
        if launchAtLogin {
            LaunchAtLoginManager.setLaunchAtLogin(enabled: true)
        }
        
        initializationFinished = true
        
        print("[AppSettings] Initialization finished")
    }
    
    private func setupBindings() {
        // 不做任何复杂 binding，避免启动时的重入问题
    }
    
    func save() {
        storage.saveAll()
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
    }
    
    func resetToDefaults() {
        storage.reset()
        load()
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
            return nil
        }
    }
    
    func importConfiguration(from data: Data) throws {
        let decoder = JSONDecoder()
        let config = try decoder.decode(ConfigurationExportData.self, from: data)
        
        importAppSettings(config.appSettings)
        HotkeyStorage.shared.save(config.hotkeyConfigs)
        if initializationFinished {
            HotkeyService.shared.loadConfigurations()
        }
        save()
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
