import Foundation
import AppKit

enum AppLauncherError: Error, LocalizedError {
    case dylibNotFound
    case appNotFound
    case launchFailed(String)
    case processNotFound
    case alreadyLaunched
    case invalidPath
    
    var errorDescription: String? {
        switch self {
        case .dylibNotFound:
            return "找不到 SpeedPatch.dylib"
        case .appNotFound:
            return "找不到应用程序"
        case .launchFailed(let message):
            return "启动失败: \(message)"
        case .processNotFound:
            return "找不到进程"
        case .alreadyLaunched:
            return "应用已启动"
        case .invalidPath:
            return "无效的路径"
        }
    }
}

struct LaunchedProcess: Identifiable, Equatable {
    let id: UUID
    let pid: pid_t
    let appURL: URL
    let appName: String
    let launchedAt: Date
    var isRunning: Bool
    var currentSpeed: Double
    var isSpeedControlEnabled: Bool
    var isSharedMemoryConnected: Bool
    
    init(
        id: UUID = UUID(),
        pid: pid_t,
        appURL: URL,
        appName: String,
        launchedAt: Date = Date(),
        isRunning: Bool = true,
        currentSpeed: Double = 1.0,
        isSpeedControlEnabled: Bool = false,
        isSharedMemoryConnected: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.appURL = appURL
        self.appName = appName
        self.launchedAt = launchedAt
        self.isRunning = isRunning
        self.currentSpeed = currentSpeed
        self.isSpeedControlEnabled = isSpeedControlEnabled
        self.isSharedMemoryConnected = isSharedMemoryConnected
    }
    
    var runtime: TimeInterval {
        return Date().timeIntervalSince(launchedAt)
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
    
    static func == (lhs: LaunchedProcess, rhs: LaunchedProcess) -> Bool {
        return lhs.pid == rhs.pid && lhs.id == rhs.id
    }
}

class AppLauncher {
    static let shared = AppLauncher()
    
    private var launchedProcesses: [LaunchedProcess] = []
    private let launchQueue = DispatchQueue(label: "com.openswift.applauncher", qos: .userInitiated)
    private var processObserver: NSObjectProtocol?
    
    private init() {
        processObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleProcessTermination(notification)
        }
        
        print("[AppLauncher] 初始化完成")
    }
    
    deinit {
        if let observer = processObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    
    func getDylibPath() -> String? {
        print("[AppLauncher] 查找 SpeedPatch.dylib...")

        // 第一优先级: 应用包内路径 (发布后 dylib 会打包在 .app 内)
        let bundlePaths = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/PlugIns/SpeedPatch/SpeedPatch.dylib")
                .path,
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/SpeedPatch/SpeedPatch.dylib")
                .path,
            Bundle.main.bundleURL.appendingPathComponent("SpeedPatch.dylib").path
        ]

        // 第二优先级: 项目源码目录 (开发时最常用)
        let sourcePaths = [
            "/Users/markzhang/Documents/OpenSpeedy-Mac/SpeedPatch/SpeedPatch.dylib"
        ]

        // 第三优先级: DerivedData (Xcode 编译产物)
        let derivedDataPaths = [
            "/Users/markzhang/Library/Developer/Xcode/DerivedData/OpenSwift-ftrsxyspywcnxndyhlaiysacwqrv/Build/Products/Debug/SpeedPatch.dylib"
        ]

        // 最终 fallback: 系统标准路径
        let fallbackPaths = [
            "/usr/lib/SpeedPatch.dylib",
            "/usr/local/lib/SpeedPatch.dylib"
        ]

        let allPaths = bundlePaths + sourcePaths + derivedDataPaths + fallbackPaths

        for path in allPaths {
            if FileManager.default.fileExists(atPath: path) {
                print("[AppLauncher] ✅ 找到 SpeedPatch.dylib: \(path)")
                return path
            }
        }

        print("[AppLauncher] ❌ 未找到 SpeedPatch.dylib")
        print("[AppLauncher] 已搜索的路径:")
        for path in allPaths {
            print("  - \(path)")
        }
        return nil
    }
    
    func launchApp(at url: URL) -> Result<LaunchedProcess, AppLauncherError> {
        return launchQueue.sync {
            print("[AppLauncher] 准备启动应用: \(url.path)")
            
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("[AppLauncher] ❌ 应用不存在: \(url.path)")
                return .failure(.appNotFound)
            }
            
            guard let dylibPath = getDylibPath() else {
                return .failure(.dylibNotFound)
            }
            
            let appName = url.deletingPathExtension().lastPathComponent
            print("[AppLauncher] 应用名称: \(appName)")
            
            let config = NSWorkspace.OpenConfiguration()
            config.environment = [
                "DYLD_INSERT_LIBRARIES": dylibPath,
                "DYLD_FORCE_FLAT_NAMESPACE": "1"
            ]
            
            print("[AppLauncher] 环境变量配置:")
            print("  DYLD_INSERT_LIBRARIES = \(dylibPath)")
            print("  DYLD_FORCE_FLAT_NAMESPACE = 1")
            
            var launchError: Error?
            var launchedPID: pid_t = -1
            
            let semaphore = DispatchSemaphore(value: 0)
            
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error = error {
                    launchError = error
                    print("[AppLauncher] ❌ 启动失败: \(error.localizedDescription)")
                } else if let app = app {
                    launchedPID = app.processIdentifier
                    print("[AppLauncher] ✅ 应用启动成功, PID: \(launchedPID)")
                }
                semaphore.signal()
            }
            
