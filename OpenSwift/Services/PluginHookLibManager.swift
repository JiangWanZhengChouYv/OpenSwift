import Foundation

/// 宿主导出的注册函数：供插件 hooklib 在被 dlopen 后调用，声明它适配的目标进程。
///
/// hooklib 内用 `dlsym(RTLD_DEFAULT, "openswift_plugin_register_target")` 获取并调用，
/// 例如：
/// ```c
/// void (*reg)(const char*, const char*) =
///     (void(*)(const char*, const char*))dlsym(RTLD_DEFAULT, "openswift_plugin_register_target");
/// if (reg) reg("com.example.App", "ProcessName");
/// ```
@_cdecl("openswift_plugin_register_target")
public func openswift_plugin_register_target(
    _ bundleId: UnsafePointer<CChar>?,
    _ process: UnsafePointer<CChar>?
) {
    var bid: String? = nil
    if let bundleId, let s = String(cString: bundleId, encoding: .utf8), !s.isEmpty {
        bid = s
    }
    var proc: String? = nil
    if let process, let s = String(cString: process, encoding: .utf8), !s.isEmpty {
        proc = s
    }
    PluginHookLibManager.shared.registerTargetFromCurrentHook(bundleId: bid, process: proc)
}

/// L3 原生扩展（hooklib.dylib）管理器。
///
/// 对「已启用且带 hooklib」的插件：`dlopen` 其 dylib、`dlsym` 入口并调用，
/// 收集 hooklib 声明的适配目标（经 `openswift_plugin_register_target`），
/// 维护 `(目标匹配规则, hooklib 绝对路径)` 注册表，供注入时按目标附加。
final class PluginHookLibManager {
    static let shared = PluginHookLibManager()

    /// 一条 hooklib 的适配目标规则。
    struct TargetRule {
        let pluginID: String
        let bundleId: String?
        let process: String?
        let hooklibPath: String

        /// 命中判断：bundleId 精确匹配（传入时）或 process 包含匹配。
        func matches(appName: String, bundleId: String?) -> Bool {
            if let bid = bundleId, let ruleBid = self.bundleId, !ruleBid.isEmpty, bid == ruleBid {
                return true
            }
            if let proc = process, !proc.isEmpty, appName.contains(proc) {
                return true
            }
            return false
        }
    }

    /// 宿主导入约定：hooklib 入口符号名默认值。
    static let defaultEntry = "SpeedPatchRegisterHook"

    /// pluginID -> 绝对路径（已加载的 hooklib）。
    private(set) var loadedCache: [String: String] = [:]
    private var targetRules: [TargetRule] = []

    /// dlopen 后当前正在注册目标的 hooklib 所属插件 id。
    private var currentRegisteringPluginID: String?

    private let lock = NSLock()

    private init() {}

    // MARK: - 生命周期

    /// App 初始化时调用；清空并根据当前启用状态重载全部 hhooklib。
    func setup() {
        reloadAll()
    }

    /// 遍历已启用且带 hooklib 的插件，加载并收集注册目标。
    func reloadAll() {
        lock.lock()
        loadedCache.removeAll()
        targetRules.removeAll()
        let plugins = PluginStore.shared.plugins
        lock.unlock()

        for plugin in plugins {
            guard plugin.isEnabled, let hooklibRel = plugin.manifest.hooklib, !hooklibRel.isEmpty,
                  let dir = plugin.sourceDirectory else {
                continue
            }
            let abs = dir.appendingPathComponent(hooklibRel).path
            load(hooklibPath: abs, pluginID: plugin.id, entry: plugin.manifest.hooklibEntry ?? Self.defaultEntry)
        }
    }

    /// 卸载指定插件关联的 hooklib 及其注册目标。
    func unload(pluginID: String) {
        lock.lock()
        loadedCache.removeValue(forKey: pluginID)
        targetRules.removeAll { $0.pluginID == pluginID }
        lock.unlock()
    }

    // MARK: - 查询

    /// 返回命中目标（按 appName / bundleId）的全部 hooklib 绝对路径（去重、保序）。
    func hooklibPaths(forAppName appName: String, bundleId: String?) -> [String] {
        lock.lock()
        var seen = Set<String>()
        var result: [String] = []
        for rule in targetRules where rule.matches(appName: appName, bundleId: bundleId) {
            if seen.insert(rule.hooklibPath).inserted {
                result.append(rule.hooklibPath)
            }
        }
        lock.unlock()
        return result
    }

    // MARK: - hooklib 注册（由宿主 cdecl 转发）

    /// `openswift_plugin_register_target` 转发入口：记录当前加载 hooklib 的适配目标。
    func registerTargetFromCurrentHook(bundleId: String?, process: String?) {
        lock.lock()
        guard let pluginID = currentRegisteringPluginID, let path = loadedCache[pluginID] else {
            lock.unlock()
            return
        }
        targetRules.append(TargetRule(pluginID: pluginID, bundleId: bundleId, process: process, hooklibPath: path))
        lock.unlock()
        logInfo("L3 hooklib registered target for \(pluginID)", log: .openswift)
    }

    // MARK: - 加载

    private func load(hooklibPath: String, pluginID: String, entry: String) {
        guard FileManager.default.fileExists(atPath: hooklibPath) else {
            logError("L3 hooklib 不存在: \(hooklibPath)", log: .openswift)
            return
        }
        // dlopen 触发 constructor，可能即注册目标；先标记当前插件上下文
        lock.lock()
        currentRegisteringPluginID = pluginID
        lock.unlock()
        defer {
            lock.lock()
            currentRegisteringPluginID = nil
            lock.unlock()
        }

        // ad-hoc 重签名，保证含 hardened runtime 的目标可加载；失败仅记录不阻塞。
        adHocSignIfNeeded(hooklibPath)

        guard let handle = dlopen(hooklibPath, RTLD_NOW | RTLD_LOCAL) else {
            if let err = dlerror() {
                logError("L3 dlopen 失败 \(hooklibPath): \(String(cString: err))", log: .openswift)
            }
            return
        }

        lock.lock()
        loadedCache[pluginID] = hooklibPath
        lock.unlock()

        if let symbol = dlsym(handle, entry) {
            typealias EntryFn = @convention(c) () -> Void
            let fn = unsafeBitCast(symbol, to: EntryFn.self)
            fn()
            logInfo("L3 hooklib loaded \(hooklibPath) entry=\(entry)", log: .openswift)
        } else if let err = dlerror() {
            logError("L3 未找到入口符号 \(entry): \(String(cString: err))", log: .openswift)
        }
    }

    /// 对 dylib 做 ad-hoc 重签名（`codesign --force --sign -`），确保可被 hardened runtime 目标加载。
    private func adHocSignIfNeeded(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--deep", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logDebug("L3 ad-hoc signed hooklib: \(path)", log: .openswift)
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                logError("L3 codesign 失败 \(path): \(String(data: data, encoding: .utf8) ?? "")", log: .openswift)
            }
        } catch {
            logError("L3 无法执行 codesign: \(error.localizedDescription)", log: .openswift)
        }
    }
}
