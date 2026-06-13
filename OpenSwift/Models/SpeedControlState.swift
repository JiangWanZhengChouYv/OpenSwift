import Foundation
import Combine

// 关键修复: init 不引用其他 singleton
// SpeedControlState 由 ContentView 在 UI 加载时触发
// 但由于它是 singleton，第一次访问时会触发 init
// 所以这里的 init 必须绝对轻量，不能引用 AppSettings.shared 或 SpeedControlManager.shared
class SpeedControlState: ObservableObject {
    
    static let shared = SpeedControlState()
    
    private let minSpeed: Double = 0.1
    private let maxSpeed: Double = 10.0
    private let defaultSpeed: Double = 1.0
    
    @Published var currentSpeed: Double = 1.0
    @Published var isEnabled: Bool = false
    @Published var selectedProcess: ProcessInfo?
    
    private var lastError: String?
    private var isSetup: Bool = false
    
    private init() {
        // 什么也不做
        // 所有初始化延迟到 setup()
    }
    
    // 由 AppDelegate 在窗口显示后调用
    func setup() {
        guard !isSetup else { return }
        isSetup = true
        
        // 从设置加载速度值
        let savedSpeed = AppSettings.shared.lastUsedSpeed
        if savedSpeed >= minSpeed && savedSpeed <= maxSpeed {
            currentSpeed = savedSpeed
        } else {
            currentSpeed = defaultSpeed
        }
        
        print("[SpeedControlState] Setup complete, currentSpeed: \(currentSpeed)")
    }
    
    func setSpeed(_ speed: Double) {
        let clampedSpeed = min(max(speed, minSpeed), maxSpeed)
        currentSpeed = clampedSpeed
        
        if isSetup {
            AppSettings.shared.lastUsedSpeed = clampedSpeed
            
            if let _ = selectedProcess {
                let result = SpeedControlManager.shared.setSpeedRatio(Float(clampedSpeed))
                if !result {
                    logError("Failed to set speed ratio")
                }
            }
        }
    }
    
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        
        if isSetup {
            if let _ = selectedProcess {
                let result = SpeedControlManager.shared.setEnabled(enabled)
                if !result {
                    logError("Failed to set enabled state")
                }
            }
        }
    }
    
    func toggleEnabled() {
        setEnabled(!isEnabled)
    }
    
    func applyPresetSpeed(_ preset: Double) {
        setSpeed(preset)
    }
    
    func syncFromManager() {
        if isSetup {
            if let state = SpeedControlManager.shared.syncFromSharedMemory() {
                currentSpeed = Double(state.speedRatio)
                isEnabled = state.isEnabled
            }
        }
    }
    
    private func logError(_ message: String) {
        print("[SpeedControlState] Error: \(message)")
        lastError = message
    }
    
    private func clearError() {
        lastError = nil
    }
    
    var hasError: Bool {
        return lastError != nil
    }
    
    var errorMessage: String? {
        return lastError
    }
    
    var speedDescription: String {
        if currentSpeed < 1.0 {
            let factor = 1.0 / currentSpeed
            return String(format: "%.1fx 慢速 (%.1fx)", currentSpeed, factor)
        } else if currentSpeed > 1.0 {
            return String(format: "%.1fx 加速", currentSpeed)
        } else {
            return "正常速度"
        }
    }
    
    var speedCategory: SpeedCategory {
        if currentSpeed < 0.9 {
            return .slow
        } else if currentSpeed > 1.1 {
            return .fast
        } else {
            return .normal
        }
    }
}

enum SpeedCategory {
    case slow
    case normal
    case fast
}
