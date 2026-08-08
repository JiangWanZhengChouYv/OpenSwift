import Foundation

// MARK: - Wallclock Hook Control
extension AppLauncherViewModel {
    func updateWallclockHook(_ enabled: Bool, for process: LaunchedProcess) {
        updateProcessState(for: process.id) { current in
            var mutable = current
            if !mutable.speedController.isConnected {
                let success = mutable.speedController.attachToProcess(pid: process.pid)
                if !success {
                    logError("Failed to attach to process \(process.pid) before setting wallclock hook", log: .launcher)
                    return nil
                }
            }
            _ = mutable.speedController.setHookWallclock(enabled)
            mutable.isWallclockHooked = enabled
            return mutable
        }
    }
}
