import Foundation
import AppKit

enum SharedMemoryLayout {
    static let size = 4096
    static let offsetMagic = 0
    static let offsetVersion = 4
    static let offsetOwnerPID = 8
    static let offsetSpeedRatio = 12
    static let offsetIsActive = 16
    static let offsetTimestamp = 24
    static let magicNumber: UInt32 = 0x5350444D
    static let currentVersion: UInt32 = 2
}

let sharedMemoryKeyPrefix = "com.openswift.speedpatch."
let minSpeedRatio: Float = 0.1
let maxSpeedRatio: Float = 10.0
let defaultSpeedRatio: Float = 1.0

func findDylibPath() -> String? {
    if let path = findDylibFromEnvironment() { return path }
    if let path = findDylibFromCLIDirectory() { return path }
    if let path = findDylibFromCurrentDirectory() { return path }
    if let path = findDylibFromCommonPaths() { return path }
    return nil
}

private func findDylibFromEnvironment() -> String? {
    let fileManager = FileManager.default
    guard let envPath = ProcessInfo.processInfo.environment["OPENSWIFT_DYLIB_PATH"] else {
        return nil
    }
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: envPath, isDirectory: &isDir) else {
        return nil
    }
    if isDir.boolValue {
        let candidate = (envPath as NSString).appendingPathComponent("SpeedPatch.dylib")
        return fileManager.fileExists(atPath: candidate) ? candidate : nil
    }
    return envPath
}

private func findDylibFromCLIDirectory() -> String? {
    let fileManager = FileManager.default
    let cliDir = Bundle.main.bundleURL.path
    
    let paths = [
        (cliDir as NSString).appendingPathComponent(
            "PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch"
        ),
        (cliDir as NSString).appendingPathComponent(
            "PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch"
        ),
        (cliDir as NSString).appendingPathComponent(
            "OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch"
        )
    ]
    
    for path in paths {
        if fileManager.fileExists(atPath: path) {
            return path
        }
    }
    return nil
}

private func findDylibFromCurrentDirectory() -> String? {
    let fileManager = FileManager.default
    let cwd = fileManager.currentDirectoryPath
    
    let path1 = (cwd as NSString).appendingPathComponent("SpeedPatch.dylib")
    if fileManager.fileExists(atPath: path1) {
        return path1
    }
    
    let path2 = (cwd as NSString).appendingPathComponent(
        "OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch"
    )
    if fileManager.fileExists(atPath: path2) {
        return path2
    }
    
    return nil
}

private func findDylibFromCommonPaths() -> String? {
    let fileManager = FileManager.default
    let paths = [
        "/Applications/OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch",
        (NSHomeDirectory() as NSString).appendingPathComponent(
            "Applications/OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch"
        )
    ]
    
    for path in paths {
        if fileManager.fileExists(atPath: path) {
            return path
        }
    }
    return nil
}

// MARK: - DYLD 启动

func launchWithDYLD(at path: String) -> Int32 {
    let fileManager = FileManager.default
    
    guard fileManager.fileExists(atPath: path) else {
        writeError("错误：路径不存在 - \(path)")
        return 1
    }

    guard let dylibPath = findDylibPath() else {
        writeError("错误：找不到 SpeedPatch.dylib")
        return 1
    }

    let url = URL(fileURLWithPath: path)
    let environment = buildDYLDEnvironment(dylibPath: dylibPath)

    if url.pathExtension == "app" {
        return launchAppWithDYLD(at: url, environment: environment)
    } else {
        return launchExecutableWithDYLD(at: url, environment: environment)
    }
}

private func buildDYLDEnvironment(dylibPath: String) -> [String: String] {
    return [
        "DYLD_INSERT_LIBRARIES": dylibPath,
        "DYLD_FORCE_FLAT_NAMESPACE": "1"
    ]
}

private func launchAppWithDYLD(at appURL: URL, environment: [String: String]) -> Int32 {
    let config = NSWorkspace.OpenConfiguration()
    config.environment = environment

    var launchError: Error?
    var launchedPID: pid_t = -1
    let semaphore = DispatchSemaphore(value: 0)

    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
        if let error = error {
            launchError = error
        } else if let app = app {
            launchedPID = app.processIdentifier
        }
        semaphore.signal()
    }

    _ = semaphore.wait(timeout: .now() + 10)

    if let error = launchError {
        writeError("错误：启动失败 - \(error.localizedDescription)")
        return 1
    }

    if launchedPID == -1 {
        writeError("错误：无法获取进程 ID")
        return 1
    }

    print("已启动应用，PID: \(launchedPID)")
    return 0
}

private func launchExecutableWithDYLD(at url: URL, environment: [String: String]) -> Int32 {
    let process = Process()
    process.executableURL = url
    process.environment = environment

    do {
        try process.run()
        print("已启动进程，PID: \(process.processIdentifier)")
        return 0
    } catch {
        writeError("错误：启动失败 - \(error.localizedDescription)")
        return 1
    }
}

// MARK: - 进程查找

func findRunningProcess(at path: String) -> pid_t? {
    let absolutePath = URL(fileURLWithPath: path).standardizedFileURL.path
    let url = URL(fileURLWithPath: absolutePath)
    
    if url.pathExtension == "app" {
        return findRunningApp(at: url.standardizedFileURL)
    } else {
        return findRunningExecutable(at: absolutePath)
    }
}

private func findRunningApp(at targetURL: URL) -> pid_t? {
    for app in NSWorkspace.shared.runningApplications {
        if let bundleURL = app.bundleURL,
           bundleURL.standardizedFileURL == targetURL {
            let pid = app.processIdentifier
            if pid > 0 {
                return pid
            }
        }
        
        if let executableURL = app.executableURL {
            let execPath = executableURL.standardizedFileURL.path
            if execPath.hasPrefix(targetURL.path + "/") {
                let pid = app.processIdentifier
                if pid > 0 {
                    return pid
                }
            }
        }
    }
    return nil
}

private func findRunningExecutable(at path: String) -> pid_t? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", path]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if let firstLine = output.split(separator: "\n").first {
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = pid_t(trimmed), pid != process.processIdentifier {
                return pid
            }
        }
        return nil
    } catch {
        return nil
    }
}

// MARK: - 终止进程

func terminateProcess(pid: pid_t) -> Bool {
    _ = kill(pid, SIGTERM)

    let deadline = Date().addingTimeInterval(3.0)
    while Date() < deadline {
        if kill(pid, 0) == -1 {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    let sigkillResult = kill(pid, SIGKILL)
    if sigkillResult == -1 && errno == ESRCH {
        return true
    }

    Thread.sleep(forTimeInterval: 0.2)
    return kill(pid, 0) == -1
}

// MARK: - DYLD 重启

func restartWithDYLD(at path: String) -> Int32 {
    if let pid = findRunningProcess(at: path) {
        if !terminateProcess(pid: pid) {
            writeError("警告：无法终止进程 PID: \(pid)，继续尝试启动...")
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return launchWithDYLD(at: path)
}

// MARK: - 智能模式

func smartMode(at path: String) -> Int32 {
    // 1. 查找已运行的同路径进程
    if findRunningProcess(at: path) != nil {
        // 2. 如果找到，调用 restartWithDYLD
        return restartWithDYLD(at: path)
    } else {
        // 3. 如果没找到，调用 launchWithDYLD
        return launchWithDYLD(at: path)
    }
}
