import Foundation
import Combine
import AppKit

// 关键修复:
// 1. 每个 LaunchedProcess 持有自己的 SpeedControlManager 实例（不再使用全局单例）
//    这样可以同时支持多个进程的独立加速/减速上下文。
// 2. 所有对 launchedProcesses 数组的读写都通过 stateQueue 串行化，
//    避免 SwiftUI 在主线程刷新时与后台计时器刷新发生数据竞争。
// 3. Timer 在主线程创建，闭包中使用 [weak self]。
// swiftlint:disable type_body_length
class AppLauncherViewModel: ObservableObject {
    static let shared = AppLauncherViewModel()

    @Published var launchedProcesses: [LaunchedProcess] = []
    @Published var selectedLaunchedProcess: LaunchedProcess?
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var showSuccess = false
    @Published var successMessage = ""

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var detectTimer: Timer?
    private var isSetup: Bool = false
    let stateQueue = DispatchQueue(label: "com.openswift.applaunchervm.state", qos: .userInitiated)

    private init() {
        // 什么也不做
        // 所有 heavy 操作延迟到 setup()
    }

    // 由 AppDelegate 在窗口显示后调用
    func setup() {
        guard !isSetup else { return }
        isSetup = true

        refreshLaunchedProcesses()
        detectInjectedProcesses()

        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.refreshLaunchedProcesses()
            }
            self?.detectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.detectInjectedProcesses()
            }
        }

        logInfo("AppLauncherViewModel setup complete", log: .launcher)
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        detectTimer?.invalidate()
        detectTimer = nil
    }

    func refreshLaunchedProcesses() {
        let latest = AppLauncher.shared.getLaunchedProcesses()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let existing = self.launchedProcesses
            
            let latestPIDs = Set(latest.map(\.pid))

            let merged = latest.map { newProcess -> LaunchedProcess in
                if let existingProcess = existing.first(where: { $0.pid == newProcess.pid }) {
                    var updated = newProcess
                    updated.currentSpeed = existingProcess.currentSpeed
                    updated.isSpeedControlEnabled = existingProcess.isSpeedControlEnabled
                    updated.isSharedMemoryConnected = existingProcess.isSharedMemoryConnected
                    updated.speedController = existingProcess.speedController
                    updated.launchMethod = existingProcess.launchMethod
                    updated.isWallclockHooked = existingProcess.isWallclockHooked
                    updated.isRecursiveInjection = existingProcess.isRecursiveInjection
                    return updated
                }
                return newProcess
            }

            let staticProcesses = existing.filter {
                $0.launchMethod == .staticInjected && !latestPIDs.contains($0.pid)
            }

            let finalResult = merged + staticProcesses
            self.launchedProcesses = finalResult

            if let selected = self.selectedLaunchedProcess {
                if let updatedSelected = finalResult.first(where: { $0.pid == selected.pid }) {
                    self.selectedLaunchedProcess = updatedSelected
                } else {
                    self.selectedLaunchedProcess = nil
                    SpeedControlState.shared.currentController = nil
                }
            }
        }
    }

    private func detectInjectedProcesses() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let detected = DetectInjectedProcessesService.shared.scanAllUserProcesses()
            DispatchQueue.main.async {
                self.mergeDetectedProcesses(detected)
            }
        }
    }

    private func mergeDetectedProcesses(_ detected: [pid_t: InjectedProcessMeta]) {
        let existing = self.launchedProcesses
        var result: [LaunchedProcess] = []

        for old in existing {
            var updated = old
            if let meta = detected[old.pid] {
                updated.isRunning = true
                updated.isSharedMemoryConnected = true
                updated.currentSpeed = Double(meta.speedRatio)
                updated.isSpeedControlEnabled = meta.isActive
                result.append(updated)
            } else {
                if old.launchMethod == .staticInjected {
                    updated.isRunning = false
                }
                result.append(updated)
            }
        }

        let existingPIDs = Set(existing.map(\.pid))
        for (pid, meta) in detected where !existingPIDs.contains(pid) {
            let newProcess = LaunchedProcess(
                pid: pid,
                appURL: meta.appURL,
                appName: meta.appName,
                launchedAt: Date(),
                isRunning: true,
                currentSpeed: Double(meta.speedRatio),
                isSpeedControlEnabled: meta.isActive,
                isSharedMemoryConnected: true,
                launchMethod: .staticInjected,
                isWallclockHooked: true
            )
            result.append(newProcess)
        }

        self.launchedProcesses = result

        if let selected = self.selectedLaunchedProcess {
            if let updatedSelected = result.first(where: { $0.id == selected.id }) {
                self.selectedLaunchedProcess = updatedSelected
            } else if let updatedByPID = result.first(where: { $0.pid == selected.pid }) {
                self.selectedLaunchedProcess = updatedByPID
            }
        }
    }

    func selectProcess(_ process: LaunchedProcess?) {
        selectedLaunchedProcess = process
        if let process = process {
            updateProcessState(for: process.id) { current in
                var mutable = current
                let success = mutable.speedController.attachToProcess(pid: process.pid)
                mutable.isSharedMemoryConnected = success
                if success {
                    _ = mutable.speedController.setHookWallclock(AppSettings.shared.hookWallclockDefault)
                    mutable.isWallclockHooked = AppSettings.shared.hookWallclockDefault
                    mutable.isRecursiveInjection = false
                }
                if let state = mutable.speedController.syncFromSharedMemory() {
                    mutable.currentSpeed = Double(state.speedRatio)
                    mutable.isSpeedControlEnabled = state.isEnabled
                    mutable.isWallclockHooked = state.isWallclockHooked
                    mutable.isRecursiveInjection = state.isRecursiveInjection
                }
                return mutable
            }
            SpeedControlState.shared.currentController = fetchProcess(for: process.id)?.speedController
        } else {
            SpeedControlState.shared.currentController = nil
        }
    }

    func updateSpeed(_ speed: Double, for process: LaunchedProcess) {
        updateProcessState(for: process.id) { current in
            var mutable = current
            if !mutable.speedController.isConnected {
                let success = mutable.speedController.attachToProcess(pid: process.pid)
                if !success {
                    logError("Failed to attach to process \(process.pid) before setting speed", log: .launcher)
                    return nil
                }
            }
            _ = mutable.speedController.setSpeedRatio(Float(speed))
            mutable.currentSpeed = speed
            return mutable
        }
    }

    /// 设速的同时启用该进程的速度控制（写 is_active=1），供插件桥 `openSwift.setSpeed` 调用。
    @discardableResult
    func setSpeedAndEnabled(_ speed: Double, for process: LaunchedProcess) -> Bool {
        return updateProcessState(for: process.id) { current in
            var mutable = current
            if !mutable.speedController.isConnected {
                let success = mutable.speedController.attachToProcess(pid: process.pid)
                if !success {
                    logError("Failed to attach to process \(process.pid) before setting speed", log: .launcher)
                    return nil
                }
            }
            // 启动加速必须以挂钟时间 hook 为前提，保证调整倍率真正生效。
            _ = mutable.speedController.setHookWallclock(true)
            _ = mutable.speedController.setEnabled(true)
            _ = mutable.speedController.setSpeedRatio(Float(speed))
            mutable.isSpeedControlEnabled = true
            mutable.currentSpeed = speed
            return mutable
        }
    }

    func toggleSpeedControl(_ enabled: Bool, for process: LaunchedProcess) {
        updateProcessState(for: process.id) { current in
            var mutable = current
            if !mutable.speedController.isConnected {
                let success = mutable.speedController.attachToProcess(pid: process.pid)
                if !success {
                    logError("Failed to attach to process \(process.pid) before toggling speed control", log: .launcher)
                    return nil
                }
            }
            _ = mutable.speedController.setEnabled(enabled)
            mutable.isSpeedControlEnabled = enabled
            return mutable
        }
    }

    func disconnectFromProcess() {
        if let process = selectedLaunchedProcess {
            updateProcessState(for: process.id) { current in
                var mutable = current
                mutable.speedController.detachFromProcess()
                mutable.isSharedMemoryConnected = false
                return mutable
            }
        }
        selectedLaunchedProcess = nil
        SpeedControlState.shared.currentController = nil
    }

    func launchApp(at url: URL) {
        let result = AppLauncher.shared.launchApp(at: url)

        switch result {
        case .success(let process):
            DispatchQueue.main.async { [weak self] in
                self?.successMessage = "成功启动 \(process.appName)"
                self?.showSuccess = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.showSuccess = false
                }

                self?.refreshLaunchedProcesses()
            }
        case .failure(let error):
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error.localizedDescription
                self?.showError = true
            }
        }
    }
    
    func launchExecutable(at url: URL) {
        let result = AppLauncher.shared.launchExecutable(at: url)

        switch result {
        case .success(let process):
            DispatchQueue.main.async { [weak self] in
                self?.successMessage = "成功启动 \(process.appName)"
                self?.showSuccess = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.showSuccess = false
                }

                self?.refreshLaunchedProcesses()
            }
        case .failure(let error):
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error.localizedDescription
                self?.showError = true
            }
        }
    }

    func terminateProcess(_ process: LaunchedProcess) {
        disconnectFromProcess()
        process.speedController.detachAndCleanup()
        let result = AppLauncher.shared.terminateProcess(process)

        switch result {
        case .success:
            DispatchQueue.main.async { [weak self] in
                self?.successMessage = "已终止 \(process.appName)"
                self?.showSuccess = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.showSuccess = false
                }

                self?.refreshLaunchedProcesses()
            }
        case .failure(let error):
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error.localizedDescription
                self?.showError = true
            }
        }
    }

    func forceTerminateProcess(_ process: LaunchedProcess) {
        disconnectFromProcess()
        process.speedController.detachAndCleanup()
        let result = AppLauncher.shared.forceTerminateProcess(process)

        switch result {
        case .success:
            DispatchQueue.main.async { [weak self] in
                self?.successMessage = "已强制终止 \(process.appName)"
                self?.showSuccess = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.showSuccess = false
                }

                self?.refreshLaunchedProcesses()
            }
        case .failure(let error):
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error.localizedDescription
                self?.showError = true
            }
        }
    }

    func removeProcess(_ process: LaunchedProcess) {
        process.speedController.detachAndCleanup()
        AppLauncher.shared.removeProcess(process)
        refreshLaunchedProcesses()
    }

    func cleanupTerminatedProcesses() {
        for process in launchedProcesses where !process.isRunning {
            if selectedLaunchedProcess?.id == process.id {
                disconnectFromProcess()
            }
            process.speedController.detachAndCleanup()
        }
        AppLauncher.shared.clearTerminatedProcesses()
        refreshLaunchedProcesses()
    }

    // MARK: - Private helpers (thread-safe process state mutation)

    private func fetchProcess(for id: UUID) -> LaunchedProcess? {
        return stateQueue.sync { launchedProcesses.first { $0.id == id } }
    }

    @discardableResult
    func updateProcessState(for id: UUID, mutator: (LaunchedProcess) -> LaunchedProcess?) -> Bool {
        var snapshot: [LaunchedProcess] = stateQueue.sync { launchedProcesses }
        guard let index = snapshot.firstIndex(where: { $0.id == id }) else { return false }
        guard let updated = mutator(snapshot[index]) else { return false }
        snapshot[index] = updated
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateQueue.sync { self.launchedProcesses = snapshot }
            if self.selectedLaunchedProcess?.id == id {
                self.selectedLaunchedProcess = updated
            }
        }
        return true
    }
}
// swiftlint:enable type_body_length
