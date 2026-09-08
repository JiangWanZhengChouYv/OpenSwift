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
        let writeStep: (Double) -> Void = { [weak self] ratio in
            _ = self?.updateProcessState(for: process.id) { current in
                var mutable = current
                if !mutable.speedController.isConnected {
                    let success = mutable.speedController.attachToProcess(pid: pid)
                    if !success {
                        logError("Failed to attach to process \(pid) before setting speed", log: .launcher)
                        return nil
                    }
                }
                _ = mutable.speedController.setSpeedRatio(Float(ratio))
                mutable.currentSpeed = ratio
                return mutable
            }
            // 该进程恰是 UI 选中进程时，同步 SpeedControlState.currentSpeed，保持单一来源一致。
            if pid == SpeedControlState.shared.currentController?.targetPID {
                SpeedControlState.shared.syncFromController()
            }
        }
        if smoothing {
            let start = stateQueue.sync { () -> Float in
                guard let p = launchedProcesses.first(where: { $0.id == process.id }),
                      p.speedController.isConnected else {
                    return 1.0
                }
                return p.speedController.getSpeedRatio()
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
