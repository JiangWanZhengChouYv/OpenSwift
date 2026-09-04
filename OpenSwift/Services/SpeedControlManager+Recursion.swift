import Foundation

// MARK: - 递归注入 Hook 读写
extension SpeedControlManager {
    func setRecursiveInject(_ enabled: Bool) -> Bool {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer, sharedMemoryFD != -1 else {
                logError("Not connected, cannot set recursive_inject", log: .speed)
                return false
            }
            let value = enabled ? UInt8(1) : UInt8(0)
            pointer.storeBytes(of: value,
                               toByteOffset: SharedMemoryLayout.offsetRecursiveInject,
                               as: UInt8.self)
            let now = UInt64(Date().timeIntervalSince1970)
            pointer.storeBytes(of: now,
                               toByteOffset: SharedMemoryLayout.offsetTimestamp,
                               as: UInt64.self)
            msync(pointer, SharedMemoryLayout.size, MS_SYNC)
            logInfo("Recursive inject \(enabled ? "enabled" : "disabled") for PID \(targetPID)", log: .speed)
            return true
        }
    }

    func getRecursiveInject() -> Bool {
        return ioQueue.sync {
            guard let pointer = sharedMemoryPointer else { return false }
            return pointer.load(fromByteOffset: SharedMemoryLayout.offsetRecursiveInject, as: UInt8.self) != 0
        }
    }
}
