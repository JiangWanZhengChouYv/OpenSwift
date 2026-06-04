import Foundation
import AppKit

class MenuBarController: ObservableObject {
    static let shared = MenuBarController()
    
    @Published var isVisible: Bool = false
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    
    private let appSettings = AppSettings.shared
    
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
        if appSettings.showInMenuBar {
            showMenuBarItem()
        } else {
            hideMenuBarItem()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
