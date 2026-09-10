import Foundation

// 独立 extension：与状态镜像/共享内存即时同步相关的能力。
// 拆分到独立文件，避免 AppLauncherViewModel.swift 超出 file_length(400)。
extension AppLauncherViewModel {
    /// 把指定 pid 的共享内存速度/启停状态即时镜像到对应行，供快捷键等绕过 UI 改速的路径使用。
    @discardableResult
    func reflectSpeedForPID(_ pid: pid_t) -> Bool {
        guard let id = stateQueue.sync(execute: { launchedProcesses.first { $0.pid == pid }?.id }) else {
            return false
        }
        return updateProcessState(for: id) { mutable in
            var updated = mutable
            if let state = updated.speedController.syncFromSharedMemory() {
                updated.currentSpeed = Double(state.speedRatio)
                updated.isSpeedControlEnabled = state.isEnabled
            }
            return updated
        }
    }
}
