import Foundation

// MARK: - Recursive Inject Control（递归注入开关）
extension AppLauncherViewModel {
    func updateRecursiveInjection(_ enabled: Bool, for process: LaunchedProcess) {
        updateProcessState(for: process.id) { current in
            var mutable = current
            if !mutable.speedController.isConnected {
                let success = mutable.speedController.attachToProcess(pid: process.pid)
                if !success {
                    logError(
                        "Failed to attach to process \(process.pid) before setting recursive injection",
                        log: .launcher
                    )
                    return nil
                }
            }
            _ = mutable.speedController.setRecursiveInject(enabled)
            mutable.isRecursiveInjection = enabled
            return mutable
        }
    }
}
