import SwiftUI
import AppKit

@main
struct OpenSwiftApp: App {
    @State private var showMenuBar = true
    
    var body: some Scene {
        Window("OpenSwift", id: "main") {
            ContentView()
                .onAppear {
                    AppState.shared.setup()
                }
        }
        .defaultPosition(.center)
        .defaultSize(CGSize(width: 1000, height: 700))
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("文件") {
                Button("刷新进程列表") {
                    ProcessManagerProvider.shared.manager.refreshProcesses()
                }
                .keyboardShortcut("r", modifiers: .command)
                
                Divider()
                
                Button("清理已终止进程") {
                    AppLauncherViewModel.shared.cleanupTerminatedProcesses()
                }
            }
            
            CommandMenu("编辑") {
                Button("撤销") { }
                .keyboardShortcut("z", modifiers: .command)
                
                Button("重做") { }
                .keyboardShortcut("Z", modifiers: [.command, .shift])
                
                Divider()
                
                Button("剪切") { }
                .keyboardShortcut("x", modifiers: .command)
                
                Button("复制") { }
                .keyboardShortcut("c", modifiers: .command)
                
                Button("粘贴") { }
                .keyboardShortcut("v", modifiers: .command)
                
                Button("全选") { }
                .keyboardShortcut("a", modifiers: .command)
            }
            
            CommandMenu("工具") {
                Button("静态打包应用...") {
                    AppState.shared.staticPatchFlowFromMenu()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            
            CommandGroup(after: .appInfo) {
                Button("检查更新...") {
                    UpdateManager.shared.checkForUpdates()
                }

                Button("快捷键设置...") {
                    AppState.shared.showHotkeySettings = true
                }
                .keyboardShortcut("k", modifiers: .command)
                
                Button("设置...") {
                    AppState.shared.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            CommandGroup(replacing: .appTermination) {
                Button("退出 OpenSwift") {
                    AppState.shared.shutdown()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        
        MenuBarExtra("OpenSwift", systemImage: "speedometer", isInserted: $showMenuBar) {
            MenuBarContentView(showMenuBar: $showMenuBar)
        }
        .menuBarExtraStyle(.window)
    }
}

class AppState {
    static let shared = AppState()
    
    var showHotkeySettings = false
    var showSettings = false
    
    func setup() {
        AppSettings.shared.bootstrapSideEffects()
        MenuBarController.shared.setup()
        HotkeyService.shared.setup()
        SpeedControlState.shared.setup()
        AppLauncherViewModel.shared.setup()
        AppLauncher.shared.setup()
        ProcessHistory.shared.setup()
        ProcessManagerProvider.shared.manager.setup()
        CLIManager.shared.setup()
        PluginStore.shared.setup()
        PluginRuntime.shared.setup()
        PluginHookLibManager.shared.setup()
        
        logInfo("OpenSwift launched successfully", log: .openswift)
    }
    
    func shutdown() {
        logDebug("Application terminating, cleaning up...", log: .openswift)
        
        HotkeyService.shared.shutdown()
        MenuBarController.shared.shutdown()
        AppLauncherViewModel.shared.shutdown()
        ProcessManagerProvider.shared.manager.shutdown()
        AppLauncher.shared.shutdown()
        SpeedControlState.shared.shutdown()
        ProcessHistory.shared.shutdown()
        AppSettings.shared.shutdown()
        CLIManager.shared.shutdown()
        ProcessManagerProvider.shared.manager.cleanupAll()
    }
    
    func staticPatchFlowFromMenu() {
        DispatchQueue.main.async {
            let openPanel = NSOpenPanel()
            openPanel.canChooseDirectories = false
            openPanel.canChooseFiles = true
            openPanel.allowedContentTypes = [.applicationBundle]
            openPanel.allowsOtherFileTypes = true
            openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
            openPanel.title = "选择要打包的应用"
            guard openPanel.runModal() == .OK, let sourceURL = openPanel.url else { return }
            let defaultName = sourceURL.deletingPathExtension().lastPathComponent + "_Patched"
            let savePanel = NSSavePanel()
            savePanel.title = "保存打包后的应用"
            savePanel.nameFieldStringValue = defaultName
            savePanel.canCreateDirectories = true
            savePanel.allowedContentTypes = [.applicationBundle]
            savePanel.directoryURL = sourceURL.deletingLastPathComponent()
            guard savePanel.runModal() == .OK, let outputURL = savePanel.url else { return }
            let alert = NSAlert()
            alert.messageText = "正在打包..."
            alert.informativeText = sourceURL.lastPathComponent + " → " + outputURL.lastPathComponent
            alert.addButton(withTitle: "取消")
            let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 20, width: 200, height: 20))
            progress.style = .spinning
            progress.startAnimation(nil)
            alert.accessoryView = progress
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try StaticPatchService.shared.patchApp(
                        at: sourceURL, outputURL: outputURL, overwrite: true
                    )
                    DispatchQueue.main.async { self.showStaticPatchSuccess(alert: alert, result: result) }
                } catch {
                    DispatchQueue.main.async { self.showStaticPatchFailure(alert: alert, error: error) }
                }
            }
            _ = alert.runModal()
        }
    }

    private func showStaticPatchSuccess(alert: NSAlert, result: URL) {
        alert.window.close()
        let ok = NSAlert()
        ok.messageText = "打包成功"
        ok.informativeText = "已生成：\(result.path)"
        ok.addButton(withTitle: "在 Finder 中显示")
        ok.addButton(withTitle: "关闭")
        if ok.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([result])
        }
    }

    private func showStaticPatchFailure(alert: NSAlert, error: Error) {
        alert.window.close()
        let fail = NSAlert()
        fail.messageText = "打包失败"
        fail.informativeText = error.localizedDescription
        fail.addButton(withTitle: "关闭")
        fail.runModal()
    }
}
