import Foundation
import AppKit

struct InjectedProcess: Identifiable, Equatable, Hashable {
    let id: UUID
    let pid: pid_t
    let processInfo: ProcessInfo
    let injectedAt: Date
    var speedRatio: Double
    var isEnabled: Bool
    let sharedMemoryKey: String
    var isActive: Bool
    
    init(
        id: UUID = UUID(),
        pid: pid_t,
        processInfo: ProcessInfo,
        injectedAt: Date = Date(),
        speedRatio: Double = 1.0,
        isEnabled: Bool = false,
        sharedMemoryKey: String? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.pid = pid
        self.processInfo = processInfo
        self.injectedAt = injectedAt
        self.speedRatio = speedRatio
        self.isEnabled = isEnabled
        self.sharedMemoryKey = sharedMemoryKey ?? InjectionProtocol.Constants.sharedMemoryKey(for: pid)
        self.isActive = isActive
    }
    
    var runtime: TimeInterval {
        return Date().timeIntervalSince(injectedAt)
    }
    
    var formattedRuntime: String {
        let interval = runtime
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    var speedDescription: String {
        if speedRatio < 0.9 {
            let factor = 1.0 / speedRatio
            return String(format: "%.1fx 慢速", factor)
        } else if speedRatio > 1.1 {
            return String(format: "%.1fx 加速", speedRatio)
        } else {
            return "正常速度"
        }
    }
    
    var statusDescription: String {
        if !isActive {
            return "已终止"
        } else if isEnabled {
            return "运行中"
        } else {
            return "已暂停"
        }
    }
    
    static func == (lhs: InjectedProcess, rhs: InjectedProcess) -> Bool {
        return lhs.pid == rhs.pid && lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(pid)
    }
}

struct ProcessGroup: Identifiable {
    let id: UUID
    var name: String
    var processes: [InjectedProcess]
    var createdAt: Date
    var isPreset: Bool
    
    init(
        id: UUID = UUID(),
        name: String,
        processes: [InjectedProcess] = [],
        createdAt: Date = Date(),
        isPreset: Bool = false
    ) {
        self.id = id
        self.name = name
        self.processes = processes
        self.createdAt = createdAt
        self.isPreset = isPreset
    }
    
    var processCount: Int {
        return processes.count
    }
    
    var activeProcessCount: Int {
        return processes.filter { $0.isActive }.count
    }
    
    mutating func addProcess(_ process: InjectedProcess) {
        if !processes.contains(where: { $0.pid == process.pid }) {
            processes.append(process)
        }
    }
    
    mutating func removeProcess(pid: pid_t) {
        processes.removeAll { $0.pid == pid }
    }
    
    mutating func updateProcess(_ updatedProcess: InjectedProcess) {
        if let index = processes.firstIndex(where: { $0.pid == updatedProcess.pid }) {
            processes[index] = updatedProcess
        }
    }
}

class ProcessHistory: ObservableObject {
    static let shared = ProcessHistory()
    
    @Published var history: [InjectedProcess] = []
    @Published var recentPIDs: Set<pid_t> = []
    
    private let maxHistoryCount = 100
    private let persistenceKey = "ProcessHistory"
    private var isSetup: Bool = false
    
    private init() {
        // init 只做最轻量操作
        // 所有重操作延迟到 setup()
    }
    
    // 由 AppDelegate 在窗口显示后调用
    func setup() {
        guard !isSetup else { return }
        isSetup = true
        loadFromDisk()
    }
    
    func addToHistory(_ process: InjectedProcess) {
        if !recentPIDs.contains(process.pid) {
            recentPIDs.insert(process.pid)
            
            if history.count >= maxHistoryCount {
                if let oldest = history.first {
                    recentPIDs.remove(oldest.pid)
                }
                history.removeFirst()
            }
            
            history.append(process)
            saveToDisk()
        }
    }
    
    func isProcessInHistory(pid: pid_t) -> Bool {
        return recentPIDs.contains(pid)
    }
    
    func getLastSpeedRatio(for pid: pid_t) -> Double? {
        return history.first { $0.pid == pid }?.speedRatio
    }
    
    func clearHistory() {
        history.removeAll()
        recentPIDs.removeAll()
        saveToDisk()
    }
    
    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(history.map { ProcessHistoryData(from: $0) }) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }
    
    private func loadFromDisk() {
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let historyData = try? JSONDecoder().decode([ProcessHistoryData].self, from: data) {
            history = historyData.map { $0.toInjectedProcess() }
            recentPIDs = Set(history.map { $0.pid })
        }
    }
    
    func shutdown() {
        saveToDisk()
        logInfo("ProcessHistory shutdown complete", log: .openswift)
    }
}

struct ProcessHistoryData: Codable {
    let pid: pid_t
    let name: String
    let speedRatio: Double
    let isEnabled: Bool
    let lastUsed: Date
    
    init(from process: InjectedProcess) {
        self.pid = process.pid
        self.name = process.processInfo.name
        self.speedRatio = process.speedRatio
        self.isEnabled = process.isEnabled
        self.lastUsed = process.injectedAt
    }
    
    func toInjectedProcess() -> InjectedProcess {
        let processInfo = ProcessInfo(
            pid: pid,
            name: name,
            path: nil,
            bundleIdentifier: nil,
            icon: nil
        )
        return InjectedProcess(
            pid: pid,
            processInfo: processInfo,
            injectedAt: lastUsed,
            speedRatio: speedRatio,
            isEnabled: isEnabled
        )
    }
}

struct ProcessGroupData: Codable {
    let id: UUID
    let name: String
    let createdAt: Date
    let isPreset: Bool
    let processes: [ProcessHistoryData]
    
    init(from group: ProcessGroup) {
        self.id = group.id
        self.name = group.name
        self.createdAt = group.createdAt
        self.isPreset = group.isPreset
        self.processes = group.processes.map { ProcessHistoryData(from: $0) }
    }
    
    func toProcessGroup() -> ProcessGroup {
        var group = ProcessGroup(
            id: id,
            name: name,
            createdAt: createdAt,
            isPreset: isPreset
        )
        
        for processData in processes {
            let process = processData.toInjectedProcess()
            group.addProcess(process)
        }
        
        return group
    }
}
