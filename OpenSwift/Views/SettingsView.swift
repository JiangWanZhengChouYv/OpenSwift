import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    var onDismiss: (() -> Void)? = nil
    
    @State private var selectedTab: SettingsTab = .general
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            HStack(spacing: 0) {
                sidebarView
                    .frame(width: 180)
                
                Divider()
                
                contentView
                    .frame(maxWidth: .infinity)
            }
            
            Divider()
            
            footerView
        }
        .frame(width: 700, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var headerView: some View {
        HStack {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            
            Text("设置")
                .font(.system(size: 16, weight: .semibold))
            
            Spacer()
        }
        .padding()
    }
    
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 14))
                            .frame(width: 20)
                        
                        Text(tab.title)
                            .font(.system(size: 13))
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView(settings: settings)
        case .interface:
            InterfaceSettingsView(settings: settings)
        case .hotkeys:
            HotkeySettingsView()
        case .advanced:
            AdvancedSettingsView(settings: settings)
        case .about:
            AboutSettingsView()
        }
    }
    
    private var footerView: some View {
        HStack {
            Button("恢复默认设置") {
                showResetConfirmation()
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            Button("保存并关闭") {
                settings.save()
                onDismiss?()
            }
            .buttonStyle(.bordered)
        }
        .padding()
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

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "general"
    case interface = "interface"
    case hotkeys = "hotkeys"
    case advanced = "advanced"
    case about = "about"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .general: return "通用"
        case .interface: return "界面"
        case .hotkeys: return "快捷键"
        case .advanced: return "高级"
        case .about: return "关于"
        }
    }
    
    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .interface: return "paintbrush"
        case .hotkeys: return "keyboard"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection(title: "启动与菜单栏") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $settings.launchAtLogin) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("登录时启动")
                                    .font(.system(size: 13))
                                Text("在登录时自动启动 OpenSwift")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        
                        Toggle(isOn: $settings.showInMenuBar) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("在菜单栏显示图标")
                                    .font(.system(size: 13))
                                Text("在菜单栏显示 OpenSwift 图标")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        
                        Toggle(isOn: $settings.minimizeToTray) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("最小化到菜单栏")
                                    .font(.system(size: 13))
                                Text("关闭窗口时最小化到菜单栏而不是退出")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                
                settingsSection(title: "快捷键") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $settings.hotkeyEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("启用全局快捷键")
                                    .font(.system(size: 13))
                                Text("使用快捷键控制进程速度")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        
                        Toggle(isOn: $settings.showSpeedNotifications) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("显示速度通知")
                                    .font(.system(size: 13))
                                Text("使用快捷键时显示通知")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            
            content()
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
        }
    }
}

struct InterfaceSettingsView: View {
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection(title: "进程列表") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $settings.showProcessIcons) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("显示进程图标")
                                    .font(.system(size: 13))
                                Text("在进程列表中显示应用图标")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        
                        Toggle(isOn: $settings.autoRefreshProcessList) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自动刷新进程列表")
                                    .font(.system(size: 13))
                                Text("定期自动刷新运行中的进程")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        
                        if settings.autoRefreshProcessList {
                            HStack {
                                Text("刷新间隔：")
                                    .font(.system(size: 13))
                                
                                Slider(value: $settings.refreshInterval, in: 3...30, step: 1)
                                
                                Text("\(Int(settings.refreshInterval)) 秒")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .frame(width: 50)
                            }
                        }
                    }
                }
                
                settingsSection(title: "速度控制") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $settings.rememberSpeedPerProcess) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("为每个进程记住速度设置")
                                    .font(.system(size: 13))
                                Text("记录并恢复每个进程的上次速度设置")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            
            content()
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
        }
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showImportSheet = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection(title: "数据管理") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("历史记录数量")
                                    .font(.system(size: 13))
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
                        
                        Toggle(isOn: $settings.autoCleanupInactive) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自动清理已终止进程")
                                    .font(.system(size: 13))
                                Text("自动移除已终止进程的注入记录")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                
                settingsSection(title: "导入与导出") {
                    VStack(alignment: .leading, spacing: 12) {
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
                }
                
                settingsSection(title: "重置") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button(action: clearProcessHistory) {
                            HStack {
                                Image(systemName: "trash")
                                Text("清空进程历史")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                        
                        Button(action: clearAllData) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                Text("清空所有数据")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
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
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                _ = url.startAccessingSecurityScopedResource()
                importConfiguration(from: url)
                url.stopAccessingSecurityScopedResource()
            case .failure(let error):
                print("Import failed: \(error)")
            }
        }
    }
    
    @ViewBuilder
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            
            content()
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
        }
    }
    
    private func exportConfiguration() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "OpenSwift-Config.json"
        savePanel.canCreateDirectories = true
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            if let data = AppSettings.shared.exportConfiguration() {
                do {
                    try data.write(to: url)
                    showAlert(title: "导出成功", message: "配置已成功导出到 \(url.lastPathComponent)")
                } catch {
                    showAlert(title: "导出失败", message: error.localizedDescription)
                }
            }
        }
    }
    
    private func importConfiguration(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            try AppSettings.shared.importConfiguration(from: data)
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
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("关于")
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text("OpenSwift 是一个强大的 macOS 进程速度控制工具，允许您实时调整任何进程的运行速度。")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("功能特点")
                        .font(.system(size: 14, weight: .semibold))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        featureItem(icon: "bolt.fill", text: "多进程独立变速")
                        featureItem(icon: "speedometer", text: "实时速度控制")
                        featureItem(icon: "folder.fill", text: "进程组管理")
                        featureItem(icon: "keyboard", text: "全局快捷键支持")
                        featureItem(icon: "gearshape.fill", text: "灵活的配置选项")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func featureItem(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            
            Text(text)
                .font(.system(size: 13))
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
