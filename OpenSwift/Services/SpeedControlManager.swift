import Foundation

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
    
    static let currentVersion: UInt32 = 1
    static let magicNumber: UInt32 = 0x5350444D // "SPDM"
}

// MARK: - 共享内存管理器

class SpeedControlManager {

    static let shared = SpeedControlManager()

    private let sharedMemoryKeyPrefix = "com.openswift.speedpatch."
    private var targetPID: pid_t = 0
    private var sharedMemoryPointer: UnsafeMutableRawPointer?
    private var sharedMemoryFD: Int32 = -1

    private let minSpeedRatio: Float = 0.1
    private let maxSpeedRatio: Float = 10.0
    private let defaultSpeedRatio: Float = 1.0

    var isConnected: Bool {
        return sharedMemoryPointer != nil && sharedMemoryFD != -1
    }

    private init() {}

    // MARK: - 进程连接

    func attachToProcess(pid: pid_t) -> Bool {
        // 如果已经连接到同一个进程，不做任何操作
        if targetPID == pid && isConnected {
            print("[SpeedControlManager] Already attached to process \(pid)")
            return true
        }

        // 只有连接到不同进程时才断开（但不删除共享内存，因为目标进程可能仍在运行）
        if targetPID != pid {
            detachSilently()
        }

        targetPID = pid

        let key = sharedMemoryKeyPrefix + String(targetPID)

        // 权限: 0600 - 仅所有者可读可写 (与 C 端保持一致)
        let shmMode = S_IRUSR | S_IWUSR

        // 先尝试打开已存在的共享内存（由注入的进程创建）
        sharedMemoryFD = key.withCString { cKey in
            shm_open(cKey, O_RDWR, shmMode)
        }

        // 如果打开失败，尝试创建（但不先删除）
        if sharedMemoryFD == -1 {
            print("[SpeedControlManager] Shared memory not found for PID \(pid), trying to create it (mode=0600): \(String(cString: strerror(errno)))")
            sharedMemoryFD = key.withCString { cKey in
                shm_open(cKey, O_CREAT | O_RDWR, shmMode)
            }

            if sharedMemoryFD == -1 {
                print("[SpeedControlManager] Failed to create shared memory: \(String(cString: strerror(errno)))")
                return false
            }

            // 设置共享内存大小
            if ftruncate(sharedMemoryFD, off_t(SharedMemoryLayout.size)) == -1 {
                print("[SpeedControlManager] Failed to set shared memory size: \(String(cString: strerror(errno)))")
                close(sharedMemoryFD)
                sharedMemoryFD = -1
                return false
            }
        }

        // 映射共享内存
        sharedMemoryPointer = mmap(nil,
                                   SharedMemoryLayout.size,
                                   PROT_READ | PROT_WRITE,
                                   MAP_SHARED,
                                   sharedMemoryFD,
                                   0)

        if sharedMemoryPointer == MAP_FAILED {
            print("[SpeedControlManager] Failed to map shared memory: \(String(cString: strerror(errno)))")
            close(sharedMemoryFD)
            sharedMemoryFD = -1
            return false
        }

        // 检查共享内存是否已初始化（通过 magic number 和 version）
        if let pointer = sharedMemoryPointer {
            let magic = pointer.load(fromByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
            let version = pointer.load(fromByteOffset: SharedMemoryLayout.offsetVersion, as: UInt32.self)

            if magic != SharedMemoryLayout.magicNumber || version == 0 {
                print("[SpeedControlManager] Shared memory not initialized (magic=\(magic), version=\(version)), initializing...")
                initializeSharedMemory()
            } else {
                print("[SpeedControlManager] Connected to existing shared memory (magic=0x\(String(format: "%08X", magic)), version=\(version))")
            }
        }

        print("[SpeedControlManager] Attached to process \(targetPID)")
        return true
    }

    /// 静默断开连接：只 munmap 和 close，不删除共享内存
    /// 用于切换进程或临时断开，目标进程可能仍在运行
    func detachSilently() {
        if let pointer = sharedMemoryPointer {
            munmap(pointer, SharedMemoryLayout.size)
            sharedMemoryPointer = nil
        }

        if sharedMemoryFD != -1 {
            close(sharedMemoryFD)
            sharedMemoryFD = -1
        }

        targetPID = 0
        print("[SpeedControlManager] Detached silently (shared memory preserved)")
    }

    /// 完全断开并清理：只有在确定目标进程已终止时调用
    func detachAndCleanup() {
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
            print("[SpeedControlManager] Shared memory unlinked for PID \(pidToClean)")
        }

        targetPID = 0
        print("[SpeedControlManager] Detached and cleaned up")
    }

