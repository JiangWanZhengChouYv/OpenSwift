import Foundation

// AppLauncherViewModel+SpeedWrite.swift
// 变速写入的两个入口：平滑由 UI 动画驱动（见 SpeedSliderView 的 SpeedAnimationDriver），
// 因此这里只负责「设目标模型值」与「直写共享内存」两件事，不再有定时器平滑器。
extension AppLauncherViewModel {
    /// 设置进程速度。
    /// - `smooth: true`（快捷预设/输入框等离散变速）：只把目标倍率写入行模型值，
    ///   由该行速度滑块的 UI 动画逐帧直写共享内存（UI 是唯一驱动源，避免第二个动画源互相打架）。
    /// - `smooth: false`（滑块/卡片等拖动类控件）：立即直写共享内存，保持跟手。
    func updateSpeed(_ speed: Double, for process: LaunchedProcess, smooth: Bool = true) {
        if smooth {
            setModelSpeed(speed, forPID: process.pid)
            return
        }
        writeSpeedToSharedMemory(speed, forPID: process.pid, fallback: process)
    }

    /// 按稳定 pid 直写共享内存倍率（拖动/手拖路径），并把该值镜像回行模型显示。
    func writeSpeedToSharedMemory(_ speed: Double, forPID pid: pid_t, fallback: LaunchedProcess? = nil) {
        let fresh = stateQueue.sync { launchedProcesses.first { $0.pid == pid } }
        guard let controller = fresh?.speedController ?? fallback?.speedController else {
            logError("No speed controller for pid \(pid)", log: .launcher)
            return
        }
        if !controller.isConnected && !controller.attachToProcess(pid: pid) {
            logError("Failed to attach to process \(pid) before setting speed", log: .launcher)
            return
        }
        _ = controller.setSpeedRatio(Float(speed))
        setModelSpeed(speed, forPID: pid)
        if pid == SpeedControlState.shared.currentController?.targetPID {
            SpeedControlState.shared.syncFromController()
        }
    }
}
