import Foundation
import Combine

class SpeedControlState: ObservableObject {
    
    static let shared = SpeedControlState()
    
    private let appSettings = AppSettings.shared
    private let speedControlManager = SpeedControlManager.shared
    
    private let minSpeed: Double = 0.1
    private let maxSpeed: Double = 10.0
    private let defaultSpeed: Double = 1.0
    
    @Published var currentSpeed: Double = 1.0 {
        didSet {
            if oldValue != currentSpeed {
                objectWillChange.send()
                saveState()
            }
        }
    }
    
    @Published var isEnabled: Bool = false {
        didSet {
            if oldValue != isEnabled {
                objectWillChange.send()
                saveState()
            }
        }
    }
    
    @Published var selectedProcess: ProcessInfo? {
        didSet {
            objectWillChange.send()
            if let process = selectedProcess {
                attachToProcess(process)
            } else {
                detachFromProcess()
            }
        }
    }
    
    private var lastError: String?
    
    private init() {
        loadSavedState()
    }
    
    private func loadSavedState() {
        let savedSpeed = appSettings.lastUsedSpeed
        if savedSpeed >= minSpeed && savedSpeed <= maxSpeed {
            currentSpeed = savedSpeed
        } else {
            currentSpeed = defaultSpeed
        }
    }
    
    private func saveState() {
        appSettings.lastUsedSpeed = currentSpeed
    }
    
    func setSpeed(_ speed: Double) {
        let clampedSpeed = min(max(speed, minSpeed), maxSpeed)
        currentSpeed = clampedSpeed
        
        if let _ = selectedProcess {
            let result = speedControlManager.setSpeedRatio(Float(clampedSpeed))
            if !result {
                logError("Failed to set speed ratio")
            }
        }
    }
    
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        
        if let _ = selectedProcess {
            let result = speedControlManager.setEnabled(enabled)
            if !result {
                logError("Failed to set enabled state")
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
        if let state = speedControlManager.syncFromSharedMemory() {
            currentSpeed = Double(state.speedRatio)
            isEnabled = state.isEnabled
        }
    }
    
    private func attachToProcess(_ process: ProcessInfo) {
        let success = speedControlManager.attachToProcess(pid: process.pid)
        if success {
            _ = speedControlManager.setSpeedRatioAndEnabled(
                ratio: Float(currentSpeed),
                enabled: isEnabled
            )
            clearError()
        } else {
            logError("Failed to attach to process: \(process.name)")
        }
    }
    
    private func detachFromProcess() {
        speedControlManager.detachFromProcess()
    }
    
    private func logError(_ message: String) {
        #if DEBUG
        print("[SpeedControlState] Error: \(message)")
        #endif
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
