import Foundation
import Combine
import AppKit

class HotkeyService: ObservableObject {
    static let shared = HotkeyService()

    @Published var configurations: [HotkeyConfig] = []
    @Published var isEnabled: Bool = false
    @Published var hasAccessibilityPermission: Bool = false

    private var hotkeyManager: GlobalHotkeyManager?
    private let storage = HotkeyStorage.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadConfigurations()
        checkPermissions()
    }

    func loadConfigurations() {
        configurations = storage.load()
        print("[HotkeyService] Loaded \(configurations.count) configurations")
    }

    func saveConfigurations() {
        storage.save(configurations)
    }

    func registerHotkeys() {
        if hotkeyManager != nil {
            unregisterHotkeys()
        }

        let enabledConfigs = configurations.filter { $0.isEnabled }
        if enabledConfigs.isEmpty {
            print("[HotkeyService] No enabled hotkeys to register")
            return
        }

        hotkeyManager = GlobalHotkeyManager.shared
        hotkeyManager?.setActionHandler { [weak self] action in
            self?.executeAction(action)
        }

        hotkeyManager?.startMonitoring(with: enabledConfigs)
        isEnabled = true

        print("[HotkeyService] Registered \(enabledConfigs.count) hotkeys")
    }

    func unregisterHotkeys() {
        hotkeyManager?.stopMonitoring()
        hotkeyManager = nil
        isEnabled = false
        print("[HotkeyService] Unregistered all hotkeys")
    }

    func updateConfiguration(_ config: HotkeyConfig) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            saveConfigurations()

            if isEnabled {
                hotkeyManager?.updateConfigurations(configurations.filter { $0.isEnabled })
            }

            print("[HotkeyService] Updated configuration: \(config.action.displayName)")
        }
    }

    func updateEnabled(_ configId: UUID, isEnabled: Bool) {
        if let index = configurations.firstIndex(where: { $0.id == configId }) {
            configurations[index].isEnabled = isEnabled
            saveConfigurations()

            if self.isEnabled {
                hotkeyManager?.updateConfigurations(configurations.filter { $0.isEnabled })
            }

            print("[HotkeyService] \(isEnabled ? "Enabled" : "Disabled") hotkey: \(configurations[index].action.displayName)")
        }
    }

    func resetToDefaults() {
        storage.resetToDefaults()
        configurations = HotkeyConfig.defaultConfigurations()

        if isEnabled {
            hotkeyManager?.updateConfigurations(configurations.filter { $0.isEnabled })
        }

        print("[HotkeyService] Reset to default configurations")
    }

    func enableAll() {
        for i in 0..<configurations.count {
            configurations[i].isEnabled = true
        }
        saveConfigurations()

        if !isEnabled {
            registerHotkeys()
        } else {
            hotkeyManager?.updateConfigurations(configurations)
        }

        print("[HotkeyService] Enabled all hotkeys")
    }

    func disableAll() {
        for i in 0..<configurations.count {
            configurations[i].isEnabled = false
        }
        saveConfigurations()

        hotkeyManager?.updateConfigurations([])
        print("[HotkeyService] Disabled all hotkeys")
    }

    private func executeAction(_ action: HotkeyAction) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let speedControlState = SpeedControlState.shared

            switch action {
            case .increaseSpeed:
                let newSpeed = min(speedControlState.currentSpeed + 0.5, 10.0)
                speedControlState.setSpeed(newSpeed)
                print("[HotkeyService] Increase speed to \(newSpeed)")

            case .decreaseSpeed:
                let newSpeed = max(speedControlState.currentSpeed - 0.5, 0.1)
                speedControlState.setSpeed(newSpeed)
                print("[HotkeyService] Decrease speed to \(newSpeed)")

            case .toggleSpeed:
                speedControlState.toggleEnabled()
                print("[HotkeyService] Toggle speed control: \(speedControlState.isEnabled)")

            case .resetSpeed:
                speedControlState.setSpeed(1.0)
                print("[HotkeyService] Reset speed to 1.0")

            case .quickBoost:
                speedControlState.setSpeed(2.0)
                print("[HotkeyService] Quick boost to 2.0")

            case .quickSlow:
                speedControlState.setSpeed(0.5)
                print("[HotkeyService] Quick slow to 0.5")
            }

            self.showNotification(for: action, speed: speedControlState.currentSpeed, isEnabled: speedControlState.isEnabled)
        }
    }

    private func showNotification(for action: HotkeyAction, speed: Double, isEnabled: Bool) {
        guard let appDelegate = NSApplication.shared.delegate as? NSObject else { return }

        let notification = NSUserNotification()
        notification.title = "OpenSwift"
        notification.informativeText = "\(action.displayName): \(String(format: "%.1fx", speed))"
        notification.soundName = nil

        NSUserNotificationCenter.default.deliver(notification)
    }

    func checkPermissions() {
        hasAccessibilityPermission = GlobalHotkeyManager.shared.hasAccessibilityPermissions
    }

    func requestPermissions() {
        GlobalHotkeyManager.shared.requestAccessibilityPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkPermissions()
        }
    }

    func configuration(for action: HotkeyAction) -> HotkeyConfig? {
        return configurations.first { $0.action == action }
    }
}
