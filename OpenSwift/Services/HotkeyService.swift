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
    private var pollingTimer: Timer?
    private var appNapActivity: NSObjectProtocol?
    private let storage = HotkeyStorage.shared
    
    private init() {
        // 什么也不做
        // 所有 heavy 操作延迟到 setup() 中
    }
    
    // 由 AppDelegate 在窗口显示后调用
    func setup() {
        guard !isSetup else { return }
        isSetup = true
        
        startAppNapProtection()
        loadConfigurations()
        checkPermissions()
        
        // 用户可能在系统设置里授予/撤销辅助功能权限后回到应用。
        // 每次应用激活时重查一次，授权后自动补注册快捷键。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        if AppSettings.shared.hotkeyEnabled {
            registerHotkeys()
        }
    }
    
    @objc private func handleApplicationDidBecomeActive() {
        hasAccessibilityPermission = GlobalHotkeyManager.shared.hasAccessibilityPermissions
        // 授权刚刚生效 + 未注册 + 用户开启了快捷键 → 补注册。
        if hasAccessibilityPermission && !isEnabled && AppSettings.shared.hotkeyEnabled {
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
        // 授权生效后自动注册快捷键。
        if hasAccessibilityPermission && !isEnabled && AppSettings.shared.hotkeyEnabled {
            registerHotkeys()
        }
        // 仍待授权则启动轮询，授权异步生效后自动清除「待授权」。
        if hasAccessibilityPermission {
            stopPermissionPolling()
        } else {
            startPermissionPolling()
        }
    }

    /// 手动触发一次权限检查（供「重新检查」按钮）。
    func refreshPermissions() {
        checkPermissions()
    }

    /// 待授权时每 1 秒轮询一次，直到授权生效或超时（最长 120 秒）。
    private func startPermissionPolling() {
        guard pollingTimer == nil else { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let trusted = GlobalHotkeyManager.shared.hasAccessibilityPermissions
            self.hasAccessibilityPermission = trusted
            if trusted {
                timer.invalidate()
                self.pollingTimer = nil
                if !self.isEnabled && AppSettings.shared.hotkeyEnabled {
                    self.registerHotkeys()
                }
            }
        }
    }

    private func stopPermissionPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
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
    
    func shutdown() {
        stopPermissionPolling()
        NotificationCenter.default.removeObserver(self)
        stopAppNapProtection()
        unregisterHotkeys()
        logInfo("HotkeyService shutdown complete", log: .hotkey)
    }

    // MARK: - App Nap 抑制

    /// 持有 `.userInitiated` 活动，避免后台时被 App Nap 节流主运行循环，
    /// 否则 Carbon 热键事件会有 ~1s 的投递延迟。
    private func startAppNapProtection() {
        guard appNapActivity == nil else { return }
        appNapActivity = Foundation.ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "保持全局快捷键实时响应"
        )
    }

    private func stopAppNapProtection() {
        if let activity = appNapActivity {
            Foundation.ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }
}
