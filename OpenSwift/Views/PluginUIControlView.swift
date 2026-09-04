import SwiftUI

/// 复用控件渲染组件：供插件面板与主加速页两处使用。
struct PluginUIControlView: View {
    let pluginID: String
    let element: PluginUIElement

    var body: some View {
        switch element.type {
        case "toggle": toggleControl
        case "button": buttonControl
        case "text": textControl
        case "number": numberControl
        case "list": PluginScheduleEditor(pluginID: pluginID, key: element.key, label: element.label)
        default: EmptyView()
        }
    }

    /// 插件是否已启用且带可执行脚本，用于 button 控件的可用性。
    private var hasScript: Bool {
        guard let plugin = PluginStore.shared.plugin(withID: pluginID) else {
            return false
        }
        guard let script = plugin.manifest.script else {
            return false
        }
        return !script.isEmpty && plugin.isEnabled
    }

    private var toggleControl: some View {
        let isOn = Binding<Bool>(
            get: {
                let configured = PluginStore.shared.configValue(pluginID: pluginID, key: element.key)
                if case .bool(let value)? = configured {
                    return value
                }
                if case .bool(let value)? = element.defaultValue {
                    return value
                }
                return false
            },
            set: { newValue in
                PluginStore.shared.setConfig(.bool(newValue), forKey: element.key, pluginID: pluginID)
            }
        )
        return Toggle(element.label ?? element.key, isOn: isOn)
            .toggleStyle(.switch)
            .font(.system(size: 12))
    }

    private var buttonControl: some View {
        Button(element.label ?? element.key) {
            PluginRuntime.shared.callExportedFunction(pluginID: pluginID, name: element.key)
        }
        .font(.system(size: 12))
        .disabled(!hasScript)
    }

    private var textControl: some View {
        let text = Binding<String>(
            get: {
                let configuredValue = PluginStore.shared.configValue(pluginID: pluginID, key: element.key)
                if case .string(let value)? = configuredValue {
                    return value
                }
                if case .string(let value)? = element.defaultValue {
                    return value
                }
                return ""
            },
            set: { newValue in
                PluginStore.shared.setConfig(.string(newValue), forKey: element.key, pluginID: pluginID)
            }
        )
        return TextField(element.label ?? element.key, text: text)
            .font(.system(size: 12))
    }

    private var numberControl: some View {
        let number = Binding<String>(
            get: {
                let configuredValue = PluginStore.shared.configValue(pluginID: pluginID, key: element.key)
                if case .number(let value)? = configuredValue {
                    return String(format: "%.3f", value)
                }
                if case .number(let value)? = element.defaultValue {
                    return String(format: "%.3f", value)
                }
                return ""
            },
            set: { newValue in
                if let value = Double(newValue) {
                    PluginStore.shared.setConfig(.number(value), forKey: element.key, pluginID: pluginID)
                }
            }
        )
        return TextField(element.label ?? element.key, text: number)
            .font(.system(size: 12))
    }
}
