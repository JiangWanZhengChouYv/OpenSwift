import Foundation

/// 变速平滑器：把共享内存倍率按设定时长线性渐变到目标值。
/// 用于快捷键/快捷按钮/输入框等离散变速，滑块手动拖动保持直写（不经此平滑）。
///
/// 平滑任务按 PID 隔离：每个进程各自维护独立的进行中 Task / 最近已写值。
/// 这样「面板写速」与「快捷键/菜单/插件 setSpeed」两条路径对同一 PID 是同一份渐变，
/// 不会因各自取消对方的 Task 而残留中间值；不同 PID 的变速互不干扰。
final class SpeedSmoother {
    static let shared = SpeedSmoother()

    private struct Entry {
        var task: Task<Void, Never>?
        var lastWritten: Float?
        var isRunning: Bool = false
    }

    /// 每个被注入进程各自的平滑状态。仅主线程访问。
    private var entries: [pid_t: Entry] = [:]

    private init() {}

    /// 从 start 线性渐变到 target，write 闭包在每一小步回调（主线程）。
    /// 对同一 PID 新调用会取消上一次未完成的渐变，并从「最近已写值」续走落到新 target，
    /// 保证最终某次写入精确等于最新的 target。
    func apply(pid: pid_t, from start: Float, to target: Float, duration: TimeInterval,
               write: @escaping (Float) -> Void) {
        var entry = entries[pid] ?? Entry()
        entry.task?.cancel()

        // 起点：平滑正在进行时用最近已写值续走（那段值就是共享内存里的真实最近值）；
        // 否则取调用方传入的共享内存最近值（兼容外部直接改速后的一致性）。
        let actualStart = entry.isRunning ? (entry.lastWritten ?? start) : start
        entry.lastWritten = actualStart

        guard duration > 0.0001, abs(target - actualStart) >= 0.0001 else {
            entry.isRunning = false
            entry.lastWritten = target
            entries[pid] = entry
            write(target)
            return
        }

        entry.isRunning = true
        entry.task = Task { @MainActor [weak self] in
            let interval: TimeInterval = 0.016
            var progress: Float = 0
            while progress < 1 {
                if Task.isCancelled { return }
                let ratio = actualStart + (target - actualStart) * progress
                self?.entries[pid]?.lastWritten = ratio
                write(ratio)
                progress += Float(interval / max(duration, 0.016))
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            if !Task.isCancelled {
                self?.entries[pid]?.lastWritten = target
                self?.entries[pid]?.isRunning = false
                write(target)
            }
            self?.entries[pid]?.task = nil
        }
        entries[pid] = entry
    }

    /// 取消指定 PID 正在进行的平滑（用于滑块拖动直写接管，避免残留渐变与拖动打架）。
    func cancel(_ pid: pid_t) {
        guard var entry = entries[pid] else { return }
        entry.task?.cancel()
        entry.task = nil
        entry.isRunning = false
        entry.lastWritten = nil
        entries[pid] = entry
    }

    func cancelAll() {
        entries.values.forEach { $0.task?.cancel() }
        entries.removeAll()
    }
}
