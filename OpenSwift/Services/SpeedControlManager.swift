import Foundation

// MARK: - 共享内存字段偏移常量 (与 C 端 SharedMemoryHeader 完全一致)
//
// 布局:
//   Offset 0-3:   lock (os_unfair_lock, 4 bytes)         - 跨进程锁
//   Offset 4-7:   version (UInt32, 4 bytes)              - 协议版本
//   Offset 8-11:  owner_pid (UInt32, 4 bytes)            - 创建者 PID
//   Offset 12-15: speed_ratio (Float32, 4 bytes)         - 速度倍率
//   Offset 16:    is_active (UInt8, 1 byte)              - 是否启用
//   Offset 17-23: padding (7 bytes)                      - 对齐填充
//   Offset 24-31: timestamp (UInt64, 8 bytes)            - 时间戳
//   Offset 32-71: reserved (40 bytes)                    - 预留
//   总大小: 72 bytes; 共享内存大小: 4096 bytes
//
// 注意: 所有读写都按固定字节偏移操作，不依赖 Swift/Clang 的 struct 对齐差异
enum SharedMemoryLayout {
    static let size = 4096
    static let headerSize = 72
    
    static let offsetLock = 0        // os_unfair_lock
    static let offsetVersion = 4     // UInt32
    static let offsetOwnerPID = 8    // UInt32
    static let offsetSpeedRatio = 12 // Float32
    static let offsetIsActive = 16   // UInt8
    static let offsetTimestamp = 24  // UInt64
    
    static let currentVersion: UInt32 = 1
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

        // 只有连接到不同进程时才断开
        if targetPID != pid {
            detachFromProcess()
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
            print("[SpeedControlManager] Shared memory not found, trying to create it (mode=0600): \(String(cString: strerror(errno)))")
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

        // 仅在需要时初始化 (version == 0 表示未初始化)
        if let pointer = sharedMemoryPointer {
            let version = pointer.load(fromByteOffset: SharedMemoryLayout.offsetVersion, as: UInt32.self)
            if version == 0 {
                initializeSharedMemory()
            }
        }

        print("[SpeedControlManager] Attached to process \(targetPID)")
        return true
    }

    func detachFromProcess() {
        if let pointer = sharedMemoryPointer {
            munmap(pointer, SharedMemoryLayout.size)
            sharedMemoryPointer = nil
        }

        if sharedMemoryFD != -1 {
            close(sharedMemoryFD)
            sharedMemoryFD = -1
        }

        if targetPID > 0 {
            let key = sharedMemoryKeyPrefix + String(targetPID)
            _ = key.withCString { cKey in
                shm_unlink(cKey)
            }
        }

        targetPID = 0
        print("[SpeedControlManager] Detached from process")
    }

    // MARK: - 共享内存初始化

    private func initializeSharedMemory() {
        guard let pointer = sharedMemoryPointer else { return }

        // 清零整个 header 区域 (前 72 字节)
        memset(pointer, 0, SharedMemoryLayout.headerSize)

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

        // 初始化跨进程锁 (os_unfair_lock 需要初始化为 OS_UNFAIR_LOCK_INIT = 0)
        // memset 已经将锁字段清零，OS_UNFAIR_LOCK_INIT 就是 0
        // 这里显式确认一下
        pointer.storeBytes(of: 0 as UInt32, toByteOffset: SharedMemoryLayout.offsetLock, as: UInt32.self)

        msync(pointer, SharedMemoryLayout.size, MS_SYNC)

        print("[SpeedControlManager] Shared memory initialized (owner_pid=\(targetPID))")
    }

    // MARK: - 跨进程锁辅助方法

    private func withSharedMemoryLock<T>(_ body: () -> T) -> T {
        guard let pointer = sharedMemoryPointer else {
            return body()
        }

        // 通过 UnsafeMutablePointer<os_unfair_lock> 获取锁
        // os_unfair_lock_t 就是 UnsafeMutablePointer<os_unfair_lock>
        let lockPtr = pointer.advanced(by: SharedMemoryLayout.offsetLock)
            .assumingMemoryBound(to: os_unfair_lock.self)

        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }

        return body()
    }

    // MARK: - 速度控制读写

    func setSpeedRatio(_ ratio: Float) -> Bool {
        guard isConnected, let pointer = sharedMemoryPointer else {
            print("[SpeedControlManager] Not connected, cannot set speed ratio")
            return false
        }

        let clampedRatio = min(max(ratio, minSpeedRatio), maxSpeedRatio)

        withSharedMemoryLock {
            // PID 验证: 如果所有者 PID 与当前目标不匹配，可能连接到了错误的共享内存
            let ownerPID = pointer.load(fromByteOffset: SharedMemoryLayout.offsetOwnerPID, as: UInt32.self)
            if ownerPID != 0 && ownerPID != UInt32(targetPID) {
                print("[SpeedControlManager] Warning: owner_pid=\(ownerPID) does not match target_pid=\(targetPID)")
            }

            pointer.storeBytes(of: clampedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
            pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)
        }

        msync(pointer, SharedMemoryLayout.size, MS_SYNC)

        print("[SpeedControlManager] Speed ratio set to \(clampedRatio)")
        return true
    }

    func getSpeedRatio() -> Float {
        guard let pointer = sharedMemoryPointer else {
            return defaultSpeedRatio
        }

        return withSharedMemoryLock {
            pointer.load(fromByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
        }
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        guard isConnected, let pointer = sharedMemoryPointer else {
            print("[SpeedControlManager] Not connected, cannot set enabled")
            return false
        }

        withSharedMemoryLock {
            pointer.storeBytes(of: enabled ? UInt8(1) : UInt8(0), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
            pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)
        }

        msync(pointer, SharedMemoryLayout.size, MS_SYNC)

        print("[SpeedControlManager] Speed control \(enabled ? "enabled" : "disabled")")
        return true
    }

    func isEnabled() -> Bool {
        guard let pointer = sharedMemoryPointer else {
            return false
        }

        return withSharedMemoryLock {
            let value = pointer.load(fromByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
            return value != 0
        }
    }

    func setSpeedRatioAndEnabled(ratio: Float, enabled: Bool) -> Bool {
        guard isConnected, let pointer = sharedMemoryPointer else {
            print("[SpeedControlManager] Not connected, cannot set speed ratio and enabled")
            return false
        }

        let clampedRatio = min(max(ratio, minSpeedRatio), maxSpeedRatio)

        withSharedMemoryLock {
            pointer.storeBytes(of: clampedRatio, toByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
            pointer.storeBytes(of: enabled ? UInt8(1) : UInt8(0), toByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self)
            pointer.storeBytes(of: UInt64(Date().timeIntervalSince1970), toByteOffset: SharedMemoryLayout.offsetTimestamp, as: UInt64.self)
        }

        msync(pointer, SharedMemoryLayout.size, MS_SYNC)

        print("[SpeedControlManager] Speed ratio: \(clampedRatio), enabled: \(enabled)")
        return true
    }

    func syncFromSharedMemory() -> (speedRatio: Float, isEnabled: Bool)? {
        guard let pointer = sharedMemoryPointer else {
            return nil
        }

        return withSharedMemoryLock {
            let ratio = pointer.load(fromByteOffset: SharedMemoryLayout.offsetSpeedRatio, as: Float32.self)
            let isActive = pointer.load(fromByteOffset: SharedMemoryLayout.offsetIsActive, as: UInt8.self) != 0
            return (ratio, isActive)
        }
    }

    deinit {
        detachFromProcess()
    }
}
