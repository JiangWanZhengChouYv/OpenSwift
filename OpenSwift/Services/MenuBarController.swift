import Foundation
import AppKit
import SwiftUI
import Combine

class MenuBarController: ObservableObject {
    static let shared = MenuBarController()
    
    @Published var isVisible: Bool = false
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    
    private let appSettings = AppSettings.shared
    private let speedControlState = SpeedControlState.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupObservers()
    }
    
    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowInMenuBarChanged),
            name: .showInMenuBarChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowShouldClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }
    
    func setup() {
        if appSettings.showInMenuBar {
            showMenuBarItem()
        } else {
            hideMenuBarItem()
        }
    }
    
    func showMenuBarItem() {
        guard statusItem == nil else { return }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = createMenuBarIcon()
            button.image?.isTemplate = true
            button.toolTip = "OpenSwift"
        }
        
        createMenu()
        isVisible = true
        
        #if DEBUG
        print("[MenuBarController] Menu bar item shown")
        #endif
    }
    
    func hideMenuBarItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        isVisible = false
        
        #if DEBUG
        print("[MenuBarController] Menu bar item hidden")
        #endif
    }
    
    private func createMenuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        
        let speedometerPath = NSBezierPath()
        speedometerPath.appendArc(
            withCenter: NSPoint(x: 9, y: 9),
            radius: 6,
            startAngle: 210,
            endAngle: 330,
            clockwise: false
        )
        speedometerPath.lineWidth = 2
        NSColor.black.setStroke()
        speedometerPath.stroke()
        
        let needlePath = NSBezierPath()
        needlePath.move(to: NSPoint(x: 9, y: 9))
        needlePath.line(to: NSPoint(x: 12, y: 11))
        needlePath.lineWidth = 1.5
        needlePath.stroke()
        
        image.unlockFocus()
        image.isTemplate = true
        
        return image
    }
    
    private func createMenu() {
        menu = NSMenu()
        
        let titleItem = NSMenuItem(title: "OpenSwift", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu?.addItem(titleItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        let speedMenu = NSMenu()
        
        let speedPresets: [(String, Double)] = [
            ("0.5x 慢速", 0.5),
            ("1.0x 正常", 1.0),
            ("1.5x 加速", 1.5),
            ("2.0x 快速", 2.0),
            ("5.0x 超速", 5.0)
        ]
        
        for (title, speed) in speedPresets {
            let item = NSMenuItem(title: title, action: #selector(setSpeedPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = speedControlState.currentSpeed == speed ? .on : .off
            speedMenu.addItem(item)
        }
        
        let speedMenuItem = NSMenuItem(title: "速度设置", action: nil, keyEquivalent: "")
        speedMenuItem.submenu = speedMenu
        menu?.addItem(speedMenuItem)
        
        let enableItem = NSMenuItem(
            title: speedControlState.isEnabled ? "禁用加速" : "启用加速",
            action: #selector(toggleSpeedEnabled),
            keyEquivalent: ""
        )
        enableItem.target = self
        enableItem.state = speedControlState.isEnabled ? .on : .off
        menu?.addItem(enableItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        let injectedCount = ProcessManagerProvider.shared.manager.injectedProcesses.count
        let statusItem = NSMenuItem(
            title: "已注入进程: \(injectedCount)",
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu?.addItem(statusItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        let showWindowItem = NSMenuItem(
            title: "显示主窗口",
            action: #selector(showMainWindow),
            keyEquivalent: "o"
        )
        showWindowItem.target = self
        menu?.addItem(showWindowItem)
        
        let settingsItem = NSMenuItem(
            title: "设置...",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu?.addItem(settingsItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(
            title: "退出 OpenSwift",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu?.addItem(quitItem)
        
        self.statusItem?.menu = menu
    }
    
    @objc private func setSpeedPreset(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? Double else { return }
        speedControlState.setSpeed(speed)
        updateMenuState()
    }
    
    @objc private func toggleSpeedEnabled() {
        speedControlState.toggleEnabled()
        updateMenuState()
    }
    
    @objc private func showMainWindow() {
        showMainApplicationWindow()
    }
    
    @objc private func showSettings() {
        DispatchQueue.main.async {
            let settingsView = SettingsView(onDismiss: {
                NSApp.keyWindow?.close()
            })
            let hostingController = NSHostingController(rootView: settingsView)
            
            if let window = NSApplication.shared.windows.first {
                window.contentViewController = hostingController
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func showMainApplicationWindow() {
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    private func updateMenuState() {
        createMenu()
        
        #if DEBUG
        print("[MenuBarController] Menu state updated")
        #endif
    }
    
    @objc private func handleShowInMenuBarChanged() {
        if appSettings.showInMenuBar {
            showMenuBarItem()
        } else {
            hideMenuBarItem()
        }
    }
    
    @objc private func handleWindowShouldClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        
        if window == NSApplication.shared.windows.first && appSettings.minimizeToTray {
            window.orderOut(nil)
            NotificationCenter.default.post(name: .windowMinimizedToTray, object: nil)
        }
    }
    
    func updateStatus() {
        DispatchQueue.main.async {
            self.createMenu()
            
            #if DEBUG
            print("[MenuBarController] Menu state updated")
            #endif
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
