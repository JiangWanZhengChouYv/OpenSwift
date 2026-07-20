import Foundation
import Combine
import AppKit

// 关键修复: init 只做最轻量的操作
// HotkeyService 在 AppDelegate.applicationDidFinishLaunching 中通过 setup 延迟初始化
class HotkeyService: ObservableObject {
    static let shared = HotkeyService()
    
    @Published var configurations: [HotkeyConfig] = []
    @Published var isEnabled: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    
    private var hotkeyManager: GlobalHotkeyManager?
    private var isSetup: Bool = false
    private let storage = HotkeyStorage.shared
    
    private init() {
        // 什么也不做
        // 所有 heavy 操作延迟到 setup() 中
    }
    
    // 由 AppDelegate 在窗口显示后调用
    func setup() {
        guard !isSetup else { return }
        isSetup = true
        
        loadConfigurations()
        checkPermissions()
        
        if AppSettings.shared.hotkeyEnabled {
            registerHotkeys()
        }
    }
    
    func loadConfigurations() {
        configurations = storage.load()
        logDebug("Loaded \(configurations.count) configurations", log: .hotkey)
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
            logDebug("No enabled hotkeys to register", log: .hotkey)
            return
        }
        
        hotkeyManager = GlobalHotkeyManager.shared
        hotkeyManager?.setActionHandler { [weak self] action in
            self?.executeAction(action)
        }
        
        hotkeyManager?.startMonitoring(with: enabledConfigs)
        isEnabled = true
        
        logInfo("Registered \(enabledConfigs.count) hotkeys", log: .hotkey)
    }
    
    func unregisterHotkeys() {
        hotkeyManager?.stopMonitoring()
        hotkeyManager = nil
        isEnabled = false
        logInfo("Unregistered all hotkeys", log: .hotkey)
    }
    
    func updateConfiguration(_ config: HotkeyConfig) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            saveConfigurations()
            
            if isEnabled {
                hotkeyManager?.updateConfigurations(configurations.filter { $0.isEnabled })
            }
            
            logDebug("Updated configuration: \(config.action.displayName)", log: .hotkey)
        }
    }
    
    func updateEnabled(_ configId: UUID, isEnabled: Bool) {
        if let index = configurations.firstIndex(where: { $0.id == configId }) {
            configurations[index].isEnabled = isEnabled
            saveConfigurations()
            
            if self.isEnabled {
                hotkeyManager?.updateConfigurations(configurations.filter { $0.isEnabled })
            }
            
            let actionName = configurations[index].action.displayName
            let status = isEnabled ? "Enabled" : "Disabled"
            logDebug("\(status) hotkey: \(actionName)", log: .hotkey)
        }
    }
    
    func resetToDefaults() {
        storage.resetToDefaults()
        configurations = HotkeyConfig.defaultConfigurations()
        
        if isEnabled {
            hotkeyManager?.updateConfigurations(configurations.filter { $0.isEnabled })
        }
        
        logInfo("Reset to default configurations", log: .hotkey)
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
        
        logInfo("Enabled all hotkeys", log: .hotkey)
    }
    
    func disableAll() {
        for i in 0..<configurations.count {
            configurations[i].isEnabled = false
        }
        saveConfigurations()
        
        hotkeyManager?.updateConfigurations([])
        logInfo("Disabled all hotkeys", log: .hotkey)
    }
    
    private func executeAction(_ action: HotkeyAction) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let speedControlState = SpeedControlState.shared
            
            switch action {
            case .increaseSpeed:
                let newSpeed = min(speedControlState.currentSpeed + 0.5, 10.0)
                speedControlState.setSpeed(newSpeed)
                logDebug("Increase speed to \(newSpeed)", log: .hotkey)
                
            case .decreaseSpeed:
                let newSpeed = max(speedControlState.currentSpeed - 0.5, 0.1)
                speedControlState.setSpeed(newSpeed)
                logDebug("Decrease speed to \(newSpeed)", log: .hotkey)
                
            case .toggleSpeed:
                speedControlState.toggleEnabled()
                logDebug("Toggle speed control: \(speedControlState.isEnabled)", log: .hotkey)
                
            case .resetSpeed:
                speedControlState.setSpeed(1.0)
                logDebug("Reset speed to 1.0", log: .hotkey)
                
            case .quickBoost:
                speedControlState.setSpeed(2.0)
                logDebug("Quick boost to 2.0", log: .hotkey)
                
            case .quickSlow:
                speedControlState.setSpeed(0.5)
                logDebug("Quick slow to 0.5", log: .hotkey)
            }
            
            self.showNotification(
                for: action,
                speed: speedControlState.currentSpeed,
                isEnabled: speedControlState.isEnabled
            )
        }
    }
    
    private func showNotification(for action: HotkeyAction, speed: Double, isEnabled: Bool) {
        guard let _ = NSApplication.shared.delegate as? NSObject else { return }
        
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
