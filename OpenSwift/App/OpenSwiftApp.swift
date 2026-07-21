import AppKit
import SwiftUI
import Combine

// 关键修复: applicationDidFinishLaunching 中按正确顺序初始化
// 1. 先激活应用
// 2. 立即显示窗口 (这是最重要的)
// 3. 然后在主线程异步初始化其他组件 (singletons, timer 等)
//
// 注意: AppDelegate 的 let 属性是在 init 时初始化的，这可能会触发 singleton 循环
// 所以把所有 singleton 引用移到方法内懒加载
class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        logInfo("applicationDidFinishLaunching - START", log: .openswift)
        
        // 第一步: 激活应用到前台
        NSApp.activate(ignoringOtherApps: true)
        
        // 第二步: 立即创建并显示窗口
        let contentView = ContentView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "OpenSwift"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        
        logDebug("Window should now be visible", log: .openswift)
        
        // 第三步: 异步初始化其他组件 (在 window 显示之后)
        // 这样即使某个组件初始化慢，用户也能先看到窗口
        DispatchQueue.main.async { [weak self] in
            self?.finishInitialization()
        }
    }
    
    private func finishInitialization() {
        logDebug("Starting delayed initialization...", log: .openswift)
        
        // 按顺序初始化，确保依赖关系正确
        // 1. SettingsStorage 通过 AppSettings.shared 隐式初始化
        // 2. AppSettings.bootstrapSideEffects() 启动 didSet 副作用
        // 3. MenuBarController.setup() 读取 AppSettings.showInMenuBar
        // 4. HotkeyService.setup() 读取 AppSettings.hotkeyEnabled
        // 5. SpeedControlState.setup() 读取 AppSettings.lastUsedSpeed
        // 6. AppLauncherViewModel.setup() 创建 Timer

        AppSettings.shared.bootstrapSideEffects()
        MenuBarController.shared.setup()
        HotkeyService.shared.setup()
        SpeedControlState.shared.setup()
        AppLauncherViewModel.shared.setup()
        AppLauncher.shared.setup()
        ProcessHistory.shared.setup()
        ProcessManagerProvider.shared.manager.setup()
        CLIManager.shared.setup()
        
        setupMenu()
        setupWindowDelegate()
        restoreWindowPosition()
        
        logInfo("OpenSwift launched successfully", log: .openswift)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
            logDebug("Application terminating, cleaning up...", log: .openswift)
            
            // 1. 先清理全局快捷键监听器（必须最先清理，因为它依赖辅助功能系统）
            // 如果不先清理，辅助功能系统可能会在应用退出时回调已释放的对象
            HotkeyService.shared.unregisterHotkeys()
            
            // 2. 清理 UI 相关资源（状态栏、窗口）
            MenuBarController.shared.shutdown()
            AppLauncherViewModel.shared.shutdown()
            
            // 3. 清理业务对象的通知观察器
            ProcessManagerProvider.shared.manager.shutdown()
            AppLauncher.shared.shutdown()
            
            // 4. 保存设置
            saveWindowPosition()
            AppSettings.shared.save()
            
            // 5. 最后清理注入进程和共享内存
            ProcessManagerProvider.shared.manager.cleanupAll()
        }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最小化到托盘时不退出
        return !AppSettings.shared.minimizeToTray
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    private func setupWindowDelegate() {
        mainWindow?.delegate = self
    }
    
    private func saveWindowPosition() {
        if let window = mainWindow {
            AppSettings.shared.windowPosition = window.frame.origin
            AppSettings.shared.windowSize = window.frame.size
        }
    }
    
    private func restoreWindowPosition() {
        if let position = AppSettings.shared.windowPosition,
           let window = mainWindow {
            window.setFrameOrigin(position)
        }
        
        if let size = AppSettings.shared.windowSize,
           let window = mainWindow {
            var frame = window.frame
            frame.size = size
            window.setFrame(frame, display: true)
        }
    }
    
    private func setupMenu() {
        let mainMenu = NSMenu()
        
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        
        appMenu.addItem(withTitle: "关于 OpenSwift", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "快捷键设置...", action: #selector(showHotkeySettings), keyEquivalent: "k")
        appMenu.addItem(withTitle: "设置...", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 OpenSwift", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "隐藏其他应用", 
                        action: #selector(NSApplication.hideOtherApplications(_:)), 
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 OpenSwift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        
        fileMenu.addItem(withTitle: "刷新进程列表", action: #selector(refreshProcesses), keyEquivalent: "r")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "清理已终止进程", action: #selector(cleanupInactiveProcesses), keyEquivalent: "")
        
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        
        let helpMenu = NSMenu(title: "帮助")
        helpMenuItem.submenu = helpMenu
        
        helpMenu.addItem(withTitle: "OpenSwift 帮助", action: #selector(showHelp), keyEquivalent: "?")
        
        NSApplication.shared.mainMenu = mainMenu
    }
    
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "关于 OpenSwift"
        alert.informativeText = """
            OpenSwift v1.0

            一个强大的进程速度控制工具。

            功能特点：
            • 多进程独立变速
            • 实时速度控制
            • 进程组管理
            • 共享内存通信
            • 全局快捷键支持
            • 菜单栏集成
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
    
    @objc private func showHotkeySettings() {
        let hotkeySettingsView = HotkeySettingsView(onDismiss: {
            NSApp.keyWindow?.close()
        })
        let hostingController = NSHostingController(rootView: hotkeySettingsView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "全局快捷键设置"
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func showSettings() {
        let settingsView = SettingsView(onDismiss: {
            NSApp.keyWindow?.close()
        })
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "设置"
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func refreshProcesses() {
        ProcessManagerProvider.shared.manager.refreshProcesses()
    }
    
    @objc private func cleanupInactiveProcesses() {
        AppLauncherViewModel.shared.cleanupTerminatedProcesses()
    }
    
    @objc private func showHelp() {
        if let url = URL(string: "https://github.com/your-repo/OpenSwift") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        
        if window == mainWindow {
            if AppSettings.shared.minimizeToTray {
                window.orderOut(nil)
            } else {
                mainWindow = nil
            }
        }
    }
    
    func windowDidMove(_ notification: Notification) {
        saveWindowPosition()
    }
    
    func windowDidResize(_ notification: Notification) {
        saveWindowPosition()
    }
}
