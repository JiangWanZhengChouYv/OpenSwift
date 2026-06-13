import Foundation
import Combine
import AppKit

// 关键修复:
// 1. init 中不创建 Timer (Timer 需要主线程 runloop)
// 2. init 中不立即调用 refreshLaunchedProcesses (会触发 AppLauncher.shared 导致循环)
// 3. Timer 和刷新都延迟到 setup() 中，由 AppDelegate 在窗口显示后调用
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
        
        print("[AppLauncherViewModel] Setup complete")
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func refreshLaunchedProcesses() {
        DispatchQueue.main.async { [weak self] in
            self?.launchedProcesses = AppLauncher.shared.getLaunchedProcesses()
        }
    }
    
    func selectProcess(_ process: LaunchedProcess?) {
        selectedLaunchedProcess = process
        if let process = process {
            let success = SpeedControlManager.shared.attachToProcess(pid: process.pid)
            if let index = launchedProcesses.firstIndex(where: { $0.id == process.id }) {
                launchedProcesses[index].isSharedMemoryConnected = success
            }
        } else {
            SpeedControlManager.shared.detachFromProcess()
        }
    }
    
    func updateSpeed(_ speed: Double, for process: LaunchedProcess) {
        _ = SpeedControlManager.shared.setSpeedRatio(Float(speed))
        if let index = launchedProcesses.firstIndex(where: { $0.id == process.id }) {
            launchedProcesses[index].currentSpeed = speed
        }
    }
    
    func toggleSpeedControl(_ enabled: Bool, for process: LaunchedProcess) {
        _ = SpeedControlManager.shared.setEnabled(enabled)
        if let index = launchedProcesses.firstIndex(where: { $0.id == process.id }) {
            launchedProcesses[index].isSpeedControlEnabled = enabled
        }
    }
    
    func disconnectFromProcess() {
        SpeedControlManager.shared.detachFromProcess()
        if let process = selectedLaunchedProcess, let index = launchedProcesses.firstIndex(where: { $0.id == process.id }) {
            launchedProcesses[index].isSharedMemoryConnected = false
        }
        selectedLaunchedProcess = nil
    }
    
    func launchApp(at url: URL) {
        let result = AppLauncher.shared.launchApp(at: url)
        
        switch result {
        case .success(let process):
            DispatchQueue.main.async { [weak self] in
                self?.successMessage = "成功启动 \(process.appName)"
                self?.showSuccess = true
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
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
        let result = AppLauncher.shared.terminateProcess(process)
        
        switch result {
        case .success:
            DispatchQueue.main.async { [weak self] in
                self?.successMessage = "已终止 \(process.appName)"
                self?.showSuccess = true
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
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
        let result = AppLauncher.shared.forceTerminateProcess(process)
        
        switch result {
        case .success:
            DispatchQueue.main.async { [weak self] in
                self?.successMessage = "已强制终止 \(process.appName)"
                self?.showSuccess = true
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
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
        AppLauncher.shared.removeProcess(process)
        refreshLaunchedProcesses()
    }
    
    func cleanupTerminatedProcesses() {
        for process in launchedProcesses where !process.isRunning {
            if selectedLaunchedProcess?.id == process.id {
                disconnectFromProcess()
            }
        }
        AppLauncher.shared.clearTerminatedProcesses()
        refreshLaunchedProcesses()
    }
}
