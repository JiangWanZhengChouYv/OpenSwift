import Foundation

// AppLauncherViewModel+SpeedSmoothing.swift
// 单一驱动入口 applySpeed：把「平滑变速 + 写底层 + 同步显示」收敛到这里。
// 滑块拖动直写（smooth: false）与离散变速（smooth: true）共用同一入口。
extension AppLauncherViewModel {
    /// 设置进程速度；`smooth` 为 true 且开启平滑时按设定时长渐变到目标倍率，
    /// 否则瞬时写入。滑块手动拖动传 `smooth: false` 保持跟手。
    func updateSpeed(_ speed: Double, for process: LaunchedProcess, smooth: Bool = true) {
        let pid = process.pid
        let controller: SpeedControlManager
        if let fresh = stateQueue.sync(execute: { launchedProcesses.first { $0.pid == pid } }) {
            controller = fresh.speedController
        } else {
            controller = process.speedController
        }
        applySpeed(to: controller, pid: pid, target: speed, smooth: smooth)
    }

    /// 单一驱动：按稳定 pid 写底层（setSpeedRatio）+ 同步显示（panelSetDisplay）。
    /// 平滑走 SpeedSmoother 主线程步进，逐帧写底层并刷新显示，UI 跟随底层同源同走。
    func applySpeed(to controller: SpeedControlManager, pid: pid_t, target: Double, smooth: Bool) {
        guard controller.isConnected || controller.attachToProcess(pid: pid) else {
            logError("Failed to attach to process \(pid) before setting speed", log: .launcher)
            return
        }
        let smoothing = smooth && AppSettings.shared.speedSmoothingEnabled
        let duration = AppSettings.shared.speedSmoothingDuration
        if smoothing {
            let start = controller.getSpeedRatio()
            SpeedSmoother.shared.apply(pid: pid, from: start, to: Float(target),
                                       duration: duration) { [weak self] ratio in
                guard let self else { return }
                if controller.setSpeedRatio(ratio) {
                    self.panelSetDisplay(Double(ratio), forPID: pid)
                }
            }
        } else {
            SpeedSmoother.shared.cancel(pid)
            if controller.setSpeedRatio(Float(target)) {
                panelSetDisplay(target, forPID: pid)
            }
        }
        // 选中进程时状态回显 target（快捷键/菜单/通知显示行为不变）
        if pid == SpeedControlState.shared.currentController?.targetPID {
            SpeedControlState.shared.currentSpeed = target
        }
    }
}
