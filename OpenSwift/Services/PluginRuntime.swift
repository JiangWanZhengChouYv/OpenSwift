import Combine
import Foundation
import JavaScriptCore

/// 单个已启用且带脚本的插件在运行时中的上下文。
struct PluginContext {
    let pluginID: String
    let context: JSContext
    /// 进程启动时的分发回调，参数为 {pid, appName, appURL}。
    let onProcessLaunch: ([String: Any]) -> Void
}

/// 插件 L1-L2 运行时。
///
/// 负责加载每个「已启用且 manifest.script 非空」的插件脚本，通过 JavaScriptCore
/// 执行，并向插件 JS 注入宿主桥 `openSwift`。同时观察宿主已启动进程列表，
/// 将新出现的活跃进程分发给所有已加载插件。
class PluginRuntime: ObservableObject {
    static let shared = PluginRuntime()

    /// 插件 id -> 运行时上下文（含 JSContext 与启动回调）。
    private var contexts: [String: PluginContext] = [:]
    /// 已分发的进程 pid，避免重复触发。
    private var handledProcessPIDs: Set<pid_t> = []
    private var cancellables = Set<AnyCancellable>()
    private var hasSetup = false

    private init() {}

    /// 加载已启用且带脚本的插件，并开始观察进程启动事件。由应用初始化时调用。
    func setup() {
        guard !hasSetup else { return }
        hasSetup = true
        loadAll()
        observeLaunchedProcesses()
        dispatchCurrentlyLaunchedProcesses()
    }

    /// 卸载并按当前启用状态重新加载全部插件脚本。
    func reloadAll() {
        contexts.removeAll()
        handledProcessPIDs.removeAll()
        loadAll()
    }

    /// 卸载指定插件对应的运行上下文。
    func unload(pluginID: String) {
        contexts.removeValue(forKey: pluginID)
    }

    /// 调用插件脚本中导出的同名函数（用于 UI 按钮触发）。
    func callExportedFunction(pluginID: String, name: String) {
        guard let pluginContext = contexts[pluginID] else {
            logError("Plugin \(pluginID) 未加载，无法调用函数 \(name)", log: .openswift)
            return
        }
        pluginContext.context.evaluateScript("if (typeof \(name)==='function') \(name)();")
    }

    // MARK: - 脚本加载

    /// 遍历已启用且 script 非空的插件，加载并执行其脚本。
    private func loadAll() {
        for plugin in PluginStore.shared.plugins {
            guard plugin.isEnabled,
                  let script = plugin.manifest.script,
                  !script.isEmpty,
                  let directory = plugin.sourceDirectory else {
                continue
            }
            let scriptURL = directory.appendingPathComponent(script)
            guard let scriptContent = try? String(contentsOf: scriptURL, encoding: .utf8) else {
                logError("读取插件脚本失败: \(scriptURL.path)", log: .openswift)
                continue
            }
            guard let context = JSContext() else {
                logError("创建 JSContext 失败: \(plugin.id)", log: .openswift)
                continue
            }
            context.exceptionHandler = { _, exception in
                logError("插件脚本异常: \(String(describing: exception))", log: .openswift)
            }
            injectBridge(context: context, pluginID: plugin.id)
            context.evaluateScript(scriptContent)

            let onProcessLaunch: ([String: Any]) -> Void = { [weak self] info in
                guard let self, let activeContext = self.contexts[plugin.id]?.context else {
                    return
                }
                activeContext.objectForKeyedSubscript("__openSwift_onProcessLaunch")?.call(withArguments: [info])
            }
            contexts[plugin.id] = PluginContext(
                pluginID: plugin.id,
                context: context,
                onProcessLaunch: onProcessLaunch
            )
            logInfo("已加载插件脚本: \(plugin.id)", log: .openswift)
        }
    }

    // MARK: - 进程启动事件桥

    private func observeLaunchedProcesses() {
        AppLauncherViewModel.shared.$launchedProcesses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processes in
                self?.handleLaunchedProcesses(processes)
            }
            .store(in: &cancellables)
    }

    /// 对新出现的活跃进程分发启动事件给所有已加载插件。
    private func handleLaunchedProcesses(_ processes: [LaunchedProcess]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let freshProcesses = processes.filter {
                $0.isRunning && !self.handledProcessPIDs.contains($0.pid)
            }
            guard !freshProcesses.isEmpty else { return }
            for process in freshProcesses {
                self.handledProcessPIDs.insert(process.pid)
                let info: [String: Any] = [
                    "pid": process.pid,
                    "appName": process.appName,
                    "appURL": process.appURL.absoluteString
                ]
                for pluginContext in self.contexts.values {
                    pluginContext.onProcessLaunch(info)
                }
            }
        }
    }

    /// setup() 后立即把当前已存在的进程也分发一次，保证已启动进程也能触发。
    private func dispatchCurrentlyLaunchedProcesses() {
        handleLaunchedProcesses(AppLauncherViewModel.shared.launchedProcesses)
    }
}
