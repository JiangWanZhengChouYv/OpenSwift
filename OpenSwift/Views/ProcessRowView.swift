import SwiftUI
import AppKit

struct ProcessRowView: View {
    let process: ProcessInfo
    let isSelected: Bool
    var isInjected: Bool = false
    var isActive: Bool = true
    var onInject: (() -> Void)? = nil
    var onEject: (() -> Void)? = nil
    var onRestartWithDYLD: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
            } else {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(process.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    
                    if isInjected {
                        injectionStatusBadge
                    }
                }
                
                HStack(spacing: 8) {
                    Text("PID: \(process.pid)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    if let bundleId = process.bundleIdentifier {
                        Text(bundleId)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            
            Spacer()
            
            if isSelected {
                Button(action: {
                    onRestartWithDYLD?()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 12))
                        Text("DYLD 重启")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if isInjected {
                onEject?()
            } else {
                onInject?()
            }
        }
    }
    
    private var injectionStatusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            
            Text(statusText)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.1))
        )
    }
    
    private var statusColor: Color {
        if !isActive {
            return Color.gray
        } else if isInjected {
            return Color(hex: "34C759")
        } else {
            return Color.clear
        }
    }
    
    private var statusText: String {
        if !isActive {
            return "已终止"
        } else if isInjected {
            return "已注入"
        } else {
            return ""
        }
    }
}

struct ProcessRowViewWithContextMenu: View {
    let process: ProcessInfo
    let isSelected: Bool
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var appLauncherViewModel: AppLauncherViewModel
    @State private var showConfirmDialog = false
    
