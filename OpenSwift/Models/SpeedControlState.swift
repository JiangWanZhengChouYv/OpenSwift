import Foundation
import Combine

// SpeedControlState 不再依赖全局 SpeedControlManager.shared。
// 当前选中进程会通过 currentController（一个与该进程关联的 SpeedControlManager）。
// 这样每个进程有独立的速度控制上下文。
class SpeedControlState: ObservableObject {

    static let shared = SpeedControlState()

    private let minSpeed: Double = 0.1
    private let maxSpeed: Double = 10.0
    private let defaultSpeed: Double = 1.0

    @Published var currentSpeed: Double = 1.0
    @Published var isEnabled: Bool = false
    @Published var selectedProcess: ProcessInfo?

    /// 当前 UI 选中进程对应的 SpeedControlManager。可能为 nil（没有进程被选中时）。
    weak var currentController: SpeedControlManager?

    private var lastError: String?
    private var isSetup: Bool = false

    private init() {}

    func setup() {
        guard !isSetup else { return }
        isSetup = true

        logInfo("SpeedControlState setup complete", log: .speed)
    }

    func setSpeed(_ speed: Double) {
        let clamped = min(max(speed, minSpeed), maxSpeed)
        currentSpeed = clamped

        if let controller = currentController {
            let result = controller.setSpeedRatio(Float(clamped))
            if !result {
                logError("Failed to set speed ratio", log: .speed)
            }
        } else {
            logDebug("setSpeed called without active process — ignoring shared memory write", log: .speed)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if let controller = currentController {
            _ = controller.setEnabled(enabled)
        }
    }

    func toggleEnabled() {
        setEnabled(!isEnabled)
    }

    func applyPresetSpeed(_ preset: Double) {
        setSpeed(preset)
    }

    func syncFromManager() {
        if let controller = currentController, let state = controller.syncFromSharedMemory() {
            currentSpeed = Double(state.speedRatio)
            isEnabled = state.isEnabled
        }
    }

    private func recordError(_ message: String) {
        logError("SpeedControl: \(message)", log: .speed)
        lastError = message
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
    
    func shutdown() {
        logInfo("SpeedControlState shutdown complete", log: .speed)
    }
}

enum SpeedCategory {
    case slow
    case normal
    case fast
}
