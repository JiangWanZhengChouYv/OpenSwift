import Foundation
import AppKit

extension ProcessManager {
    func showInContextMenu(for process: ProcessInfo, at location: NSPoint, in view: NSView) {
        createContextMenu(for: process).popUp(positioning: nil, at: location, in: view)
    }

    func createContextMenu(for process: ProcessInfo) -> NSMenu {
        let menu = NSMenu()
        if isProcessInjected(process) {
            addInjectedProcessMenuItems(to: menu, for: process)
        } else {
            addInjectMenuItem(to: menu, for: process)
        }
        menu.addItem(NSMenuItem.separator())
        addCommonMenuItems(to: menu, for: process)
        return menu
    }

    private func addInjectedProcessMenuItems(to menu: NSMenu, for process: ProcessInfo) {
        menu.addItem(menuItem(title: "卸载 SpeedPatch", action: #selector(ejectSpeedPatch(_:)), object: process))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "启用加速", action: #selector(enableSpeedControl(_:)), object: process))
        menu.addItem(menuItem(title: "禁用加速", action: #selector(disableSpeedControl(_:)), object: process))
        menu.addItem(NSMenuItem.separator())
        addSpeedSubmenu(to: menu, for: process)
    }

    private func addInjectMenuItem(to menu: NSMenu, for process: ProcessInfo) {
        menu.addItem(menuItem(title: "注入 SpeedPatch", action: #selector(injectSpeedPatch(_:)), object: process))
    }

    private func addSpeedSubmenu(to menu: NSMenu, for process: ProcessInfo) {
        let speedSubmenu = NSMenu()
        [(0.5, "0.5x (慢速)"), (1.0, "1.0x (正常)"), (1.5, "1.5x (加速)"), (2.0, "2.0x (快速)"), (5.0, "5.0x (超速)")]
            .forEach { speedSubmenu.addItem(createSpeedMenuItem(title: $1, speed: $0, process: process)) }
        let speedMenuItem = NSMenuItem(title: "快速设置速度", action: nil, keyEquivalent: "")
        speedMenuItem.submenu = speedSubmenu
        menu.addItem(speedMenuItem)
    }

    private func addCommonMenuItems(to menu: NSMenu, for process: ProcessInfo) {
        menu.addItem(menuItem(title: "复制进程信息", action: #selector(copyProcessInfo(_:)), object: process))
        if let path = process.path {
            menu.addItem(menuItem(title: "在 Finder 中显示", action: #selector(showInFinder(_:)), object: path))
        }
    }

    private func menuItem(title: String, action: Selector, object: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = object; item.target = self; return item
    }

    private func createSpeedMenuItem(title: String, speed: Double, process: ProcessInfo) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(setQuickSpeed(_:)), keyEquivalent: "")
        item.representedObject = (process, speed); item.target = self; return item
    }

    @objc private func injectSpeedPatch(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ProcessInfo { injectSpeedControl(into: p) }
    }
    
    @objc private func ejectSpeedPatch(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ProcessInfo { removeInjectedProcess(p) }
    }
    
    @objc private func enableSpeedControl(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ProcessInfo {
            updateInjectedProcess(pid: p.pid, isEnabled: true)
        }
    }
    
    @objc private func disableSpeedControl(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ProcessInfo {
            updateInjectedProcess(pid: p.pid, isEnabled: false)
        }
    }
    
    @objc private func setQuickSpeed(_ sender: NSMenuItem) {
        if let (p, s) = sender.representedObject as? (ProcessInfo, Double) {
            updateInjectedProcess(pid: p.pid, speedRatio: s)
        }
    }

    @objc private func copyProcessInfo(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ProcessInfo else { return }
        var info = "进程名称: \(process.name)\nPID: \(process.pid)\n"
        if let id = process.bundleIdentifier { info += "Bundle ID: \(id)\n" }
        if let path = process.path { info += "路径: \(path)" }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info, forType: .string)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}
