import SwiftUI

// MARK: - Home Plugin Controls（主加速页插件控件区）
extension SpeedControlPanel {
    /// 渲染所有已启用插件的 `slot=home` 控件。native=recursive_injection 时绑定
    /// 当前选中进程的递归注入开关，否则走通用 PluginUIControlView（配置存 PluginStore）。
    /// 外层按插件分组遍历，保证 homeControl 始终能拿到 pluginID。
    @ViewBuilder
    func homePluginControlsSection(for process: LaunchedProcess) -> some View {
        let homeElements = PluginStore.shared.plugins
            .filter(\.isEnabled)
            .flatMap { $0.manifest.ui }
            .filter { ($0.slot ?? "plugin") == "home" }

        if !homeElements.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(PluginStore.shared.plugins) { plugin in
                    if plugin.isEnabled {
                        ForEach(plugin.manifest.ui.filter { ($0.slot ?? "plugin") == "home" }) { element in
                            homeControl(for: element, pluginID: plugin.id, process: process)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func homeControl(for element: PluginUIElement, pluginID: String, process: LaunchedProcess) -> some View {
        switch element.native {
        case "recursive_injection":
            recursiveInjectionToggle(element: element, process: process)
        default:
            // 非 native 或未知 native 都退回通用控件，避免隐藏。
            PluginUIControlView(pluginID: pluginID, element: element)
        }
    }

    private func recursiveInjectionToggle(
        element: PluginUIElement,
        process: LaunchedProcess
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(element.label ?? "递归注入", isOn: Binding(
                get: { process.isRecursiveInjection },
                set: { newValue in
                    appLauncherViewModel.updateRecursiveInjection(newValue, for: process)
                }
            ))
            .toggleStyle(.switch)
            .font(.system(size: 13))
            Text("开启后子进程（Electron/Qt 等）也会注入加速")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
