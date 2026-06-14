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

@_silgen_name("shm_open")
func shm_open(_ name: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32

@_silgen_name("shm_unlink")
func shm_unlink(_ name: UnsafePointer<CChar>!) -> Int32

@_silgen_name("ftok")
func ftok(_ path: UnsafePointer<CChar>!, _ id: Int32) -> key_t
