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

    /// 按**稳定 pid** 把目标倍率写入行模型值（只改 UI 模型，不写共享内存）。
    /// 离散变速（快捷预设/输入框/快捷键）用它设置目标值，随后由该行速度滑块的 UI 动画
    /// 逐帧直写共享内存（UI 是平滑的唯一驱动源）。
    /// 禁止按 `LaunchedProcess.id` 更新：面板刷新/重建后快照 id 会陈旧，更新封装会静默丢写。
    @discardableResult
    func setModelSpeed(_ speed: Double, forPID pid: pid_t) -> Bool {
        guard let id = stateQueue.sync(execute: { launchedProcesses.first { $0.pid == pid }?.id }) else {
            return false
        }
        return updateProcessState(for: id) { mutable in
            var updated = mutable
            updated.currentSpeed = speed
            return updated
        }
    }
}
