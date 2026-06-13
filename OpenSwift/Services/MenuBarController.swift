import Foundation
import AppKit

// 关键修复: init 只做最轻量的操作
// MenuBarController 在 AppDelegate.applicationDidFinishLaunching 中通过 setup() 初始化
// 这确保在窗口显示之后才做任何 heavy 操作
class MenuBarController: ObservableObject {
    static let shared = MenuBarController()
    
    @Published var isVisible: Bool = false
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    
    // 延迟初始化: 不直接持有 AppSettings.shared (避免循环初始化)
    // 只在需要时通过方法访问
    private var isSetup: Bool = false
    
    private init() {
        // 什么也不做
    }
    
    func setup() {
        guard !isSetup else { return }
        isSetup = true
        
        let show = AppSettings.shared.showInMenuBar
        if show {
            showMenuBarItem()
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowInMenuBarChanged),
            name: .showInMenuBarChanged,
            object: nil
        )
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
    }
    
    func hideMenuBarItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        isVisible = false
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
        
        let showMainWindowItem = NSMenuItem(
            title: "显示主界面",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showMainWindowItem.target = self
        menu?.addItem(showMainWindowItem)
        
        self.statusItem?.menu = menu
    }
    
    @objc private func showMainWindow() {
        NSApplication.shared.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func handleShowInMenuBarChanged() {
        // 延迟获取，避免在初始化阶段访问
        DispatchQueue.main.async { [weak self] in
            let shouldShow = AppSettings.shared.showInMenuBar
            if shouldShow {
                self?.showMenuBarItem()
            } else {
                self?.hideMenuBarItem()
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
