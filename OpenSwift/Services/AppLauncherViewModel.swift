import Foundation
import Combine
import AppKit

// 关键修复:
// 1. 每个 LaunchedProcess 持有自己的 SpeedControlManager 实例（不再使用全局单例）
//    这样可以同时支持多个进程的独立加速/减速上下文。
// 2. 所有对 launchedProcesses 数组的读写都通过 stateQueue 串行化，
//    避免 SwiftUI 在主线程刷新时与后台计时器刷新发生数据竞争。
// 3. Timer 在主线程创建，闭包中使用 [weak self]。
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
    private var isSetup: Bool = false
    private let stateQueue = DispatchQueue(label: "com.openswift.applaunchervm.state", qos: .userInitiated)

    private init() {
        // 什么也不做
        // 所有 heavy 操作延迟到 setup()
    }

    // 由 AppDelegate 在窗口显示后调用
    func setup() {
        guard !isSetup else { return }
        isSetup = true

        refreshLaunchedProcesses()

        // Timer 在主线程创建
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.refreshLaunchedProcesses()
            }
        }

        logInfo("AppLauncherViewModel setup complete", log: .launcher)
    }

    deinit {
        timer?.invalidate()
    }

    func refreshLaunchedProcesses() {
        let latest = AppLauncher.shared.getLaunchedProcesses()
        DispatchQueue.main.async { [weak self] in
            self?.launchedProcesses = latest
        }
    }

    func selectProcess(_ process: LaunchedProcess?) {
        selectedLaunchedProcess = process
        if let process = process {
            updateProcessState(for: process.id) { current in
                var mutable = current
                let success = mutable.speedController.attachToProcess(pid: process.pid)
                mutable.isSharedMemoryConnected = success
                if let state = mutable.speedController.syncFromSharedMemory() {
                    mutable.currentSpeed = Double(state.speedRatio)
                    mutable.isSpeedControlEnabled = state.isEnabled
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

    private func updateProcessState(for id: UUID, mutator: (LaunchedProcess) -> LaunchedProcess?) {
        var snapshot: [LaunchedProcess] = stateQueue.sync { launchedProcesses }
        guard let index = snapshot.firstIndex(where: { $0.id == id }) else { return }
        guard let updated = mutator(snapshot[index]) else { return }
        snapshot[index] = updated
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateQueue.sync { self.launchedProcesses = snapshot }
            if self.selectedLaunchedProcess?.id == id {
                self.selectedLaunchedProcess = updated
            }
        }
    }
}
