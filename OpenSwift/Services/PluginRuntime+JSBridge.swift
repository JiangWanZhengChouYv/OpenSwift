import Foundation
import JavaScriptCore

/// 为插件 JS 提供 setTimeout/clearTimeout 的宿主定时器容器。
private final class JSTimerBox {
    var timers: [Int: Timer] = [:]
    var counter: Int = 0
}

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
            AppLauncherViewModel.shared.setSpeedAndEnabled(ratio, for: process)
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

        injectTimers(context: context)
    }

    /// JSContext 默认没有 setTimeout/clearTimeout，这里用宿主 Timer 注入，
    /// 供插件做定时/分段调度（如定时调整倍率按「倍率-时长」分段走）。
    private func injectTimers(context: JSContext) {
        let timerBox = JSTimerBox()

        context.setObject({ (function: JSValue, delay: Double) -> Int in
            timerBox.counter += 1
            let id = timerBox.counter
            let timer = Timer(timeInterval: max(delay, 0) / 1000.0, repeats: false) { _ in
                timerBox.timers.removeValue(forKey: id)
                DispatchQueue.main.async { function.call(withArguments: []) }
            }
            RunLoop.main.add(timer, forMode: .common)
            timerBox.timers[id] = timer
            return id
        } as @convention(block) (JSValue, Double) -> Int, forKeyedSubscript: "setTimeout" as NSString)

        context.setObject({ (id: Int) in
            timerBox.timers.removeValue(forKey: id)?.invalidate()
        } as @convention(block) (Int) -> Void, forKeyedSubscript: "clearTimeout" as NSString)
    }
}
