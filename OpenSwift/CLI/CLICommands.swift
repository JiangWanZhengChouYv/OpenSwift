import Foundation
import AppKit

/// CLI 命令实现
/// 实现 dylib 路径定位、DYLD 启动/重启、进程查找与终止、智能模式、速度控制、退出清理等核心逻辑

// MARK: - 共享内存布局常量

/// 共享内存布局（与 SpeedPatch/speedpatch.h 和 OpenSwift/Services/SpeedControlManager.swift 完全一致）
///
/// 布局:
///   Offset 0-3:   magic (uint32_t, 4 bytes)              - 魔术数字 0x5350444D
///   Offset 4-7:   version (uint32_t, 4 bytes)            - 协议版本
///   Offset 8-11:  owner_pid (uint32_t, 4 bytes)          - 创建者 PID
///   Offset 12-15: speed_ratio (float, 4 bytes)           - 速度倍率
///   Offset 16:    is_active (uint8_t, 1 byte)            - 是否启用
///   Offset 17-23: padding (7 bytes)                      - 对齐填充
///   Offset 24-31: timestamp (uint64_t, 8 bytes)          - 最后修改时间戳
///   Offset 32-71: reserved (40 bytes)                    - 预留
///   总大小: 72 bytes; 共享内存大小: 4096 bytes
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

/// 共享内存 key 前缀
let sharedMemoryKeyPrefix = "com.openswift.speedpatch."

/// 速度倍率范围
let minSpeedRatio: Float = 0.1
let maxSpeedRatio: Float = 10.0
let defaultSpeedRatio: Float = 1.0

// MARK: - POSIX shm 变参函数声明

