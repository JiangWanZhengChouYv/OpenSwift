import Foundation

/// 变速平滑器：把共享内存倍率按设定时长线性渐变到目标值。
/// 用于快捷键/快捷按钮/输入框等离散变速，滑块手动拖动保持直写（不经此平滑）。
final class SpeedSmoother {
    static let shared = SpeedSmoother()

    private var activeTask: Task<Void, Never>?

    private init() {}

    /// 从 start 线性渐变到 target，write 闭包在每一小步回调（主线程）。
    /// 新调用会取消上一次未完成的渐变（连按不重叠，从当前共享内存值续走）。
    func apply(from start: Float, to target: Float, duration: TimeInterval, write: @escaping (Float) -> Void) {
        activeTask?.cancel()
        guard duration > 0.0001 else {
            write(target)
            return
        }
        // 起点与目标几乎一致，直接写入，避免空转。
        if abs(target - start) < 0.0001 {
            write(target)
            return
        }
        activeTask = Task { @MainActor [weak self] in
            let interval: TimeInterval = 0.016
            var progress: Float = 0
            while progress < 1 {
                if Task.isCancelled { return }
                let ratio = start + (target - start) * progress
                write(ratio)
                progress += Float(interval / max(duration, 0.016))
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            if !Task.isCancelled {
                write(target)
            }
            self?.activeTask = nil
        }
    }

    func cancelAll() {
        activeTask?.cancel()
        activeTask = nil
    }
}