            _ = semaphore.wait(timeout: .now() + 10)
            
            if let error = launchError {
                return .failure(.launchFailed(error.localizedDescription))
            }
            
            if launchedPID == -1 {
                return .failure(.launchFailed("无法获取进程 ID"))
            }
            
            let process = LaunchedProcess(
                pid: launchedPID,
                appURL: url,
                appName: appName
            )
            
            launchedProcesses.append(process)
            print("[AppLauncher] 已记录启动的进程: \(appName) (PID: \(launchedPID))")
            
            return .success(process)
        }
    }
    
    func launchApp(withBundleIdentifier bundleId: String) -> Result<LaunchedProcess, AppLauncherError> {
        print("[AppLauncher] 通过 Bundle ID 启动应用: \(bundleId)")
        
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            print("[AppLauncher] ❌ 找不到 Bundle ID 对应的应用: \(bundleId)")
            return .failure(.appNotFound)
        }
        
        return launchApp(at: appURL)
    }
    
    func terminateProcess(_ process: LaunchedProcess) -> Result<Void, AppLauncherError> {
        return launchQueue.sync {
            print("[AppLauncher] 终止进程: \(process.appName) (PID: \(process.pid))")
            
            guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == process.pid }) else {
                print("[AppLauncher] ❌ 进程未运行: \(process.pid)")
                updateProcessStatus(pid: process.pid, isRunning: false)
                return .failure(.processNotFound)
            }
            
            runningApp.terminate()
            updateProcessStatus(pid: process.pid, isRunning: false)
            print("[AppLauncher] ✅ 已发送终止信号")
            
            return .success(())
        }
    }
    
    func forceTerminateProcess(_ process: LaunchedProcess) -> Result<Void, AppLauncherError> {
        return launchQueue.sync {
            print("[AppLauncher] 强制终止进程: \(process.appName) (PID: \(process.pid))")
            
            guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == process.pid }) else {
                print("[AppLauncher] ❌ 进程未运行: \(process.pid)")
                updateProcessStatus(pid: process.pid, isRunning: false)
                return .failure(.processNotFound)
            }
            
            runningApp.forceTerminate()
            updateProcessStatus(pid: process.pid, isRunning: false)
            print("[AppLauncher] ✅ 已强制终止")
            
            return .success(())
        }
    }
    
    func getLaunchedProcesses() -> [LaunchedProcess] {
        return launchQueue.sync {
            updateAllProcessesStatus()
            return launchedProcesses
        }
    }
    
    func getLaunchedProcess(for pid: pid_t) -> LaunchedProcess? {
        return launchQueue.sync {
            return launchedProcesses.first { $0.pid == pid }
        }
    }
    
    func isProcessLaunchedByUs(pid: pid_t) -> Bool {
        return launchQueue.sync {
            return launchedProcesses.contains { $0.pid == pid }
        }
    }
    
    func isProcessRunning(pid: pid_t) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == pid }
    }
    
    private func updateProcessStatus(pid: pid_t, isRunning: Bool) {
        if let index = launchedProcesses.firstIndex(where: { $0.pid == pid }) {
            launchedProcesses[index].isRunning = isRunning
        }
    }
    
    private func updateAllProcessesStatus() {
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        
        for index in launchedProcesses.indices {
            launchedProcesses[index].isRunning = runningPIDs.contains(launchedProcesses[index].pid)
        }
    }
    
    private func handleProcessTermination(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        
        let terminatedPID = app.processIdentifier
        let appName = app.localizedName ?? "Unknown"
        
        print("[AppLauncher] 检测到进程终止: \(appName) (PID: \(terminatedPID))")
        
        launchQueue.async { [weak self] in
            self?.updateProcessStatus(pid: terminatedPID, isRunning: false)
        }
    }
    
    func removeProcess(_ process: LaunchedProcess) {
        launchQueue.async { [weak self] in
            self?.launchedProcesses.removeAll { $0.id == process.id }
            print("[AppLauncher] 已移除进程记录: \(process.appName)")
        }
    }
    
    func clearTerminatedProcesses() {
        launchQueue.async { [weak self] in
            guard let self = self else { return }
            let beforeCount = self.launchedProcesses.count
            self.launchedProcesses.removeAll { !$0.isRunning }
            let removedCount = beforeCount - self.launchedProcesses.count
            print("[AppLauncher] 清理了 \(removedCount) 个已终止的进程记录")
        }
    }
}