// shm_open/shm_unlink 在 POSIX 中被声明为变参函数，Swift 标记为 unavailable。
// 通过 @_silgen_name 重新声明为非变参形式，使 Swift 可以正确链接。
@_silgen_name("shm_open")
func shm_open(_ name: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32

@_silgen_name("shm_unlink")
func shm_unlink(_ name: UnsafePointer<CChar>!) -> Int32

// MARK: - Dylib 路径定位

/// 定位 SpeedPatch.dylib 路径
///
/// 定位顺序：
/// 1. 环境变量 OPENSWIFT_DYLIB_PATH 指定的路径（如果是目录，查找其中的 SpeedPatch.dylib）
/// 2. 与 CLI 可执行文件同级的 PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch
/// 3. 与 CLI 可执行文件同级的 PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch
/// 4. CLI 同级目录下的 OpenSwift.app 内嵌 dylib（用于 CLI 与 .app 共存的部署场景）
/// 5. 当前工作目录下的 SpeedPatch.dylib
/// 6. 当前工作目录下 OpenSwift.app 内嵌 dylib
/// 7. 找不到则返回 nil
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

    // 4. CLI 同级目录下的 OpenSwift.app 内嵌 dylib
    let path4 = (cliDir as NSString)
        .appendingPathComponent("OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch")
    if fileManager.fileExists(atPath: path4) {
        return path4
    }

    // 5. 当前工作目录下的 SpeedPatch.dylib
    let cwd = fileManager.currentDirectoryPath
    let path5 = (cwd as NSString).appendingPathComponent("SpeedPatch.dylib")
    if fileManager.fileExists(atPath: path5) {
        return path5
    }

    // 6. 当前工作目录下 OpenSwift.app 内嵌 dylib
    let path6 = (cwd as NSString)
        .appendingPathComponent("OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch")
    if fileManager.fileExists(atPath: path6) {
        return path6
    }

    // 7. 找不到
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

// MARK: - 速度控制

/// 打开目标 PID 的共享内存（已存在的，不创建）
///
/// - Parameter pid: 目标进程 PID
/// - Returns: (fd, pointer)，失败返回 nil
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

/// 设置目标进程的加速倍率
///
/// 通过共享内存向目标进程写入 speed_ratio 和 is_active=1
///
/// - Parameters:
///   - pid: 目标进程 PID
///   - ratio: 速度倍率（自动截断到 [0.1, 10.0]）
/// - Returns: 状态码（0 成功，1 失败）
func setSpeed(pid: pid_t, ratio: Float) -> Int32 {
    // 1. 截断速度倍率到合法范围
    var clampedRatio = ratio
    if clampedRatio < minSpeedRatio {
        print("警告：速度倍率 \(ratio) 低于最小值 \(minSpeedRatio)，已截断")
        clampedRatio = minSpeedRatio
    } else if clampedRatio > maxSpeedRatio {
        print("警告：速度倍率 \(ratio) 超过最大值 \(maxSpeedRatio)，已截断")
        clampedRatio = maxSpeedRatio
    }

    // 2. 打开共享内存
    guard let (fd, pointer) = openSharedMemory(pid: pid) else {
        writeError("错误：找不到进程 \(pid) 的共享内存（进程可能未启动或未注入 SpeedPatch）")
        return 1
    }

    defer {
        closeSharedMemory(fd: fd, pointer: pointer)
    }

    // 3. 校验 magic 和 version
    let magic = pointer.load(fromByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
    let version = pointer.load(fromByteOffset: SharedMemoryLayout.offsetVersion, as: UInt32.self)
    if magic != SharedMemoryLayout.magicNumber {
        writeError("错误：共享内存 magic 不匹配（期望 0x\(String(format: "%08X", SharedMemoryLayout.magicNumber))，实际 0x\(String(format: "%08X", magic))）")
        return 1
    }
    if version < 2 {
        writeError("错误：共享内存版本不兼容（\(version)），需要 >= 2")
        return 1
    }

    // 4. 写入 speed_ratio 和 is_active=1
    pointer.storeBytes(of: clampedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
    pointer.storeBytes(of: UInt8(1), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
    pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)

    // 5. msync 确保写入对目标进程可见
    msync(pointer, SharedMemoryLayout.size, MS_SYNC)

    print("已设置进程 \(pid) 的加速倍率为 \(clampedRatio)x（已启用）")
    return 0
}

// MARK: - 退出清理

/// 复位目标进程的速度并清理共享内存
///
/// 写入 is_active=0、speed_ratio=1.0，然后调用 shm_unlink 删除共享内存对象
///
/// - Parameter pid: 目标进程 PID
/// - Returns: 状态码（始终返回 0，幂等）
func quitAndCleanup(pid: pid_t) -> Int32 {
    let key = sharedMemoryKeyPrefix + String(pid)

    // 1. 尝试打开共享内存
    guard let (fd, pointer) = openSharedMemory(pid: pid) else {
        // 共享内存不存在，视为已清理（幂等）
        print("进程 \(pid) 的共享内存不存在或已清理")
        return 0
    }

    defer {
        closeSharedMemory(fd: fd, pointer: pointer)
    }

    // 2. 校验 magic（避免误操作）
    let magic = pointer.load(fromByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
    if magic != SharedMemoryLayout.magicNumber {
        writeError("警告：共享内存 magic 不匹配（0x\(String(format: "%08X", magic))），仍尝试清理")
    }

    // 3. 写入 is_active=0 和 speed_ratio=1.0 复位
    pointer.storeBytes(of: defaultSpeedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
    pointer.storeBytes(of: UInt8(0), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
    pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)

    // 4. msync 确保写入对目标进程可见
    msync(pointer, SharedMemoryLayout.size, MS_SYNC)

    // 5. 调用 shm_unlink 删除共享内存对象
    //    注意：shm_unlink 只删除名字，实际内存对象在有进程持有 fd 期间不会被释放
    //    但后续的 shm_open 将无法再打开此名字
    let unlinkResult = key.withCString { cKey in
        shm_unlink(cKey)
    }

    if unlinkResult == -1 && errno != ENOENT {
        writeError("警告：shm_unlink 失败：\(String(cString: strerror(errno)))")
    }

    print("已清理进程 \(pid) 的共享内存（速度复位为 1.0x，加速已禁用）")
    return 0
}
