import Foundation

// AppLauncherViewModel+SpeedSmoothing.swift
// 把 updateSpeed（离散变速 + 平滑过渡）从主文件拆出，满足 file_length <= 400。
extension AppLauncherViewModel {
    /// 设置进程速度；`smooth` 为 true 且开启平滑时按设定时长渐变到目标倍率，
    /// 否则瞬时写入。滑块手动拖动传 `smooth: false` 保持跟手。
    func updateSpeed(_ speed: Double, for process: LaunchedProcess, smooth: Bool = true) {
        let pid = process.pid
        let smoothing = smooth && AppSettings.shared.speedSmoothingEnabled
        let duration = AppSettings.shared.speedSmoothingDuration

        // 直写共享内存：按稳定 pid 解析 controller，写后按 pid 镜像回 UI。
        // 不经 updateProcessState(for: id)——面板刷新/重建可能让传入快照的 id 陈旧，
        // 导致 updateProcessState 按 id 找不到行而静默丢写。
        let writeStep: (Double) -> Void = { [weak self] ratio in
            guard let self else { return }
            // 优先用 launchedProcesses 里同 pid 的 controller（刷新后仍是同一实例/同一块 shm），
            // 快照行仅作后备。
            let controller: SpeedControlManager
            if let fresh = stateQueue.sync(execute: { self.launchedProcesses.first { $0.pid == pid } }) {
                controller = fresh.speedController
            } else {
                controller = process.speedController
            }
            if !controller.isConnected && !controller.attachToProcess(pid: pid) {
                logError("Failed to attach to process \(pid) before setting speed", log: .launcher)
                return
            }
            _ = controller.setSpeedRatio(Float(ratio))
            // 按稳定 pid 镜像回 UI 行（滑块/输入框显示真实底层值）。
            reflectSpeedForPID(pid)
            // 该进程恰是 UI 选中进程时，同步 SpeedControlState.currentSpeed，保持单一来源一致。
            if pid == SpeedControlState.shared.currentController?.targetPID {
                SpeedControlState.shared.syncFromController()
            }
        }

        if smoothing {
            // 平滑起点：从当前该 pid 的 controller 读真实倍率，不用可能陈旧的快照行。
            let start: Float = stateQueue.sync {
                if let p = launchedProcesses.first(where: { $0.pid == pid }), p.speedController.isConnected {
                    return p.speedController.getSpeedRatio()
                }
                return process.speedController.isConnected ? process.speedController.getSpeedRatio() : 1.0
            }
            SpeedSmoother.shared.apply(pid: pid, from: start, to: Float(speed), duration: duration, write: { ratio in
                writeStep(Double(ratio))
            })
        } else {
            // 滑块拖动直写路径：先取消该 PID 残留平滑，避免旧渐变任务与拖动打架造成显示回跳。
            SpeedSmoother.shared.cancel(pid)
            writeStep(speed)
        }
    }
}
