import SwiftUI

struct HotkeySettingsView: View {
    @ObservedObject var hotkeyService = HotkeyService.shared
    @State private var showPermissionAlert: Bool = false
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    if !hotkeyService.hasAccessibilityPermission {
                        permissionWarning
                    }

                    hotkeyListSection

                    batchActionsSection

                    tipsSection
                }
                .padding()
            }

            Divider()

            footerSection
        }
        .frame(width: 600, height: 600)
        .sheet(isPresented: $showPermissionAlert) {
            PermissionAlertView {
                showPermissionAlert = false
            }
        }
    }

    private var headerSection: some View {
        HStack {
            Text("全局快捷键设置")
                .font(.system(size: 18, weight: .bold))

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(hotkeyService.isEnabled ? Color(hex: "34C759") : Color.gray)
                    .frame(width: 8, height: 8)

                Text(hotkeyService.isEnabled ? "已启用" : "已禁用")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var permissionWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundColor(Color(hex: "FF9500"))

            VStack(alignment: .leading, spacing: 4) {
                Text("需要辅助功能权限")
                    .font(.system(size: 14, weight: .semibold))

                Text("全局快捷键需要辅助功能权限才能在应用后台正常工作")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("授予权限") {
                hotkeyService.requestPermissions()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    hotkeyService.checkPermissions()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "FF9500").opacity(0.1))
        )
    }

    private var hotkeyListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷键列表")
                .font(.system(size: 14, weight: .semibold))

            VStack(spacing: 8) {
                ForEach(hotkeyService.configurations) { config in
                    HotkeyRowView(
                        config: config,
                        onToggle: { isEnabled in
                            hotkeyService.updateEnabled(config.id, isEnabled: isEnabled)
                        },
                        onUpdate: { newKeyCode, newModifiers in
                            var updatedConfig = config
                            updatedConfig.keyCode = newKeyCode
                            updatedConfig.modifiers = newModifiers
                            hotkeyService.updateConfiguration(updatedConfig)
                        }
                    )
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var batchActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批量操作")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 12) {
                Button(action: {
                    hotkeyService.enableAll()
                }) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("全部启用")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)

                Button(action: {
                    hotkeyService.disableAll()
                }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("全部禁用")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)

                Button(action: {
                    hotkeyService.resetToDefaults()
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("恢复默认")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("使用提示")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                tipRow(icon: "keyboard", text: "快捷键在应用后台也有效")
                tipRow(icon: "command", text: "需要至少一个修饰键（⌘⌥⌃⇧）")
                tipRow(icon: "pencil", text: "点击「修改」按钮录制新快捷键")
                tipRow(icon: "xmark.circle", text: "按 ESC 键取消录制")
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var footerSection: some View {
        HStack {
            Button(action: {
                onDismiss?()
            }) {
                Text("完成")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionAlertView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(hex: "FF9500"))

            Text("需要辅助功能权限")
                .font(.system(size: 18, weight: .semibold))

            Text("全局快捷键需要辅助功能权限才能在应用后台正常工作。\n请在系统偏好设置中授予 OpenSwift 辅助功能权限。")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                Button("打开系统偏好设置") {
                    openAccessibilityPreferences()
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button("稍后") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(30)
        .frame(width: 400)
    }

    private func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct HotkeyRowView: View {
    let config: HotkeyConfig
    let onToggle: (Bool) -> Void
    let onUpdate: (UInt32, UInt32) -> Void

    @State private var keyCode: UInt32
    @State private var modifiers: UInt32
    @State private var isEditing: Bool = false

    init(config: HotkeyConfig, onToggle: @escaping (Bool) -> Void, onUpdate: @escaping (UInt32, UInt32) -> Void) {
        self.config = config
        self.onToggle = onToggle
        self.onUpdate = onUpdate
        _keyCode = State(initialValue: config.keyCode)
        _modifiers = State(initialValue: config.modifiers)
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { config.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Text(config.action.displayName)
                .font(.system(size: 13))
                .frame(minWidth: 100, alignment: .leading)

            Spacer()

            HotkeyRecorderView(
                keyCode: $keyCode,
                modifiers: $modifiers
            )
            .onChange(of: keyCode) { newValue in
                onUpdate(newValue, modifiers)
            }
            .onChange(of: modifiers) { newValue in
                onUpdate(keyCode, newValue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
    }
}
