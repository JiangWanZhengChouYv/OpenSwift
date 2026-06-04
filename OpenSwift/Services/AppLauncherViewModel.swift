import Foundation
import Combine
import AppKit

class AppLauncherViewModel: ObservableObject {
    static let shared = AppLauncherViewModel()
    
    @Published var launchedProcesses: [LaunchedProcess] = []
    @Published var selectedLaunchedProcess: LaunchedProcess?
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var showSuccess = false
    @Published var successMessage = ""
    
    private let appLauncher = AppLauncher.shared
    private let speedControlManager = SpeedControlManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    
    private init() {
        refreshLaunchedProcesses()
        
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshLaunchedProcesses()
        }
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func refreshLaunchedProcesses() {
        DispatchQueue.main.async { [weak self] in
            self?.launchedProcesses = self?.appLauncher.getLaunchedProcesses() ?? []
        }
    }
    
    func selectProcess(_ process: LaunchedProcess?) {
        selectedLaunchedProcess = process
        if let process = process {
            let success = speedControlManager.attachToProcess(pid: process.pid)
            if let index = launchedProcesses.firstIndex(where: { $0.id == process.id }) {
                launchedProcesses[index].isSharedMemoryConnected = success
            }
        } else {
            speedControlManager.detachFromProcess()
        }
    }
    
    func updateSpeed(_ speed: Double, for process: LaunchedProcess) {
        _ = speedControlManager.setSpeedRatio(Float(speed))
        if let index = launchedProcesses.firstIndex(where: { $0.id == process.id }) {
            launchedProcesses[index].currentSpeed = speed
        }
    }
    
    func toggleSpeedControl(_ enabled: Bool, for process: LaunchedProcess) {
        _ = speedControlManager.setEnabled(enabled)
        if let index = launchedProcesses.firstIndex(where: { $0.id == process.id }) {
            launchedProcesses[index].isSpeedControlEnabled = enabled
        }
    }
    
    func disconnectFromProcess() {
        speedControlManager.detachFromProcess()
        if let process = selectedLaunchedProcess, let index = launchedProcesses.firstIndex(where: { $0.id == process.id }) {
            launchedProcesses[index].isSharedMemoryConnected = false
        }
        selectedLaunchedProcess = nil
    }
    
    func launchApp(at url: URL) {
        let result = appLauncher.launchApp(at: url)
        
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
        let result = appLauncher.terminateProcess(process)
        
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
        let result = appLauncher.forceTerminateProcess(process)
        
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
        appLauncher.removeProcess(process)
        refreshLaunchedProcesses()
    }
    
    func cleanupTerminatedProcesses() {
        for process in launchedProcesses where !process.isRunning {
            if selectedLaunchedProcess?.id == process.id {
                disconnectFromProcess()
            }
        }
        appLauncher.clearTerminatedProcesses()
        refreshLaunchedProcesses()
    }
}
