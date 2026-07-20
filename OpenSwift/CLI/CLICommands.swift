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

@_silgen_name("shm_open")
func shm_open(_ name: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32

@_silgen_name("shm_unlink")
func shm_unlink(_ name: UnsafePointer<CChar>!) -> Int32

func findDylibPath() -> String? {
    let fileManager = FileManager.default

    if let envPath = ProcessInfo.processInfo.environment["OPENSWIFT_DYLIB_PATH"] {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: envPath, isDirectory: &isDir) {
            if isDir.boolValue {
                let candidateInDir = (envPath as NSString).appendingPathComponent("SpeedPatch.dylib")
                if fileManager.fileExists(atPath: candidateInDir) {
                    return candidateInDir
                }
            } else {
                return envPath
            }
        }
    }

    let cliDir = Bundle.main.bundleURL.path

    let path2 = (cliDir as NSString)
        .appendingPathComponent("PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch")
    if fileManager.fileExists(atPath: path2) {
        return path2
    }

    let path3 = (cliDir as NSString)
        .appendingPathComponent("PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch")
    if fileManager.fileExists(atPath: path3) {
        return path3
    }

    let path4 = (cliDir as NSString)
        .appendingPathComponent("OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch")
    if fileManager.fileExists(atPath: path4) {
        return path4
    }

    let cwd = fileManager.currentDirectoryPath
    let path5 = (cwd as NSString).appendingPathComponent("SpeedPatch.dylib")
    if fileManager.fileExists(atPath: path5) {
        return path5
    }

    let path6 = (cwd as NSString)
        .appendingPathComponent("OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch")
    if fileManager.fileExists(atPath: path6) {
        return path6
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

// MARK: - 速度控制

private func openSharedMemory(pid: pid_t) -> (fd: Int32, pointer: UnsafeMutableRawPointer)? {
    let key = sharedMemoryKeyPrefix + String(pid)

    // O_RDWR 打开已存在的共享内存（不创建）
    let fd = key.withCString { cKey in
        shm_open(cKey, O_RDWR, 0)
    }

    if fd == -1 {
        return nil
    }

    // 映射共享内存（mmap 返回 UnsafeMutableRawPointer?，MAP_FAILED 是非 nil 失败标记）
    let mapped = mmap(nil,
                      SharedMemoryLayout.size,
                      PROT_READ | PROT_WRITE,
                      MAP_SHARED,
                      fd,
                      0)

    guard let pointer = mapped, pointer != MAP_FAILED else {
        close(fd)
        return nil
    }

    return (fd, pointer)
}

/// 关闭共享内存映射
private func closeSharedMemory(fd: Int32, pointer: UnsafeMutableRawPointer) {
    msync(pointer, SharedMemoryLayout.size, MS_SYNC)
    munmap(pointer, SharedMemoryLayout.size)
    close(fd)
}

func setSpeed(pid: pid_t, ratio: Float) -> Int32 {
    var clampedRatio = ratio
    if clampedRatio < minSpeedRatio {
        print("警告：速度倍率 \(ratio) 低于最小值 \(minSpeedRatio)，已截断")
        clampedRatio = minSpeedRatio
    } else if clampedRatio > maxSpeedRatio {
        print("警告：速度倍率 \(ratio) 超过最大值 \(maxSpeedRatio)，已截断")
        clampedRatio = maxSpeedRatio
    }

    guard let (fd, pointer) = openSharedMemory(pid: pid) else {
        writeError("错误：找不到进程 \(pid) 的共享内存")
        return 1
    }

    defer {
        closeSharedMemory(fd: fd, pointer: pointer)
    }

    let magic = pointer.load(fromByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
    let version = pointer.load(fromByteOffset: SharedMemoryLayout.offsetVersion, as: UInt32.self)
    if magic != SharedMemoryLayout.magicNumber {
        let expected = String(format: "%08X", SharedMemoryLayout.magicNumber)
        let actual = String(format: "%08X", magic)
        writeError("错误：共享内存 magic 不匹配（期望 0x\(expected)，实际 0x\(actual)）")
        return 1
    }
    if version < 2 {
        writeError("错误：共享内存版本不兼容（\(version)），需要 >= 2")
        return 1
    }

    pointer.storeBytes(of: clampedRatio,
                       toByteOffset: SharedMemoryLayout.offsetSpeedRatio,
                       as: Float32.self)
    pointer.storeBytes(of: UInt8(1),
                       toByteOffset: SharedMemoryLayout.offsetIsActive,
                       as: UInt8.self)
    let now = UInt64(Date().timeIntervalSince1970)
    pointer.storeBytes(of: now,
                       toByteOffset: SharedMemoryLayout.offsetTimestamp,
                       as: UInt64.self)
    msync(pointer, SharedMemoryLayout.size, MS_SYNC)

    print("已设置进程 \(pid) 的加速倍率为 \(clampedRatio)x（已启用）")
    return 0
}

// MARK: - 退出清理

func quitAndCleanup(pid: pid_t) -> Int32 {
    let key = sharedMemoryKeyPrefix + String(pid)

    guard let (fd, pointer) = openSharedMemory(pid: pid) else {
        print("进程 \(pid) 的共享内存不存在或已清理")
        return 0
    }

    defer {
        closeSharedMemory(fd: fd, pointer: pointer)
    }

    let magic = pointer.load(fromByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
    if magic != SharedMemoryLayout.magicNumber {
        let magicHex = String(format: "%08X", magic)
        writeError("警告：共享内存 magic 不匹配（0x\(magicHex)），仍尝试清理")
    }

    pointer.storeBytes(of: defaultSpeedRatio,
                       toByteOffset: SharedMemoryLayout.offsetSpeedRatio,
                       as: Float32.self)
    pointer.storeBytes(of: UInt8(0),
                       toByteOffset: SharedMemoryLayout.offsetIsActive,
                       as: UInt8.self)
    let timestamp = UInt64(Date().timeIntervalSince1970)
    pointer.storeBytes(of: timestamp,
                       toByteOffset: SharedMemoryLayout.offsetTimestamp,
                       as: UInt64.self)
    msync(pointer, SharedMemoryLayout.size, MS_SYNC)

    let unlinkResult = key.withCString { cKey in
        shm_unlink(cKey)
    }

    if unlinkResult == -1 && errno != ENOENT {
        writeError("警告：shm_unlink 失败：\(String(cString: strerror(errno)))")
    }

    print("已清理进程 \(pid) 的共享内存（速度复位为 1.0x，加速已禁用）")
    return 0
}
