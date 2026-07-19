import Foundation
import AppKit

/// CLI 命令实现
/// 实现 dylib 路径定位、DYLD 启动/重启、进程查找与终止、智能模式等核心逻辑

// MARK: - Dylib 路径定位

/// 定位 SpeedPatch.dylib 路径
///
/// 定位顺序：
/// 1. 环境变量 OPENSWIFT_DYLIB_PATH 指定的路径（如果是目录，查找其中的 SpeedPatch.dylib）
/// 2. 与 CLI 可执行文件同级的 PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch
/// 3. 与 CLI 可执行文件同级的 PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch
/// 4. 当前工作目录下的 SpeedPatch.dylib
/// 5. 找不到则返回 nil
///
/// - Returns: 找到的 dylib 路径，找不到返回 nil
func findDylibPath() -> String? {
    let fileManager = FileManager.default

    // 1. 环境变量 OPENSWIFT_DYLIB_PATH
    if let envPath = ProcessInfo.processInfo.environment["OPENSWIFT_DYLIB_PATH"] {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: envPath, isDirectory: &isDir) {
            if isDir.boolValue {
                // 是目录，查找其中的 SpeedPatch.dylib
                let candidateInDir = (envPath as NSString).appendingPathComponent("SpeedPatch.dylib")
                if fileManager.fileExists(atPath: candidateInDir) {
                    return candidateInDir
                }
            } else {
                // 是文件，直接使用
                return envPath
            }
        }
    }

    // 对于 CLI 工具，Bundle.main.bundleURL 就是可执行文件所在目录
    let cliDir = Bundle.main.bundleURL.path

    // 2. PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch
    let path2 = (cliDir as NSString)
        .appendingPathComponent("PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch")
    if fileManager.fileExists(atPath: path2) {
        return path2
    }

    // 3. PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch
    let path3 = (cliDir as NSString)
        .appendingPathComponent("PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch")
    if fileManager.fileExists(atPath: path3) {
        return path3
    }

    // 4. 当前工作目录下的 SpeedPatch.dylib
    let cwd = fileManager.currentDirectoryPath
    let path4 = (cwd as NSString).appendingPathComponent("SpeedPatch.dylib")
    if fileManager.fileExists(atPath: path4) {
        return path4
    }

    // 5. 找不到
    return nil
}

// MARK: - DYLD 启动

/// 以 DYLD 注入方式启动目标应用或可执行文件
///
/// - Parameter path: 目标 .app 目录或可执行文件路径
/// - Returns: 状态码（0 成功，非 0 失败）
func launchWithDYLD(at path: String) -> Int32 {
    let fileManager = FileManager.default

    // 1. 检查路径是否存在
    guard fileManager.fileExists(atPath: path) else {
        writeError("错误：路径不存在 - \(path)")
        return 1
    }

    // 2. 查找 dylib 路径
    guard let dylibPath = findDylibPath() else {
        writeError("错误：找不到 SpeedPatch.dylib")
        return 1
    }

    // 判断是否为 .app 路径
    let url = URL(fileURLWithPath: path)
    let isApp = url.pathExtension == "app"

    // 准备环境变量
    let environment: [String: String] = [
        "DYLD_INSERT_LIBRARIES": dylibPath,
        "DYLD_FORCE_FLAT_NAMESPACE": "1"
    ]

    if isApp {
        // 3a. .app 路径：使用 NSWorkspace.shared.openApplication
        let appURL = URL(fileURLWithPath: path)
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

        // 等待启动完成，最多 10 秒
        _ = semaphore.wait(timeout: .now() + 10)

        // 4. 检查启动结果
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
    } else {
        // 3b. 非 .app 可执行文件：使用 Process
        let process = Process()
        process.executableURL = url
        process.environment = environment
        // 不捕获标准输出，让目标进程的输出直接显示

        do {
            try process.run()
            // 4. 启动成功，输出 PID
            let launchedPID = process.processIdentifier
            print("已启动进程，PID: \(launchedPID)")
            return 0
        } catch {
            // 5. 启动失败
            writeError("错误：启动失败 - \(error.localizedDescription)")
            return 1
        }
    }
}

// MARK: - 进程查找

/// 查找同路径的运行中进程
///
/// - Parameter path: 目标路径
/// - Returns: 找到的 PID，找不到返回 nil
func findRunningProcess(at path: String) -> pid_t? {
    // 1. 将输入路径转为绝对路径
    let absolutePath = URL(fileURLWithPath: path).standardizedFileURL.path
    let url = URL(fileURLWithPath: absolutePath)
    let isApp = url.pathExtension == "app"

    if isApp {
        // 3. 对于 .app：比较 executableURL 或 bundleURL 的路径
        let targetURL = url.standardizedFileURL

        for app in NSWorkspace.shared.runningApplications {
            // 比较 bundleURL
            if let bundleURL = app.bundleURL,
               bundleURL.standardizedFileURL == targetURL {
                let pid = app.processIdentifier
                if pid > 0 {
                    return pid
                }
            }
            // 比较 executableURL（可执行文件位于 .app 内部）
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
    } else {
        // 4. 对于可执行文件：使用 pgrep -f <path> 查找
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", absolutePath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // 静默 stderr

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // 5. 取第一行作为 PID
            if let firstLine = output.split(separator: "\n").first {
                let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = pid_t(trimmed) {
                    // 排除 pgrep 自身的 PID（虽然 pgrep 通常会自动排除，但保险起见）
                    if pid != process.processIdentifier {
                        return pid
                    }
                }
            }
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - 终止进程

/// 终止指定进程
///
/// - Parameter pid: 进程 ID
/// - Returns: 是否成功终止
func terminateProcess(pid: pid_t) -> Bool {
    // 1. 发送 SIGTERM 终止信号
    _ = kill(pid, SIGTERM)

    // 2. 等待最多 3 秒让进程退出（轮询检查 kill(pid, 0) 是否返回 -1）
    let deadline = Date().addingTimeInterval(3.0)
    while Date() < deadline {
        if kill(pid, 0) == -1 {
            // 进程已退出
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    // 3. 3 秒后仍存活，使用 SIGKILL 强制终止
    let sigkillResult = kill(pid, SIGKILL)
    if sigkillResult == -1 && errno == ESRCH {
        // 进程已不存在
        return true
    }

    // 等待一小段时间确认 SIGKILL 生效
    Thread.sleep(forTimeInterval: 0.2)

    // 4. 返回是否成功终止
    return kill(pid, 0) == -1
}

// MARK: - DYLD 重启

/// 以 DYLD 注入方式重启目标
///
/// - Parameter path: 目标路径
/// - Returns: 状态码
func restartWithDYLD(at path: String) -> Int32 {
    // 1. 查找已运行的同路径进程
    if let pid = findRunningProcess(at: path) {
        // 2. 如果找到，终止该进程
        if !terminateProcess(pid: pid) {
            writeError("警告：无法终止进程 PID: \(pid)，继续尝试启动...")
        }
        // 3. 等待 0.5 秒让系统清理
        Thread.sleep(forTimeInterval: 0.5)
    }

    // 4. 调用 launchWithDYLD 启动
    // 5. 返回启动结果的状态码
    return launchWithDYLD(at: path)
}

// MARK: - 智能模式

/// 智能模式：已运行则重启，否则直接启动
///
/// - Parameter path: 目标路径
/// - Returns: 状态码
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
