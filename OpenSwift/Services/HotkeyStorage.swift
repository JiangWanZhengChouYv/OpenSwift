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
            print("[HotkeyStorage] Saved \(configurations.count) hotkey configurations")
        } catch {
            print("[HotkeyStorage] Failed to save configurations: \(error)")
        }
    }

    func load() -> [HotkeyConfig] {
        guard let data = userDefaults.data(forKey: HotkeyStorage.storageKey) else {
            print("[HotkeyStorage] No saved configurations found, using defaults")
            return HotkeyConfig.defaultConfigurations()
        }

        do {
            let decoder = JSONDecoder()
            let configurations = try decoder.decode([HotkeyConfig].self, from: data)
            print("[HotkeyStorage] Loaded \(configurations.count) hotkey configurations")
            return configurations
        } catch {
            print("[HotkeyStorage] Failed to load configurations: \(error)")
            return HotkeyConfig.defaultConfigurations()
        }
    }

    func resetToDefaults() {
        userDefaults.removeObject(forKey: HotkeyStorage.storageKey)
        print("[HotkeyStorage] Reset to default configurations")
    }

    func saveSingle(_ config: HotkeyConfig) {
        var configurations = load()
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            save(configurations)
        }
    }
}
