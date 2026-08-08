import Foundation

// MARK: - SharedMemorySnapshot

/// 共享内存快照，用于替代多成员元组（避免 SwiftLint large_tuple 违规）
struct SharedMemorySnapshot {
    let speedRatio: Float
    let isEnabled: Bool
    let isWallclockHooked: Bool
}

// MARK: - 挂钟时间 Hook 读写
extension SpeedControlManager {
    func setHookWallclock(_ enabled: Bool) -> Bool {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer, sharedMemoryFD != -1 else {
                logError("Not connected, cannot set hook_wallclock", log: .speed)
                return false
            }

            let value = enabled ? UInt8(1) : UInt8(0)
            pointer.storeBytes(of: value,
                               toByteOffset: SharedMemoryLayout.offsetHookWallclock,
                               as: UInt8.self)
            let now = UInt64(Date().timeIntervalSince1970)
            pointer.storeBytes(of: now,
                               toByteOffset: SharedMemoryLayout.offsetTimestamp,
                               as: UInt64.self)
            msync(pointer, SharedMemoryLayout.size, MS_SYNC)

            logInfo("Hook wallclock \(enabled ? "enabled" : "disabled") for PID \(targetPID)", log: .speed)
            return true
        }
    }

    func getHookWallclock() -> Bool {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer else { return true }
            return pointer.load(fromByteOffset: SharedMemoryLayout.offsetHookWallclock, as: UInt8.self) != 0
        }
    }
}
