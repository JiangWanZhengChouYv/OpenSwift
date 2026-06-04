import Foundation

class SpeedControlManager {
    
    static let shared = SpeedControlManager()
    
    private let sharedMemoryKeyPrefix = "com.openswift.speedpatch."
    private var targetPID: pid_t = 0
    private var sharedMemoryPointer: UnsafeMutableRawPointer?
    private var sharedMemoryFD: Int32 = -1
    
    private let minSpeedRatio: Float = 0.1
    private let maxSpeedRatio: Float = 10.0
    private let defaultSpeedRatio: Float = 1.0
    
    struct SharedMemoryHeader {
        var version: UInt32 = 0
        var speed_ratio: Float = 1.0
        var is_active: Bool = false
        var timestamp: UInt64 = 0
        var reserved: [UInt8] = Array(repeating: 0, count: 56)
        
        static var size: Int {
            return MemoryLayout<SharedMemoryHeader>.size
        }
    }
    
    private init() {}
    
    func attachToProcess(pid: pid_t) -> Bool {
        detachFromProcess()
        
        targetPID = pid
        
        let key = sharedMemoryKeyPrefix + String(targetPID)
        
        // 先尝试打开已存在的共享内存（由注入的进程创建）
        sharedMemoryFD = key.withCString { cKey in
            shm_open(cKey, O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP)
        }
        
        // 如果打开失败，尝试创建（但不先删除）
        if sharedMemoryFD == -1 {
            print("[SpeedControlManager] Shared memory not found, trying to create it: \(String(cString: strerror(errno)))")
            sharedMemoryFD = key.withCString { cKey in
                shm_open(cKey, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP)
            }
            
            if sharedMemoryFD == -1 {
                print("[SpeedControlManager] Failed to create shared memory: \(String(cString: strerror(errno)))")
                return false
            }
            
            // 设置共享内存大小
            if ftruncate(sharedMemoryFD, off_t(SharedMemoryHeader.size)) == -1 {
                print("[SpeedControlManager] Failed to set shared memory size: \(String(cString: strerror(errno)))")
                close(sharedMemoryFD)
                sharedMemoryFD = -1
                return false
            }
        }
        
        // 映射共享内存
        sharedMemoryPointer = mmap(nil, 
                                   SharedMemoryHeader.size,
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
        
        // 仅在需要时初始化
        if let pointer = sharedMemoryPointer {
            var header = SharedMemoryHeader()
            memcpy(&header, pointer, SharedMemoryHeader.size)
            if header.version == 0 {
                initializeSharedMemory()
            }
        }
        
        print("[SpeedControlManager] Attached to process \(targetPID)")
        return true
    }
    
    func detachFromProcess() {
        if let pointer = sharedMemoryPointer {
            munmap(pointer, SharedMemoryHeader.size)
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
    
    private func initializeSharedMemory() {
        guard let pointer = sharedMemoryPointer else { return }
        
        var header = SharedMemoryHeader(
            version: 1,
            speed_ratio: defaultSpeedRatio,
            is_active: false,
            timestamp: UInt64(Date().timeIntervalSince1970)
        )
        
        memcpy(pointer, &header, SharedMemoryHeader.size)
        
        msync(pointer, SharedMemoryHeader.size, MS_SYNC)
    }
    
    func setSpeedRatio(_ ratio: Float) -> Bool {
        guard let pointer = sharedMemoryPointer else {
            print("[SpeedControlManager] Shared memory not initialized")
            return false
        }
        
        let clampedRatio = min(max(ratio, minSpeedRatio), maxSpeedRatio)
        
        var header = SharedMemoryHeader()
        memcpy(&header, pointer, SharedMemoryHeader.size)
        
        header.speed_ratio = clampedRatio
        header.timestamp = UInt64(Date().timeIntervalSince1970)
        
        memcpy(pointer, &header, SharedMemoryHeader.size)
        
        msync(pointer, SharedMemoryHeader.size, MS_SYNC)
        
        print("[SpeedControlManager] Speed ratio set to \(clampedRatio)")
        return true
    }
    
    func getSpeedRatio() -> Float {
        guard let pointer = sharedMemoryPointer else {
            return defaultSpeedRatio
        }
        
        var header = SharedMemoryHeader()
        memcpy(&header, pointer, SharedMemoryHeader.size)
        
        return header.speed_ratio
    }
    
    func setEnabled(_ enabled: Bool) -> Bool {
        guard let pointer = sharedMemoryPointer else {
            print("[SpeedControlManager] Shared memory not initialized")
            return false
        }
        
        var header = SharedMemoryHeader()
        memcpy(&header, pointer, SharedMemoryHeader.size)
        
        header.is_active = enabled
        header.timestamp = UInt64(Date().timeIntervalSince1970)
        
        memcpy(pointer, &header, SharedMemoryHeader.size)
        
        msync(pointer, SharedMemoryHeader.size, MS_SYNC)
        
        print("[SpeedControlManager] Speed control \(enabled ? "enabled" : "disabled")")
        return true
    }
    
    func isEnabled() -> Bool {
        guard let pointer = sharedMemoryPointer else {
            return false
        }
        
        var header = SharedMemoryHeader()
        memcpy(&header, pointer, SharedMemoryHeader.size)
        
        return header.is_active
    }
    
    func setSpeedRatioAndEnabled(ratio: Float, enabled: Bool) -> Bool {
        guard let pointer = sharedMemoryPointer else {
            print("[SpeedControlManager] Shared memory not initialized")
            return false
        }
        
        let clampedRatio = min(max(ratio, minSpeedRatio), maxSpeedRatio)
        
        var header = SharedMemoryHeader()
        memcpy(&header, pointer, SharedMemoryHeader.size)
        
        header.speed_ratio = clampedRatio
        header.is_active = enabled
        header.timestamp = UInt64(Date().timeIntervalSince1970)
        
        memcpy(pointer, &header, SharedMemoryHeader.size)
        
        msync(pointer, SharedMemoryHeader.size, MS_SYNC)
        
        print("[SpeedControlManager] Speed ratio: \(clampedRatio), enabled: \(enabled)")
        return true
    }
    
    func syncFromSharedMemory() -> (speedRatio: Float, isEnabled: Bool)? {
        guard let pointer = sharedMemoryPointer else {
            return nil
        }
        
        var header = SharedMemoryHeader()
        memcpy(&header, pointer, SharedMemoryHeader.size)
        
        return (header.speed_ratio, header.is_active)
    }
    
    deinit {
        detachFromProcess()
    }
}