    var body: some View {
        ProcessRowView(
            process: process,
            isSelected: isSelected,
            isInjected: processManager.isProcessInjected(process),
            isActive: processManager.processes.contains { $0.pid == process.pid },
            onInject: {
                processManager.injectSpeedControl(into: process)
            },
            onEject: {
                processManager.removeInjectedProcess(process)
            },
            onRestartWithDYLD: {
                showConfirmDialog = true
            }
        )
        .contextMenu {
            contextMenuContent
        }
        .alert(isPresented: $showConfirmDialog) {
            Alert(
                title: Text("使用 DYLD 重启应用"),
                message: Text("这将终止当前运行的 \(process.name) 并使用 DYLD_INSERT_LIBRARIES 重新启动。\n\n是否继续？"),
                primaryButton: .destructive(Text("重启")) {
                    restartAppWithDYLD()
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    @ViewBuilder
    private var contextMenuContent: some View {
        if processManager.isProcessInjected(process) {
            Button(action: {
                processManager.removeInjectedProcess(process)
            }) {
                Label("卸载 SpeedPatch", systemImage: "xmark.circle")
            }
            
            Divider()
            
            Button(action: {
                if let injected = processManager.getInjectedProcess(pid: process.pid) {
                    processManager.updateInjectedProcess(pid: process.pid, isEnabled: !injected.isEnabled)
                }
            }) {
                Label(
                    processManager.getInjectedProcess(pid: process.pid)?.isEnabled == true ? "禁用加速" : "启用加速",
                    systemImage: "speedometer"
                )
            }
            
            Menu("快速设置速度") {
                Button("0.5x (慢速)") {
                    processManager.updateInjectedProcess(pid: process.pid, speedRatio: 0.5)
                }
                Button("1.0x (正常)") {
                    processManager.updateInjectedProcess(pid: process.pid, speedRatio: 1.0)
                }
                Button("1.5x (加速)") {
                    processManager.updateInjectedProcess(pid: process.pid, speedRatio: 1.5)
                }
                Button("2.0x (快速)") {
                    processManager.updateInjectedProcess(pid: process.pid, speedRatio: 2.0)
                }
                Button("5.0x (超速)") {
                    processManager.updateInjectedProcess(pid: process.pid, speedRatio: 5.0)
                }
            }
        } else {
            Button(action: {
                processManager.injectSpeedControl(into: process)
            }) {
                Label("注入 SpeedPatch", systemImage: "plus.circle")
            }
        }
        
        Divider()
        
        Button(action: {
            copyProcessInfo()
        }) {
            Label("复制进程信息", systemImage: "doc.on.doc")
        }
        
        if let path = process.path {
            Button(action: {
                showInFinder(path: path)
            }) {
                Label("在 Finder 中显示", systemImage: "folder")
            }
        }
    }
    
    private func copyProcessInfo() {
        var info = "进程名称: \(process.name)\n"
        info += "PID: \(process.pid)\n"
        if let bundleId = process.bundleIdentifier {
            info += "Bundle ID: \(bundleId)\n"
        }
        if let path = process.path {
            info += "路径: \(path)"
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }
    
    private func showInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
    
    private func restartAppWithDYLD() {
        // 步骤 1: 先终止当前进程（如果还在运行）
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == process.pid }) {
            runningApp.terminate()
        }
        
        // 步骤 2: 找到应用路径并重新启动
        var targetURL: URL?
        var launchAsExecutable = false
        
        // 策略 A: 通过 bundle identifier 查找 .app 包（最可靠）
        if let bundleId = process.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            targetURL = url
        }
        // 策略 B: 从可执行文件路径向上查找 .app 包
        else if let path = process.path {
            let executableURL = URL(fileURLWithPath: path)
            
            var searchURL = executableURL
            var foundAppBundle = false
            
            while !searchURL.pathComponents.isEmpty {
                if searchURL.pathExtension == "app" {
                    targetURL = searchURL
                    foundAppBundle = true
                    break
                }
                // 检查是否包含 .app 目录（如 "MyApp.app"）
                if searchURL.lastPathComponent.contains(".app") {
                    targetURL = searchURL
                    foundAppBundle = true
                    break
                }
                
                // 到达根目录则停止
                if searchURL.path == "/" || searchURL.pathComponents.count <= 1 {
                    break
                }
                searchURL = searchURL.deletingLastPathComponent()
            }
            
            // 策略 C: 找不到 .app 包，直接使用可执行文件路径
            if !foundAppBundle {
                targetURL = executableURL
                launchAsExecutable = true
            }
        }
        
        // 步骤 3: 启动应用
        if let url = targetURL {
            // 等待原进程完全终止（给系统一点时间清理）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if launchAsExecutable {
                    appLauncherViewModel.launchExecutable(at: url)
                } else {
                    appLauncherViewModel.launchApp(at: url)
                }
            }
        } else {
            // 无法找到应用路径，显示详细错误
            DispatchQueue.main.async {
                let missingInfo = [
                    process.bundleIdentifier != nil ? "bundleId: \(process.bundleIdentifier!)" : nil,
                    process.path != nil ? "path: \(process.path!)" : nil,
                    "name: \(process.name)",
                    "pid: \(process.pid)"
                ].compactMap { $0 }.joined(separator: ", ")
                
                appLauncherViewModel.errorMessage = "无法找到应用 \(process.name) 的启动路径（\(missingInfo)）。请通过主界面的应用选择器重新启动。"
                appLauncherViewModel.showError = true
            }
        }
    }
}

struct ProcessRowView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            ProcessRowView(
                process: ProcessInfo(
                    pid: 1234,
                    name: "Safari",
                    path: "/Applications/Safari.app",
                    bundleIdentifier: "com.apple.Safari",
                    icon: nil
                ),
                isSelected: false,
                isInjected: false
            )
            
            ProcessRowView(
                process: ProcessInfo(
                    pid: 5678,
                    name: "Xcode",
                    path: "/Applications/Xcode.app",
                    bundleIdentifier: "com.apple.dt.Xcode",
                    icon: nil
                ),
                isSelected: true,
                isInjected: true,
                isActive: true
            )
            
            ProcessRowView(
                process: ProcessInfo(
                    pid: 9999,
                    name: "Terminated App",
                    path: nil,
                    bundleIdentifier: nil,
                    icon: nil
                ),
                isSelected: false,
                isInjected: true,
                isActive: false
            )
        }
        .frame(width: 300)
        .padding()
    }
}
