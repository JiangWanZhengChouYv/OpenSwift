import Foundation

class HotkeyStorage {
    static let shared = HotkeyStorage()
    static let storageKey = "HotkeyConfigurations"

    private let userDefaults = UserDefaults.standard

    private init() {}

    func save(_ configurations: [HotkeyConfig]) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(configurations)
            userDefaults.set(data, forKey: HotkeyStorage.storageKey)
            logDebug("Saved \(configurations.count) hotkey configurations", log: .hotkey)
        } catch {
            logError("Failed to save configurations: \(error.localizedDescription)", log: .hotkey)
        }
    }

    func load() -> [HotkeyConfig] {
        guard let data = userDefaults.data(forKey: HotkeyStorage.storageKey) else {
            logDebug("No saved configurations found, using defaults", log: .hotkey)
            return HotkeyConfig.defaultConfigurations()
        }

        do {
            let decoder = JSONDecoder()
            let configurations = try decoder.decode([HotkeyConfig].self, from: data)
            logDebug("Loaded \(configurations.count) hotkey configurations", log: .hotkey)
            return configurations
        } catch {
            logError("Failed to load configurations: \(error.localizedDescription)", log: .hotkey)
            return HotkeyConfig.defaultConfigurations()
        }
    }

    func resetToDefaults() {
        userDefaults.removeObject(forKey: HotkeyStorage.storageKey)
        logInfo("Reset to default configurations", log: .hotkey)
    }

    func saveSingle(_ config: HotkeyConfig) {
        var configurations = load()
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            save(configurations)
        }
    }
    
    func shutdown() {
        logDebug("HotkeyStorage shutdown complete", log: .hotkey)
    }
}
