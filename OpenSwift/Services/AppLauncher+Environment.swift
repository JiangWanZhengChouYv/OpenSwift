import Foundation

extension AppLauncher {
    /// 构造 DYLD 注入启动环境：把命中的 L3 hooklib 用「:」追加到 SpeedPatch 后。
    func makeLaunchEnvironment(
        dylibPath: String,
        appName: String,
        bundleId: String?
    ) -> (String, [String: String]) {
        let extra = PluginHookLibManager.shared.hooklibPaths(forAppName: appName, bundleId: bundleId)
        let insert = extra.isEmpty ? dylibPath : ([dylibPath] + extra).joined(separator: ":")
        return (insert, [
            "DYLD_INSERT_LIBRARIES": insert,
            "DYLD_FORCE_FLAT_NAMESPACE": "1"
        ])
    }
}
