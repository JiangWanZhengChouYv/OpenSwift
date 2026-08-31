import Combine
import Foundation

/// 已导入插件的存储。
///
/// 插件列表保存在内存中，并通过 UserDefaults 以 JSON 形式持久化，
/// 应用启动时调用 `setup()` 恢复已导入的插件。
class PluginStore: ObservableObject {
    static let shared = PluginStore()
    static let storageKey = "InstalledPlugins"

    @Published private(set) var plugins: [Plugin] = []

    private let userDefaults = UserDefaults.standard
    private var isSetup = false

    private init() {}

    /// 恢复持久化的插件列表。由上层在应用初始化时调用。
    func setup() {
        guard !isSetup else { return }
        isSetup = true
        load()
        logInfo("PluginStore setup complete with \(plugins.count) plugins", log: .openswift)
    }

    var count: Int {
        plugins.count
    }

    var enabledCount: Int {
        plugins.filter { $0.isEnabled }.count
    }

    /// 查找指定 id 的插件。
    func plugin(withID id: String) -> Plugin? {
        plugins.first { $0.id == id }
    }

    /// 判断插件是否已导入。
    func hasPlugin(id: String) -> Bool {
        plugin(withID: id) != nil
    }

    /// 安装一个新插件；若 id 已存在则替换为新的实例。
    @discardableResult
    func add(_ plugin: Plugin) -> Bool {
        if let index = plugins.firstIndex(where: { $0.id == plugin.id }) {
            plugins[index] = plugin
        } else {
            plugins.append(plugin)
        }
        save()
        return true
    }

    /// 移除指定插件。
    func remove(id: String) {
        plugins.removeAll { $0.id == id }
        save()
    }

    /// 清空所有插件。
    func removeAll() {
        plugins.removeAll()
        save()
    }

    /// 切换插件的启用状态。
    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            return
        }
        plugins[index].isEnabled = enabled
        save()
    }

    func shutdown() {
        save()
        logInfo("PluginStore shutdown complete", log: .openswift)
    }

    // MARK: - 持久化

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(plugins)
            userDefaults.set(data, forKey: PluginStore.storageKey)
        } catch {
            logError("Failed to save plugins: \(error.localizedDescription)", log: .openswift)
        }
    }

    private func load() {
        guard let data = userDefaults.data(forKey: PluginStore.storageKey) else {
            return
        }
        do {
            let decoder = JSONDecoder()
            plugins = try decoder.decode([Plugin].self, from: data)
        } catch {
            logError("Failed to load plugins: \(error.localizedDescription)", log: .openswift)
            plugins = []
        }
    }
}
