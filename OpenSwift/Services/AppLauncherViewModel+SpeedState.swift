import Foundation

// 独立 extension：与状态镜像/共享内存即时同步相关的能力。
// 拆分到独立文件，避免 AppLauncherViewModel.swift 超出 file_length(400)。
extension AppLauncherViewModel {
    /// 按稳定 pid 直接更新行 currentSpeed（驱动步进值直接写显示，不回读）。
    /// 平滑器走主线程步进，逐帧把显示值设为当前步进值，UI 跟随底层平滑。
    @discardableResult
    func panelSetDisplay(_ speed: Double, forPID pid: pid_t) -> Bool {
        stateQueue.sync {
            guard let index = launchedProcesses.firstIndex(where: { $0.pid == pid }) else { return false }
            var row = launchedProcesses[index]
            row.currentSpeed = speed
            launchedProcesses[index] = row
            if selectedLaunchedProcess?.pid == pid {
                selectedLaunchedProcess?.currentSpeed = speed
            }
            return true
        }
    }

    /// 按稳定 pid 直接更新行的速度控制开关状态（供共享内存字节与 UI 行同步）。
    @discardableResult
    func panelSetSpeedControlEnabled(_ enabled: Bool, forPID pid: pid_t) -> Bool {
        stateQueue.sync {
            guard let index = launchedProcesses.firstIndex(where: { $0.pid == pid }) else { return false }
            var row = launchedProcesses[index]
            row.isSpeedControlEnabled = enabled
            launchedProcesses[index] = row
            if selectedLaunchedProcess?.pid == pid {
                selectedLaunchedProcess?.isSpeedControlEnabled = enabled
            }
            return true
        }
    }

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