    /// 向后兼容的 detach（保持 API 不变）
    func detachFromProcess() {
        detachSilently()
    }

    // MARK: - 共享内存初始化

    private func initializeSharedMemory() {
        guard let pointer = sharedMemoryPointer else { return }

        // 清零整个 header 区域 (前 72 字节)
        memset(pointer, 0, SharedMemoryLayout.headerSize)

        // 初始化 magic number（验证共享内存有效性）
        pointer.storeBytes(of: SharedMemoryLayout.magicNumber, toByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)

        // 初始化协议版本
        pointer.storeBytes(of: SharedMemoryLayout.currentVersion, toByteOffset: SharedMemoryLayout.offsetVersion, as: UInt32.self)

        // 初始化所有者 PID
        pointer.storeBytes(of: UInt32(targetPID), toByteOffset: SharedMemoryLayout.offsetOwnerPID, as: UInt32.self)

        // 初始化默认速度
        pointer.storeBytes(of: defaultSpeedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)

        // 初始化为禁用状态
        pointer.storeBytes(of: UInt8(0), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)

        // 初始化时间戳
        pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)

        // msync 确保写入对其他进程可见
        msync(pointer, SharedMemoryLayout.size, MS_SYNC)

        print("[SpeedControlManager] Shared memory initialized (owner_pid=\(targetPID), magic=0x\(String(format: "%08X", SharedMemoryLayout.magicNumber)))")
    }

    // MARK: - 速度控制读写 (无锁原子读写)
    //
    // 由于 speed_ratio (Float32, 4 字节) 和 is_active (UInt8, 1 字节)
    // 在现代 CPU 上的单字节/4 字节读写是原子的，只要内存是自然对齐的，
    // 就不需要跨进程锁。Swift 端写，C 端读。
    // msync 确保写入被刷新到共享内存区域，对 C 端可见。

    func setSpeedRatio(_ ratio: Float) -> Bool {
        guard isConnected, let pointer = sharedMemoryPointer else {
            print("[SpeedControlManager] Not connected, cannot set speed ratio")
            return false
        }

        let clampedRatio = min(max(ratio, minSpeedRatio), maxSpeedRatio)

        // PID 验证（调试信息，不影响操作）
        let ownerPID = pointer.load(fromByteOffset: SharedMemoryLayout.offsetOwnerPID, as: UInt32.self)
        if ownerPID != 0 && ownerPID != UInt32(targetPID) {
            print("[SpeedControlManager] Warning: owner_pid=\(ownerPID) does not match target_pid=\(targetPID)")
        }

        pointer.storeBytes(of: clampedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
        pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)

        msync(pointer, SharedMemoryLayout.size, MS_SYNC)

        print("[SpeedControlManager] Speed ratio set to \(clampedRatio) for PID \(targetPID)")
        return true
    }

    func getSpeedRatio() -> Float {
        guard let pointer = sharedMemoryPointer else {
            return defaultSpeedRatio
        }

        let ratio = pointer.load(fromByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
        return ratio
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        guard isConnected, let pointer = sharedMemoryPointer else {
            print("[SpeedControlManager] Not connected, cannot set enabled")
            return false
        }

        pointer.storeBytes(of: enabled ? UInt8(1) : UInt8(0), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
        pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)

        msync(pointer, SharedMemoryLayout.size, MS_SYNC)

        print("[SpeedControlManager] Speed control \(enabled ? "enabled" : "disabled") for PID \(targetPID)")
        return true
    }

    func isEnabled() -> Bool {
        guard let pointer = sharedMemoryPointer else {
            return false
        }

        let value = pointer.load(fromByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
        return value != 0
    }

    func setSpeedRatioAndEnabled(ratio: Float, enabled: Bool) -> Bool {
        guard isConnected, let pointer = sharedMemoryPointer else {
            print("[SpeedControlManager] Not connected, cannot set speed ratio and enabled")
            return false
        }

        let clampedRatio = min(max(ratio, minSpeedRatio), maxSpeedRatio)

        pointer.storeBytes(of: clampedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
        pointer.storeBytes(of: enabled ? UInt8(1) : UInt8(0), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
        pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)

        msync(pointer, SharedMemoryLayout.size, MS_SYNC)

        print("[SpeedControlManager] Speed ratio: \(clampedRatio), enabled: \(enabled) for PID \(targetPID)")
        return true
    }

    func syncFromSharedMemory() -> (speedRatio: Float, isEnabled: Bool)? {
        guard let pointer = sharedMemoryPointer else {
            return nil
        }

        let ratio = pointer.load(fromByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
        let isActive = pointer.load(fromByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self) != 0
        return (ratio, isActive)
    }

    deinit {
        detachSilently()
    }
}
