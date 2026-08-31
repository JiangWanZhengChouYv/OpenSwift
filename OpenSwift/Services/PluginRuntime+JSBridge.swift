import Foundation
import JavaScriptCore

extension PluginRuntime {
    /// 向指定插件的 JSContext 注入宿主桥 `openSwift`。
    func injectBridge(context: JSContext, pluginID: String) {
        guard let bridge = JSValue(newObjectIn: context) else {
            logError("创建 openSwift 桥对象失败: \(pluginID)", log: .openswift)
            return
        }

        // openSwift.log(msg)：插件侧日志，统一走全局 logInfo。
        bridge.setObject({ (message: String) in
            logInfo("[plugin:\(pluginID)] \(message)", log: .openswift)
        } as @convention(block) (String) -> Void, forKeyedSubscript: "log")

        // openSwift.onProcessLaunch(callback)：保存 JS 回调，供启动事件分发时调用。
        bridge.setObject({ (callback: JSValue) in
            context.setObject(callback, forKeyedSubscript: "__openSwift_onProcessLaunch" as NSString)
        } as @convention(block) (JSValue) -> Void, forKeyedSubscript: "onProcessLaunch")

        // openSwift.setSpeed(pid, ratio)：按 pid 找到宿主进程并设置倍率。
        bridge.setObject({ (processID: Int, ratio: Double) in
            let processes = AppLauncherViewModel.shared.launchedProcesses
            guard let process = processes.first(where: { $0.pid == pid_t(processID) }) else {
                logError("setSpeed 未找到 pid \(processID) 对应的进程", log: .openswift)
                return
            }
            AppLauncherViewModel.shared.updateSpeed(ratio, for: process)
        } as @convention(block) (Int, Double) -> Void, forKeyedSubscript: "setSpeed")

        // openSwift.getConfig(key)：读取该插件的运行时配置并转成 JS 值。
        bridge.setObject({ (key: String) -> JSValue in
            switch PluginStore.shared.configValue(pluginID: pluginID, key: key) {
            case .bool(let flag):
                return JSValue(bool: flag, in: context)
            case .string(let text):
                return JSValue(object: text, in: context)
            case .integer(let value):
                return JSValue(int32: Int32(value), in: context)
            case .number(let value):
                return JSValue(double: value, in: context)
            case nil:
                return JSValue(undefinedIn: context)
            }
        } as @convention(block) (String) -> JSValue, forKeyedSubscript: "getConfig")

        context.setObject(bridge, forKeyedSubscript: "openSwift" as NSString)
    }
}
