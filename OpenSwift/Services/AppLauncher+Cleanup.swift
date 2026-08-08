import Foundation

// MARK: - Process Cleanup
extension AppLauncher {
    func removeProcess(_ process: LaunchedProcess) {
        launchQueue.async { [weak self] in
            self?.launchedProcesses.removeAll { $0.id == process.id }
            logDebug("Removed process record: \(process.appName)", log: .launcher)
        }
    }

    func clearTerminatedProcesses() {
        launchQueue.async { [weak self] in
            guard let self = self else { return }
            let beforeCount = self.launchedProcesses.count
            self.launchedProcesses.removeAll { !$0.isRunning }
            let removedCount = beforeCount - self.launchedProcesses.count
            logDebug("Cleared \(removedCount) terminated process records", log: .launcher)
        }
    }
}
