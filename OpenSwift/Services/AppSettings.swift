import Foundation
import Combine
import AppKit

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let storage = SettingsStorage.shared
    private var cancellables = Set<AnyCancellable>()

    private var sideEffectsEnabled: Bool = false

    @Published var isFirstLaunch: Bool = true {
        didSet {
            storage.save(isFirstLaunch, forKey: SettingsKeys.isFirstLaunch)
        }
    }

    @Published var launchAtLogin: Bool = false {
        didSet {
            storage.save(launchAtLogin, forKey: SettingsKeys.launchAtLogin)
            if sideEffectsEnabled {
                LaunchAtLoginManager.setLaunchAtLogin(enabled: launchAtLogin)
            }
        }
    }

    @Published var showInMenuBar: Bool = true {
        didSet {
            storage.save(showInMenuBar, forKey: SettingsKeys.showInMenuBar)
            if sideEffectsEnabled {
                NotificationCenter.default.post(name: .showInMenuBarChanged, object: nil)
            }
        }
    }

    @Published var minimizeToTray: Bool = false {
        didSet {
            storage.save(minimizeToTray, forKey: SettingsKeys.minimizeToTray)
        }
    }

    @Published var windowPosition: CGPoint? = nil {
        didSet {
            if let position = windowPosition {
                storage.saveWindowPosition(position)
            }
        }
    }

    @Published var windowSize: CGSize? = nil {
        didSet {
            if let size = windowSize {
                storage.saveWindowSize(size)
            }
        }
    }

    @Published var showProcessIcons: Bool = true {
        didSet {
            storage.save(showProcessIcons, forKey: SettingsKeys.showProcessIcons)
        }
    }

    @Published var autoRefreshProcessList: Bool = true {
        didSet {
            storage.save(autoRefreshProcessList, forKey: SettingsKeys.autoRefreshProcessList)
        }
    }

    @Published var refreshInterval: TimeInterval = 5.0 {
        didSet {
            storage.save(refreshInterval, forKey: SettingsKeys.refreshInterval)
        }
    }

    @Published var lastUsedSpeed: Double = 1.0 {
        didSet {
            storage.save(lastUsedSpeed, forKey: SettingsKeys.lastUsedSpeed)
        }
    }

    @Published var rememberSpeedPerProcess: Bool = true {
        didSet {
            storage.save(rememberSpeedPerProcess, forKey: SettingsKeys.rememberSpeedPerProcess)
        }
    }

    @Published var hotkeyEnabled: Bool = true {
        didSet {
            storage.save(hotkeyEnabled, forKey: SettingsKeys.hotkeyEnabled)
            if sideEffectsEnabled {
                if hotkeyEnabled {
                    HotkeyService.shared.registerHotkeys()
                } else {
                    HotkeyService.shared.unregisterHotkeys()
                }
            }
        }
    }

    @Published var showSpeedNotifications: Bool = true {
        didSet {
            storage.save(showSpeedNotifications, forKey: SettingsKeys.showSpeedNotifications)
        }
    }

    @Published var maxHistoryCount: Int = 100 {
        didSet {
            storage.save(maxHistoryCount, forKey: SettingsKeys.maxHistoryCount)
        }
    }

    @Published var autoCleanupInactive: Bool = true {
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
    }

    func bootstrapSideEffects() {
        guard !sideEffectsEnabled else { return }

        storage.migrateIfNeeded()

        if launchAtLogin {
            LaunchAtLoginManager.setLaunchAtLogin(enabled: true)
        }

        sideEffectsEnabled = true

        if hotkeyEnabled {
            HotkeyService.shared.registerHotkeys()
        }

        logInfo("AppSettings: Side effects bootstrapped", log: .settings)
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
        if sideEffectsEnabled {
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
    
    func shutdown() {
        save()
        logInfo("AppSettings shutdown complete", log: .settings)
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
