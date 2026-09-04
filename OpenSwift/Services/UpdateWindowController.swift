import AppKit
import SwiftUI

/// 承载图形化更新界面的浮动面板窗口。
final class UpdateWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: UpdatePanelView())
            let panel = NSWindow(contentViewController: hosting)
            panel.title = "检查更新"
            panel.styleMask = [.titled, .closable]
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            panel.setContentSize(NSSize(width: 380, height: 340))
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        UpdateManager.shared.handleWindowClosed()
    }
}
