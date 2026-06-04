import Foundation
import AppKit
import Carbon

class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var eventMonitor: Any?
    private var configurations: [HotkeyConfig] = []
    private var actionHandler: ((HotkeyAction) -> Void)?

    private init() {
        // Default empty initializer for singleton
    }

    func setActionHandler(_ handler: @escaping (HotkeyAction) -> Void) {
        self.actionHandler = handler
    }

    func startMonitoring(with configurations: [HotkeyConfig]) {
        self.configurations = configurations
        stopMonitoring()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        if let monitor = eventMonitor {
            print("[GlobalHotkeyManager] Started global monitor with \(configurations.count) configurations")
        }
    }

    func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
            print("[GlobalHotkeyManager] Stopped global monitor")
        }
    }

    func updateConfigurations(_ configurations: [HotkeyConfig]) {
        self.configurations = configurations
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags

        for config in configurations {
            guard config.isEnabled else { continue }

            let hasCommand = flags.contains(.command)
            let hasOption = flags.contains(.option)
            let hasControl = flags.contains(.control)
            let hasShift = flags.contains(.shift)

            let eventModifiers = HotkeyConfig.modifiersToFlags(
                hasCommand: hasCommand,
                hasOption: hasOption,
                hasControl: hasControl,
                hasShift: hasShift
            )

            if keyCode == config.keyCode && eventModifiers == config.modifiers {
                print("[GlobalHotkeyManager] Hotkey matched: \(config.action.displayName)")
                actionHandler?(config.action)
                return
            }
        }
    }

    var hasAccessibilityPermissions: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        print("[GlobalHotkeyManager] Accessibility permissions: \(isTrusted)")
    }

    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        print("[GlobalHotkeyManager] Requested accessibility permissions")
    }
}
