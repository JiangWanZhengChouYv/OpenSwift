import Foundation

@_silgen_name("swift_shm_open")
func swift_shm_open(_ name: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32

@_silgen_name("swift_shm_unlink")
func swift_shm_unlink(_ name: UnsafePointer<CChar>!) -> Int32

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

class SpeedControlManager {

    private let sharedMemoryKeyPrefix = "com.openswift.speedpatch."
    private var targetPID: pid_t = 0
    private var sharedMemoryPointer: UnsafeMutableRawPointer?
    private var sharedMemoryFD: Int32 = -1

    private let minSpeedRatio: Float = 0.1
    private let maxSpeedRatio: Float = 15.0
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
        var result = false
        ioQueue.sync {
            if targetPID == pid && sharedMemoryPointer != nil && sharedMemoryFD != -1 {
                logDebug("Already attached to process \(pid)", log: .speed)
                result = true
                return
            }

            if targetPID != 0 && targetPID != pid {
                detachSilentlyInternal()
            }

            targetPID = pid

            let key = sharedMemoryKeyPrefix + String(targetPID)
            let shmMode = Int32(S_IRUSR | S_IWUSR)

            guard let fd = openOrCreateSharedMemory(key: key, mode: shmMode, pid: pid) else {
                result = false
                return
            }
            sharedMemoryFD = fd

            guard let pointer = mapSharedMemory(fd: sharedMemoryFD) else {
                close(sharedMemoryFD)
                sharedMemoryFD = -1
                result = false
                return
            }
            sharedMemoryPointer = pointer

            guard validateSharedMemory(isNewlyCreated: isNewlyCreatedSharedMemory) else {
                result = false
                return
            }

            logInfo("Attached to process \(targetPID)", log: .speed)
            result = true
        }
        return result
    }

    private var isNewlyCreatedSharedMemory = false

    private func openOrCreateSharedMemory(key: String, mode: Int32, pid: pid_t) -> Int32? {
        var fd = key.withCString { cKey in
            swift_shm_open(cKey, O_RDWR, mode_t(mode))
        }

        if fd != -1 {
            isNewlyCreatedSharedMemory = false
            return fd
        }

        let errMsg = String(cString: strerror(errno))
        logDebug("Shared memory not found for PID \(pid), creating it (mode=0600): \(errMsg)", log: .speed)

        fd = key.withCString { cKey in
            swift_shm_open(cKey, O_CREAT | O_RDWR, mode_t(mode))
        }

        if fd == -1 {
            let createErr = String(cString: strerror(errno))
            logError("Failed to create shared memory for PID \(pid): \(createErr)", log: .speed)
            return nil
        }

        if ftruncate(fd, off_t(SharedMemoryLayout.size)) == -1 {
            let sizeErr = String(cString: strerror(errno))
            logError("Failed to set shared memory size: \(sizeErr)", log: .speed)
            close(fd)
            return nil
        }

        isNewlyCreatedSharedMemory = true
        return fd
    }

    private func mapSharedMemory(fd: Int32) -> UnsafeMutableRawPointer? {
        let pointer = mmap(
            nil,
            SharedMemoryLayout.size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0
        )

        if pointer == MAP_FAILED {
            logError("Failed to map shared memory: \(String(cString: strerror(errno)))", log: .speed)
            return nil
        }

        return pointer
    }

    private func validateSharedMemory(isNewlyCreated: Bool) -> Bool {
        guard let pointer = sharedMemoryPointer else {
            return false
        }

        let magic = pointer.load(fromByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
        let version = pointer.load(fromByteOffset: SharedMemoryLayout.offsetVersion, as: UInt32.self)

        if isNewlyCreated {
            let magicHex = String(format: "%08X", magic)
            logDebug("Shared memory newly created (magic=0x\(magicHex)), initializing header...", log: .speed)
            initializeSharedMemoryInternal()
            return true
        }

        if magic != SharedMemoryLayout.minMagic || version < SharedMemoryLayout.minVersion {
            let magicHex = String(format: "%08X", magic)
            let expectedMagic = String(format: "%08X", SharedMemoryLayout.minMagic)
            let errorMsg = "Existing shared memory has invalid magic/version " +
                "(magic=0x\(magicHex), version=\(version)). " +
                "Expected magic=0x\(expectedMagic), version >= \(SharedMemoryLayout.minVersion). " +
                "The injected dylib may be outdated or incompatible."
            logError(errorMsg, log: .speed)
            munmap(pointer, SharedMemoryLayout.size)
            sharedMemoryPointer = nil
            close(sharedMemoryFD)
            sharedMemoryFD = -1
            targetPID = 0
            return false
        }

        let magicHex = String(format: "%08X", magic)
        logInfo("Connected to existing shared memory (magic=0x\(magicHex), version=\(version))", log: .speed)
        return true
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
                    swift_shm_unlink(cKey)
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
        pointer.storeBytes(of: SharedMemoryLayout.magicNumber,
                           toByteOffset: SharedMemoryLayout.offsetMagic,
                           as: UInt32.self)
        pointer.storeBytes(of: SharedMemoryLayout.currentVersion,
                           toByteOffset: SharedMemoryLayout.offsetVersion,
                           as: UInt32.self)
        pointer.storeBytes(of: UInt32(targetPID),
                           toByteOffset: SharedMemoryLayout.offsetOwnerPID,
                           as: UInt32.self)
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

        let magicHex = String(format: "%08X", SharedMemoryLayout.magicNumber)
        logDebug("Shared memory initialized (owner_pid=\(targetPID), magic=0x\(magicHex))", log: .speed)
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

    func shutdown() {
        ioQueue.async { [weak self] in
            self?.detachSilentlyInternal()
        }
    }
    
    deinit {
        // 空 deinit - 清理逻辑已迁移到 shutdown()
        // 由调用方显式调用 shutdown() 进行清理
    }
}

// MARK: - 速度控制读写 (无锁原子读写)
//
// 由于 speed_ratio (Float32, 4 字节) 和 is_active (UInt8, 1 字节)
// 在现代 CPU 上的单字节/4 字节读写是原子的，只要内存是自然对齐的，
// 就不需要跨进程锁。Swift 端写，C 端读。
// msync 确保写入被刷新到共享内存区域，对 C 端可见。
extension SpeedControlManager {
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

            pointer.storeBytes(of: clampedRatio,
                               toByteOffset: SharedMemoryLayout.offsetSpeedRatio,
                               as: Float32.self)
            let now = UInt64(Date().timeIntervalSince1970)
            pointer.storeBytes(of: now,
                               toByteOffset: SharedMemoryLayout.offsetTimestamp,
                               as: UInt64.self)
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

            let activeValue = enabled ? UInt8(1) : UInt8(0)
            pointer.storeBytes(of: activeValue,
                               toByteOffset: SharedMemoryLayout.offsetIsActive,
                               as: UInt8.self)
            let now = UInt64(Date().timeIntervalSince1970)
            pointer.storeBytes(of: now,
                               toByteOffset: SharedMemoryLayout.offsetTimestamp,
                               as: UInt64.self)
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

            pointer.storeBytes(of: clampedRatio,
                               toByteOffset: SharedMemoryLayout.offsetSpeedRatio,
                               as: Float32.self)
            let activeValue = enabled ? UInt8(1) : UInt8(0)
            pointer.storeBytes(of: activeValue,
                               toByteOffset: SharedMemoryLayout.offsetIsActive,
                               as: UInt8.self)
            let now = UInt64(Date().timeIntervalSince1970)
            pointer.storeBytes(of: now,
                               toByteOffset: SharedMemoryLayout.offsetTimestamp,
                               as: UInt64.self)
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
}
