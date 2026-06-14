import Foundation

// shm_open/shm_unlink 在 POSIX 中被声明为变参函数（第三参仅 O_CREAT 时使用），
// Swift 将 C 的变参声明标记为 unavailable。这里通过 @_silgen_name 重新声明为
// 非变参形式，使 Swift 可以正确链接到 libc 的 shm_open/shm_unlink 符号。
@_silgen_name("shm_open")
func shm_open(_ name: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32

@_silgen_name("shm_unlink")
func shm_unlink(_ name: UnsafePointer<CChar>!) -> Int32

// MARK: - 共享内存字段偏移常量 (与 C 端 SharedMemoryHeader 完全一致)
//
// 布局:
//   Offset 0-3:   magic (uint32_t, 4 bytes)              - 魔术数字，验证共享内存有效性
//   Offset 4-7:   version (uint32_t, 4 bytes)             - 协议版本
//   Offset 8-11:  owner_pid (uint32_t, 4 bytes)           - 创建者 PID
//   Offset 12-15: speed_ratio (float, 4 bytes)            - 速度倍率
//   Offset 16:    is_active (uint8_t, 1 byte)             - 是否启用
//   Offset 17-23: padding (7 bytes)                       - 对齐填充
//   Offset 24-31: timestamp (uint64_t, 8 bytes)           - 最后修改时间戳
//   Offset 32-71: reserved (40 bytes)                     - 预留
//   总大小: 72 bytes; 共享内存大小: 4096 bytes
//
// 重要: speed_ratio (4 bytes) 和 is_active (1 byte) 都是自然对齐的，
//       在现代 CPU 上单字节和 4 字节的读写是原子操作，因此不需要跨进程锁。
//       Swift 端和 C 端都可以直接无锁读写这些字段。
enum SharedMemoryLayout {
    static let size = 4096
    static let headerSize = 72
    
    static let offsetMagic = 0       // UInt32
    static let offsetVersion = 4     // UInt32
    static let offsetOwnerPID = 8    // UInt32
    static let offsetSpeedRatio = 12 // Float32
    static let offsetIsActive = 16   // UInt8
    static let offsetTimestamp = 24  // UInt64
    
    static let currentVersion: UInt32 = 2
    static let minVersion: UInt32 = 2
    static let minMagic: UInt32 = 0x5350444D // "SPDM"
    static let magicNumber: UInt32 = 0x5350444D // "SPDM"
}

// MARK: - 共享内存管理器
//
// 每个被注入的进程持有独立的 SpeedControlManager 实例（不再是全局单例）。
// 这样可以同时对多个进程保持独立的加速/减速上下文，并且切换 UI 选择时
// 不需要重新 open/map 共享内存。
//
// 线程安全：所有对共享内存指针的读写通过一个实例内部串行队列完成。
// SwiftUI 对 @Published 的赋值和订阅在主线程发生；SpeedControlManager 的
// 外部调用者如果在非主线程，会被队列同步序列化。

class SpeedControlManager {

    private let sharedMemoryKeyPrefix = "com.openswift.speedpatch."
    private var targetPID: pid_t = 0
    private var sharedMemoryPointer: UnsafeMutableRawPointer?
    private var sharedMemoryFD: Int32 = -1

    private let minSpeedRatio: Float = 0.1
    private let maxSpeedRatio: Float = 10.0
    private let defaultSpeedRatio: Float = 1.0

    private let ioQueue: DispatchQueue

    var isConnected: Bool {
        return ioQueue.sync { sharedMemoryPointer != nil && sharedMemoryFD != -1 }
    }

    init(pid: pid_t) {
        self.targetPID = pid
        self.ioQueue = DispatchQueue(
            label: "com.openswift.speedcontrol.\(pid)",
            qos: .userInitiated
        )
    }

    // MARK: - 进程连接

    func attachToProcess(pid: pid_t) -> Bool {
        return ioQueue.sync {
            // 如果已经连接到同一个进程，不做任何操作
            if targetPID == pid && sharedMemoryPointer != nil && sharedMemoryFD != -1 {
                logDebug("Already attached to process \(pid)", log: .speed)
                return true
            }

            // 只有连接到不同进程时才断开（但不删除共享内存，因为目标进程可能仍在运行）
            if targetPID != 0 && targetPID != pid {
                detachSilentlyInternal()
            }

            targetPID = pid

            let key = sharedMemoryKeyPrefix + String(targetPID)

            // 权限: 0600 - 仅所有者可读可写 (与 C 端保持一致)
            let shmMode = S_IRUSR | S_IWUSR

            var isNewlyCreated = false

            // 先尝试打开已存在的共享内存（由注入的进程创建）
            sharedMemoryFD = key.withCString { cKey in
                shm_open(cKey, O_RDWR, shmMode)
            }

            if sharedMemoryFD == -1 {
                logDebug("Shared memory not found for PID \(pid), creating it (mode=0600): \(String(cString: strerror(errno)))", log: .speed)
                sharedMemoryFD = key.withCString { cKey in
                    shm_open(cKey, O_CREAT | O_RDWR, shmMode)
                }

                if sharedMemoryFD == -1 {
                    logError("Failed to create shared memory for PID \(pid): \(String(cString: strerror(errno)))", log: .speed)
                    return false
                }

                // 设置共享内存大小
                if ftruncate(sharedMemoryFD, off_t(SharedMemoryLayout.size)) == -1 {
                    logError("Failed to set shared memory size: \(String(cString: strerror(errno)))", log: .speed)
                    close(sharedMemoryFD)
                    sharedMemoryFD = -1
                    return false
                }

                isNewlyCreated = true
            }

            // 映射共享内存
            sharedMemoryPointer = mmap(nil,
                                       SharedMemoryLayout.size,
                                       PROT_READ | PROT_WRITE,
                                       MAP_SHARED,
                                       sharedMemoryFD,
                                       0)

            if sharedMemoryPointer == MAP_FAILED {
                logError("Failed to map shared memory: \(String(cString: strerror(errno)))", log: .speed)
                close(sharedMemoryFD)
                sharedMemoryFD = -1
                return false
            }

            // 校验共享内存的 magic / version
            if let pointer = sharedMemoryPointer {
                let magic = pointer.load(fromByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
                let version = pointer.load(fromByteOffset: SharedMemoryLayout.offsetVersion, as: UInt32.self)

                if isNewlyCreated {
                    logDebug("Shared memory newly created (magic=0x\(String(format: "%08X", magic))), initializing header...", log: .speed)
                    initializeSharedMemoryInternal()
                } else {
                    if magic != SharedMemoryLayout.minMagic || version < SharedMemoryLayout.minVersion {
                        logError("Existing shared memory has invalid magic/version (magic=0x\(String(format: "%08X", magic)), version=\(version)). Expected magic=0x\(String(format: "%08X", SharedMemoryLayout.minMagic)), version >= \(SharedMemoryLayout.minVersion). The injected dylib may be outdated or incompatible.", log: .speed)
                        munmap(pointer, SharedMemoryLayout.size)
                        sharedMemoryPointer = nil
                        close(sharedMemoryFD)
                        sharedMemoryFD = -1
                        targetPID = 0
                        return false
                    }
                    logInfo("Connected to existing shared memory (magic=0x\(String(format: "%08X", magic)), version=\(version))", log: .speed)
                }
            }

            logInfo("Attached to process \(targetPID)", log: .speed)
            return true
        }
    }

    /// 静默断开连接：只 munmap 和 close，不删除共享内存
    /// 用于切换进程或临时断开，目标进程可能仍在运行
    func detachSilently() {
        ioQueue.sync {
            detachSilentlyInternal()
        }
    }

    /// 完全断开并清理：只有在确定目标进程已终止时调用
    func detachAndCleanup() {
        ioQueue.sync {
            let pidToClean = targetPID

            if let pointer = sharedMemoryPointer {
                munmap(pointer, SharedMemoryLayout.size)
                sharedMemoryPointer = nil
            }

            if sharedMemoryFD != -1 {
                close(sharedMemoryFD)
                sharedMemoryFD = -1
            }

            // 删除共享内存对象（进程已终止时才调用）
            if pidToClean > 0 {
                let key = sharedMemoryKeyPrefix + String(pidToClean)
                _ = key.withCString { cKey in
                    shm_unlink(cKey)
                }
                logDebug("Shared memory unlinked for PID \(pidToClean)", log: .speed)
            }

            targetPID = 0
            logDebug("Detached and cleaned up", log: .speed)
        }
    }

    /// 向后兼容的 detach（保持 API 不变）
    func detachFromProcess() {
        detachSilently()
    }

    // MARK: - 共享内存初始化（无同步包装，由外部调用者保证在 ioQueue 中）

    private func initializeSharedMemoryInternal() {
        guard let pointer = sharedMemoryPointer else { return }

        memset(pointer, 0, SharedMemoryLayout.headerSize)
        pointer.storeBytes(of: SharedMemoryLayout.magicNumber, toByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
        pointer.storeBytes(of: SharedMemoryLayout.currentVersion, toByteOffset: SharedMemoryLayout.offsetVersion, as: UInt32.self)
        pointer.storeBytes(of: UInt32(targetPID), toByteOffset: SharedMemoryLayout.offsetOwnerPID, as: UInt32.self)
        pointer.storeBytes(of: defaultSpeedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
        pointer.storeBytes(of: UInt8(0), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
        pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)
        msync(pointer, SharedMemoryLayout.size, MS_SYNC)

        logDebug("Shared memory initialized (owner_pid=\(targetPID), magic=0x\(String(format: "%08X", SharedMemoryLayout.magicNumber)))", log: .speed)
    }

    // MARK: - 内部工具（无同步包装，由外部调用者保证在 ioQueue 中）

    private func detachSilentlyInternal() {
        if let pointer = sharedMemoryPointer {
            munmap(pointer, SharedMemoryLayout.size)
            sharedMemoryPointer = nil
        }
        if sharedMemoryFD != -1 {
            close(sharedMemoryFD)
            sharedMemoryFD = -1
        }
        logDebug("Detached silently (shared memory preserved)", log: .speed)
    }

    // MARK: - 速度控制读写 (无锁原子读写)
    //
    // 由于 speed_ratio (Float32, 4 字节) 和 is_active (UInt8, 1 字节)
    // 在现代 CPU 上的单字节/4 字节读写是原子的，只要内存是自然对齐的，
    // 就不需要跨进程锁。Swift 端写，C 端读。
    // msync 确保写入被刷新到共享内存区域，对 C 端可见。

    func setSpeedRatio(_ ratio: Float) -> Bool {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer, sharedMemoryFD != -1 else {
                logError("Not connected, cannot set speed ratio", log: .speed)
                return false
            }

            let clampedRatio = min(max(ratio, minSpeedRatio), maxSpeedRatio)

            let ownerPID = pointer.load(fromByteOffset: SharedMemoryLayout.offsetOwnerPID, as: UInt32.self)
            if ownerPID != 0 && ownerPID != UInt32(targetPID) {
                logDebug("Warning: owner_pid=\(ownerPID) does not match target_pid=\(targetPID)", log: .speed)
            }

            pointer.storeBytes(of: clampedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
            pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)
            msync(pointer, SharedMemoryLayout.size, MS_SYNC)

            logInfo("Speed ratio set to \(clampedRatio) for PID \(targetPID)", log: .speed)
            return true
        }
    }

    func getSpeedRatio() -> Float {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer else {
                return defaultSpeedRatio
            }
            return pointer.load(fromByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
        }
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer, sharedMemoryFD != -1 else {
                logError("Not connected, cannot set enabled", log: .speed)
                return false
            }

            pointer.storeBytes(of: enabled ? UInt8(1) : UInt8(0), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
            pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)
            msync(pointer, SharedMemoryLayout.size, MS_SYNC)

            logInfo("Speed control \(enabled ? "enabled" : "disabled") for PID \(targetPID)", log: .speed)
            return true
        }
    }

    func isEnabled() -> Bool {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer else { return false }
            return pointer.load(fromByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self) != 0
        }
    }

    func setSpeedRatioAndEnabled(ratio: Float, enabled: Bool) -> Bool {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer, sharedMemoryFD != -1 else {
                logError("Not connected, cannot set speed ratio and enabled", log: .speed)
                return false
            }

            let clampedRatio = min(max(ratio, minSpeedRatio), maxSpeedRatio)

            pointer.storeBytes(of: clampedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
            pointer.storeBytes(of: enabled ? UInt8(1) : UInt8(0), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
            pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)
            msync(pointer, SharedMemoryLayout.size, MS_SYNC)

            logInfo("Speed ratio: \(clampedRatio), enabled: \(enabled) for PID \(targetPID)", log: .speed)
            return true
        }
    }

    func syncFromSharedMemory() -> (speedRatio: Float, isEnabled: Bool)? {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer else { return nil }
            let ratio = pointer.load(fromByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
            let isActive = pointer.load(fromByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self) != 0
            return (ratio, isActive)
        }
    }

    deinit {
        ioQueue.sync {
            detachSilentlyInternal()
        }
    }
}
