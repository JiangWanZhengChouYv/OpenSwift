import Foundation

enum InjectionProtocol {
    
    enum Constants {
        static let sharedMemoryKeyPrefix = "com.openswift.speedpatch."
        static let sharedMemorySize = 4096
        
        static func sharedMemoryKey(for pid: pid_t) -> String {
            return "\(sharedMemoryKeyPrefix)\(pid)"
        }
    }
    
    struct SpeedRatio {
        static let minimum: Float = 0.1
        static let maximum: Float = 10.0
        static let normal: Float = 1.0
        
        static let `default`: Float = 1.0
    }
}

// 注：POSIX 函数 shm_open / shm_unlink 通过 import Foundation 直接可用，无需 @_silgen_name 声明
