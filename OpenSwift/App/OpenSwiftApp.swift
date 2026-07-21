import SwiftUI

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
            
            CommandGroup(after: .appInfo) {
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
}
