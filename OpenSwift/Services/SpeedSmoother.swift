import Foundation

/// 变速平滑器：把共享内存倍率按设定时长线性渐变到目标值。
/// 用于快捷键/快捷按钮/输入框等离散变速，滑块手动拖动保持直写（不经此平滑）。
final class SpeedSmoother {
    static let shared = SpeedSmoother()

    private var activeTask: Task<Void, Never>?

    /// 本平滑器最近一次实际写出的值（作为下一步/取代时续走的基础，避免从调用方旧快照重新起步）。
    private var lastWritten: Float?

    /// 本平滑器当前是否正在进行渐变。仅当在进行中时才用 `lastWritten` 续走；
    /// 空闲时一律以调用方从共享内存读到的 `start` 为准（兼顾滑块直写等外部改速）。
    private var isRunning = false

    private init() {}

    /// 从 start 线性渐变到 target，write 闭包在每一小步回调（主线程）。
    /// 新调用会取消上一次未完成的渐变，并从「最近已写值」续走落到新 target，
    /// 保证最终某次写入精确等于最新的 target。
    func apply(from start: Float, to target: Float, duration: TimeInterval, write: @escaping (Float) -> Void) {
        activeTask?.cancel()

        // 起点：平滑正在进行时用最近已写值续走（那段值就是共享内存里的真实最近值）；
        // 否则取调用方传入的共享内存最近值（兼容外部直接改速后的一致性）。
        let actualStart = (isRunning && lastWritten != nil) ? lastWritten! : start
        lastWritten = actualStart

        guard duration > 0.0001 else {
            isRunning = false
            lastWritten = target
            write(target)
            return
        }
        // 起点与目标几乎一致，直接写入，避免空转。
        if abs(target - actualStart) < 0.0001 {
            isRunning = false
            lastWritten = target
            write(target)
            return
        }

        isRunning = true
        activeTask = Task { @MainActor [weak self] in
            let interval: TimeInterval = 0.016
            var progress: Float = 0
            while progress < 1 {
                if Task.isCancelled { return }
                let ratio = actualStart + (target - actualStart) * progress
                self?.lastWritten = ratio
                write(ratio)
                progress += Float(interval / max(duration, 0.016))
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            if !Task.isCancelled {
                self?.lastWritten = target
                self?.isRunning = false
                write(target)
            }
            self?.activeTask = nil
        }
    }

    func cancelAll() {
        activeTask?.cancel()
        activeTask = nil
        isRunning = false
        lastWritten = nil
    }
}
