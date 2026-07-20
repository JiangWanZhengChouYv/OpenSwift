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
    /// 与目标进程一一对应的 SpeedControlManager。由 AppLauncher 在创建进程时
    /// 初始化（lazy attach），不与其他进程共享上下文。
    var speedController: SpeedControlManager

    init(
        id: UUID = UUID(),
        pid: pid_t,
        appURL: URL,
        appName: String,
        launchedAt: Date = Date(),
        isRunning: Bool = true,
        currentSpeed: Double = 1.0,
        isSpeedControlEnabled: Bool = false,
        isSharedMemoryConnected: Bool = false,
        speedController: SpeedControlManager? = nil
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
        self.speedController = speedController ?? SpeedControlManager(pid: pid)
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
    private var isSetup: Bool = false

    private init() {
        logDebug("AppLauncher initialized", log: .launcher)
    }

    func setup() {
        guard !isSetup else { return }
        isSetup = true

        processObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleProcessTermination(notification)
        }

        logInfo("AppLauncher setup complete", log: .launcher)
    }

    deinit {
        if let observer = processObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func getDylibPath() -> Result<String, AppLauncherError> {
        logDebug("Searching for SpeedPatch.dylib...", log: .launcher)

        let bundleURL = Bundle.main.bundleURL

        var candidatePaths: [String] = [
            bundleURL.appendingPathComponent("Contents/PlugIns/SpeedPatch.dylib").path,
            bundleURL.appendingPathComponent("Contents/Frameworks/SpeedPatch.dylib").path,
            bundleURL.appendingPathComponent("SpeedPatch.dylib").path
        ]

        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidatePaths.append(executableDir.appendingPathComponent("SpeedPatch.dylib").path)
        }

        if let plistSearchPath = Bundle.main.object(forInfoDictionaryKey: "DylibSearchPath") as? String {
            let customURL = URL(fileURLWithPath: plistSearchPath).appendingPathComponent("SpeedPatch.dylib")
            candidatePaths.append(customURL.path)
        }

        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                logInfo("Found SpeedPatch.dylib: \(path)", log: .launcher)
                return .success(path)
            }
        }

        logError("SpeedPatch.dylib not found", log: .launcher)
        logDebug("Searched paths: \(candidatePaths.joined(separator: ", "))", log: .launcher)
        return .failure(.dylibNotFound)
    }

    func launchApp(at url: URL) -> Result<LaunchedProcess, AppLauncherError> {
        return launchQueue.sync {
            logDebug("Preparing to launch app: \(url.path)", log: .launcher)

            guard FileManager.default.fileExists(atPath: url.path) else {
                logError("App not found: \(url.path)", log: .launcher)
                return .failure(.appNotFound)
            }

            let dylibPath: String
            switch getDylibPath() {
            case .success(let p): dylibPath = p
            case .failure(let err): return .failure(err)
            }

            let appName = url.deletingPathExtension().lastPathComponent
            logDebug("App name: \(appName)", log: .launcher)

            let config = NSWorkspace.OpenConfiguration()
            config.environment = [
                "DYLD_INSERT_LIBRARIES": dylibPath,
                "DYLD_FORCE_FLAT_NAMESPACE": "1"
            ]

            logDebug("DYLD_INSERT_LIBRARIES = \(dylibPath)", log: .launcher)

            var launchError: Error?
            var launchedPID: pid_t = -1

            let semaphore = DispatchSemaphore(value: 0)

            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error = error {
                    launchError = error
                    logError("Launch failed: \(error.localizedDescription)", log: .launcher)
                } else if let app = app {
                    launchedPID = app.processIdentifier
                    logInfo("App launched successfully, PID: \(launchedPID)", log: .launcher)
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
            logDebug("Recorded launched process: \(appName) (PID: \(launchedPID))", log: .launcher)

            return .success(process)
        }
    }

    func launchApp(withBundleIdentifier bundleId: String) -> Result<LaunchedProcess, AppLauncherError> {
        logDebug("Launching app by bundle ID: \(bundleId)", log: .launcher)

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            logError("No app found for bundle ID: \(bundleId)", log: .launcher)
            return .failure(.appNotFound)
        }

        return launchApp(at: appURL)
    }
    
    func launchExecutable(at url: URL) -> Result<LaunchedProcess, AppLauncherError> {
        return launchQueue.sync {
            logDebug("Preparing to launch executable: \(url.path)", log: .launcher)

            guard FileManager.default.fileExists(atPath: url.path) else {
                logError("Executable not found: \(url.path)", log: .launcher)
                return .failure(.appNotFound)
            }

            let dylibPath: String
            switch getDylibPath() {
            case .success(let p): dylibPath = p
            case .failure(let err): return .failure(err)
            }

            let appName = url.lastPathComponent
            logDebug("Executable name: \(appName)", log: .launcher)

            let process = Process()
            process.executableURL = url
            process.environment = [
                "DYLD_INSERT_LIBRARIES": dylibPath,
                "DYLD_FORCE_FLAT_NAMESPACE": "1"
            ]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let launchedPID = process.processIdentifier
                logInfo("Executable launched successfully, PID: \(launchedPID)", log: .launcher)

                let launchedProcess = LaunchedProcess(
                    pid: launchedPID,
                    appURL: url,
                    appName: appName
                )

                launchedProcesses.append(launchedProcess)
                logDebug("Recorded launched executable: \(appName) (PID: \(launchedPID))", log: .launcher)

                return .success(launchedProcess)
            } catch {
                logError("Failed to launch executable: \(error.localizedDescription)", log: .launcher)
                return .failure(.launchFailed(error.localizedDescription))
            }
        }
    }

    func terminateProcess(_ process: LaunchedProcess) -> Result<Void, AppLauncherError> {
        return launchQueue.sync {
            logDebug("Terminating process: \(process.appName) (PID: \(process.pid))", log: .launcher)

            guard let runningApp = NSWorkspace.shared.runningApplications.first(
                where: { $0.processIdentifier == process.pid }
            ) else {
                logError("Process not running: \(process.pid)", log: .launcher)
                updateProcessStatus(pid: process.pid, isRunning: false)
                return .failure(.processNotFound)
            }

            runningApp.terminate()
            updateProcessStatus(pid: process.pid, isRunning: false)
            logInfo("Terminate signal sent", log: .launcher)

            return .success(())
        }
    }

    func forceTerminateProcess(_ process: LaunchedProcess) -> Result<Void, AppLauncherError> {
        return launchQueue.sync {
            logDebug("Force terminating process: \(process.appName) (PID: \(process.pid))", log: .launcher)

            guard let runningApp = NSWorkspace.shared.runningApplications.first(
                where: { $0.processIdentifier == process.pid }
            ) else {
                logError("Process not running: \(process.pid)", log: .launcher)
                updateProcessStatus(pid: process.pid, isRunning: false)
                return .failure(.processNotFound)
            }

            runningApp.forceTerminate()
            updateProcessStatus(pid: process.pid, isRunning: false)
            logInfo("Force terminate signal sent", log: .launcher)

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

        logDebug("Detected process termination: \(appName) (PID: \(terminatedPID))", log: .launcher)

        launchQueue.async { [weak self] in
            self?.updateProcessStatus(pid: terminatedPID, isRunning: false)
        }
    }

    func removeProcess(_ process: LaunchedProcess) {
        launchQueue.async { [weak self] in
            self?.launchedProcesses.removeAll { $0.id == process.id }
            logDebug("Removed process record: \(process.appName)", log: .launcher)
        }
    }

    func clearTerminatedProcesses() {
        launchQueue.async { [weak self] in
            guard let self = self else { return }
            let beforeCount = self.launchedProcesses.count
            self.launchedProcesses.removeAll { !$0.isRunning }
            let removedCount = beforeCount - self.launchedProcesses.count
            logDebug("Cleared \(removedCount) terminated process records", log: .launcher)
        }
    }
}
