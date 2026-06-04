import AppKit
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private let appSettings = AppSettings.shared
    private let menuBarController = MenuBarController.shared
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        menuBarController.setup()
        
        if appSettings.hotkeyEnabled {
            HotkeyService.shared.registerHotkeys()
        }
        
        let contentView = ContentView()
        
        mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow?.center()
        mainWindow?.title = "OpenSwift"
        mainWindow?.contentView = NSHostingView(rootView: contentView)
        mainWindow?.makeKeyAndOrderFront(nil)
        
        restoreWindowPosition()
        setupMenu()
        setupWindowDelegate()
        
        print("[AppDelegate] OpenSwift launched successfully")
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        print("[AppDelegate] Application terminating, cleaning up...")
        
        saveWindowPosition()
        
        ProcessManagerProvider.shared.manager.cleanupAll()
        HotkeyService.shared.unregisterHotkeys()
        appSettings.save()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !appSettings.minimizeToTray
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    private func setupWindowDelegate() {
        mainWindow?.delegate = self
    }
    
    private func saveWindowPosition() {
        if let frame = mainWindow?.frame {
            appSettings.windowPosition = frame.origin
            appSettings.windowSize = frame.size
        }
    }
    
    private func restoreWindowPosition() {
        if let position = appSettings.windowPosition {
            mainWindow?.setFrameOrigin(position)
        }
        
        if let size = appSettings.windowSize {
            var frame = mainWindow?.frame ?? NSRect.zero
            frame.size = size
            mainWindow?.setFrame(frame, display: true)
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
        appMenu.addItem(withTitle: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "")
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
        alert.informativeText = "OpenSwift v1.0\n\n一个强大的进程速度控制工具。\n\n功能特点：\n• 多进程独立变速\n• 实时速度控制\n• 进程组管理\n• 共享内存通信\n• 全局快捷键支持\n• 菜单栏集成"
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
        let manager = ProcessManagerProvider.shared.manager
        let inactiveProcesses = manager.injectedProcesses.filter { !$0.isActive }
        for inactive in inactiveProcesses {
            manager.removeInjectedProcess(inactive)
        }
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
        
        if window == mainWindow && appSettings.minimizeToTray {
            window.orderOut(nil)
        }
    }
    
    func windowDidMove(_ notification: Notification) {
        saveWindowPosition()
    }
    
    func windowDidResize(_ notification: Notification) {
        saveWindowPosition()
    }
}
