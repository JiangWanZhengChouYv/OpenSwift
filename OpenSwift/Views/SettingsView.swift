import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    var onDismiss: (() -> Void)? = nil
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundColor(.accentColor)
                Text("设置").font(.system(size: 16, weight: .semibold))
                Spacer()
            }.padding()
            Divider()
            HStack(spacing: 0) {
                sidebarView.frame(width: 180)
                Divider()
                contentView.frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("恢复默认设置") { showResetConfirmation() }.buttonStyle(.bordered)
                Spacer()
                Button("保存并关闭") { settings.save(); onDismiss?() }.buttonStyle(.bordered)
            }.padding()
        }
        .frame(width: 700, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab } }) {
                    HStack(spacing: 10) {
                        Image(systemName: tab.iconName).font(.system(size: 14)).frame(width: 20)
                        Text(tab.title).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedTab == tab ? .accentColor.opacity(0.15) : .clear)
                    )
                    .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder private var contentView: some View {
        switch selectedTab {
        case .general: GeneralSettingsView(settings: settings)
        case .interface: InterfaceSettingsView(settings: settings)
        case .hotkeys: HotkeySettingsView()
        case .advanced: AdvancedSettingsView(settings: settings)
        case .about: AboutSettingsView()
        }
    }

    private func showResetConfirmation() {
        let alert = NSAlert()
        alert.messageText = "恢复默认设置"
        alert.informativeText = "这将重置所有设置到默认值。确定要继续吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.resetToDefaults()
            NotificationCenter.default.post(name: .settingsDidReset, object: nil)
        }
    }
}

enum SettingsTab: Int, CaseIterable, Identifiable {
    case general, interface, hotkeys, advanced, about
    var id: String { String(rawValue) }
    var title: String { ["通用", "界面", "快捷键", "高级", "关于"][rawValue] }
    var iconName: String { ["gearshape", "paintbrush", "keyboard", "slider.horizontal.3", "info.circle"][rawValue] }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection(title: "启动与菜单栏") {
                    settingToggle($settings.launchAtLogin, label: "登录时启动", desc: "登录时自动启动")
                    settingToggle($settings.showInMenuBar, label: "在菜单栏显示图标", desc: "显示 OpenSwift 图标")
                    settingToggle($settings.minimizeToTray, label: "最小化到菜单栏", desc: "关闭窗口时最小化")
                }
                settingsSection(title: "快捷键") {
                    settingToggle($settings.hotkeyEnabled, label: "启用全局快捷键", desc: "使用快捷键控制速度")
                    settingToggle($settings.showSpeedNotifications, label: "显示速度通知", desc: "快捷键操作时通知")
                }
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InterfaceSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection(title: "进程列表") {
                    settingToggle($settings.showProcessIcons, label: "显示进程图标", desc: "显示应用图标")
                    settingToggle($settings.autoRefreshProcessList, label: "自动刷新", desc: "定期刷新进程")
                    if settings.autoRefreshProcessList {
                        HStack {
                            Text("刷新间隔：").font(.system(size: 13))
                            Slider(value: $settings.refreshInterval, in: 3...30, step: 1)
                            Text("\(Int(settings.refreshInterval)) 秒")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 50)
                        }
                    }
                }
                settingsSection(title: "速度控制") {
                    settingToggle($settings.rememberSpeedPerProcess, label: "记住速度设置", desc: "恢复上次速度")
                }
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showImportSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection(title: "数据管理") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("历史记录数量").font(.system(size: 13))
                            Text("保存的进程历史记录数量")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Stepper(value: $settings.maxHistoryCount, in: 10...500, step: 10) {
                            Text("\(settings.maxHistoryCount)")
                                .font(.system(size: 13, design: .monospaced))
                                .frame(width: 50)
                        }
                    }
                    settingToggle($settings.autoCleanupInactive, label: "自动清理", desc: "移除终止进程记录")
                }
                settingsSection(title: "导入导出") {
                    Button(action: exportConfiguration) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("导出配置")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: { showImportSheet = true }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("导入配置")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Text("导入配置将覆盖当前所有设置")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                settingsSection(title: "重置") {
                    deleteButton(action: clearProcessHistory, label: "清空进程历史", icon: "trash")
                    deleteButton(action: clearAllData, label: "清空所有数据", icon: "exclamationmark.triangle")
                }
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $showImportSheet,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                importConfiguration(from: url)
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func deleteButton(action: @escaping () -> Void, label: String, icon: String) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(label)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .foregroundColor(.red)
    }

    private func exportConfiguration() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "OpenSwift-Config.json"
        savePanel.canCreateDirectories = true

        if savePanel.runModal() == .OK, let url = savePanel.url,
           let data = AppSettings.shared.exportConfiguration() {
            do {
                try data.write(to: url)
                showAlert(title: "导出成功", message: "配置已成功导出")
            } catch {
                showAlert(title: "导出失败", message: error.localizedDescription)
            }
        }
    }

    private func importConfiguration(from url: URL) {
        do {
            try AppSettings.shared.importConfiguration(from: Data(contentsOf: url))
            showAlert(title: "导入成功", message: "配置已成功导入")
        } catch {
            showAlert(title: "导入失败", message: error.localizedDescription)
        }
    }

    private func clearProcessHistory() {
        let alert = NSAlert()
        alert.messageText = "清空进程历史"
        alert.informativeText = "确定要清空所有进程历史记录吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            ProcessHistory.shared.clearHistory()
        }
    }

    private func clearAllData() {
        let alert = NSAlert()
        alert.messageText = "清空所有数据"
        alert.informativeText = "这将清空所有设置、历史记录和快捷键配置。此操作不可撤销！"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "清空所有数据")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            AppSettings.shared.resetToDefaults()
            HotkeyStorage.shared.resetToDefaults()
            ProcessHistory.shared.clearHistory()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}

struct AboutSettingsView: View {
    private let appVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 16) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                    Text("OpenSwift")
                        .font(.system(size: 24, weight: .bold))
                    Text("版本 \(appVersion)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)

                aboutSection(title: "关于", text: "OpenSwift 是一个强大的 macOS 进程速度控制工具，允许您实时调整任何进程的运行速度。")

                aboutSection(title: "功能特点") {
                    featureItem("bolt.fill", "多进程独立变速")
                    featureItem("speedometer", "实时速度控制")
                    featureItem("folder.fill", "进程组管理")
                    featureItem("keyboard", "全局快捷键支持")
                    featureItem("gearshape.fill", "灵活的配置选项")
                }

                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func aboutSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func aboutSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func featureItem(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text).font(.system(size: 13))
        }
    }
}

private func settingToggle(_ binding: Binding<Bool>, label: String, desc: String) -> some View {
    Toggle(isOn: binding) {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13))
            Text(desc).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
    .toggleStyle(.switch)
}

private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.primary)
        content()
            .padding()
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }
}
