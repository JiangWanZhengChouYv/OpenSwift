import Foundation
import Combine

// 进程加速统计：基于 AppLauncherViewModel 的已启动进程，按进程聚合
// 累计加速时长、倍率变更次数、当前倍率、倍率变化历史。
// 内存态即可，随会话更新，不做磁盘持久化。

/// 单个进程的统计条目（每 1s 采样一次）
final class SpeedStatItem: ObservableObject, Identifiable {
    let id: pid_t
    let processName: String

    @Published var currentRatio: Double = 1.0
    @Published var changeCount: Int = 0
    @Published var accumulatedSeconds: Double = 0
    /// 倍率变化历史（最近 20 条，越新越靠前）
    @Published private(set) var ratioHistory: [RatioRecord] = []

    private var lastRatio: Double = 1.0
    private let maxHistoryCount = 20

    init(pid: pid_t, processName: String) {
        self.id = pid
        self.processName = processName
    }

    /// 记录一次倍率采样；比值与上次不同则计为一次变更
    func sample(ratio: Double, isEnabled: Bool) {
        currentRatio = ratio
        if abs(ratio - lastRatio) > 0.0001 {
            changeCount += 1
            ratioHistory.insert(RatioRecord(ratio: ratio), at: 0)
            if ratioHistory.count > maxHistoryCount {
                ratioHistory.removeLast()
            }
        }
        lastRatio = ratio
        // 仅加速（倍率≠1）且开启的状态下累计「受控时长」
        if isEnabled && abs(ratio - 1.0) > 0.0001 {
            accumulatedSeconds += 1.0
        }
    }
}

struct RatioRecord: Identifiable {
    let id: UUID = UUID()
    let timestamp: Date = Date()
    let ratio: Double
}

/// 会话级统计聚合器：持有按 pid 聚合的统计项，提供采样与查询
final class SpeedStatistics: ObservableObject {
    static let shared = SpeedStatistics()

    @Published private(set) var items: [SpeedStatItem] = []

    private var timer: Timer?
    private var isSetup: Bool = false
    private let stateQueue = DispatchQueue(label: "com.openswift.speedstatistics.state", qos: .utility)

    private init() {
        // 轻量 init，重量工作延迟到 setup()
    }

    /// 由 AppState.setup() 在窗口显示后调用
    func setup() {
        guard !isSetup else { return }
        isSetup = true

        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
        logInfo("SpeedStatistics setup complete", log: .openswift)
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
    }

    /// 每 1s 从 AppLauncherViewModel 采样已启动进程
    private func tick() {
        let processes = AppLauncherViewModel.shared.launchedProcesses
        guard !processes.isEmpty else { return }

        stateQueue.sync { [weak self] in
            guard let self = self else { return }
            for process in processes {
                self.ensureItem(pid: process.pid, name: process.appName)
                    .sample(ratio: process.currentSpeed, isEnabled: process.isSpeedControlEnabled)
            }
        }
    }

    private func ensureItem(pid: pid_t, name: String) -> SpeedStatItem {
        if let existing = items.first(where: { $0.id == pid }) {
            return existing
        }
        let item = SpeedStatItem(pid: pid, processName: name)
        items.append(item)
        return item
    }

    var totalAccumulatedSeconds: Double {
        items.reduce(0) { $0 + $1.accumulatedSeconds }
    }
}
