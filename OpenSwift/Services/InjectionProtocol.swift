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
    
    struct SharedMemoryHeader {
        static let size = MemoryLayout<SharedMemoryHeaderStruct>.size
        
        struct SharedMemoryHeaderStruct {
            var version: UInt32
            var speedRatio: Float
            var isActive: Bool
            var timestamp: UInt64
            var reserved: [UInt8]
            
            static let currentVersion: UInt32 = 1
            
            init() {
                self.version = Self.currentVersion
                self.speedRatio = SpeedRatio.default
                self.isActive = false
                self.timestamp = UInt64(Date().timeIntervalSince1970)
                self.reserved = [UInt8](repeating: 0, count: 56)
            }
        }
    }
    
    class SharedMemoryManager {
        private let shmKey: String
        private let size: Int
        private var shm_fd: Int32 = -1
        private var mappedMemory: UnsafeMutableRawPointer?
        
        init(pid: pid_t) {
            self.shmKey = Constants.sharedMemoryKey(for: pid)
            self.size = Constants.sharedMemorySize
        }
        
        func create() -> Bool {
            shm_fd = shm_open(shmKey, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP)
            
            if shm_fd == -1 {
                print("[InjectionProtocol] Failed to create shared memory: \(String(cString: strerror(errno)))")
                return false
            }
            
            if ftruncate(shm_fd, off_t(size)) == -1 {
                print("[InjectionProtocol] Failed to set size: \(String(cString: strerror(errno)))")
                Darwin.close(shm_fd)
                shm_fd = -1
                return false
            }
            
            mappedMemory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0)
            
            if mappedMemory == MAP_FAILED {
                print("[InjectionProtocol] Failed to map memory: \(String(cString: strerror(errno)))")
                Darwin.close(shm_fd)
                shm_fd = -1
                mappedMemory = nil
                return false
            }
            
            let header = SharedMemoryHeader.SharedMemoryHeaderStruct()
            mappedMemory?.storeBytes(of: header, as: SharedMemoryHeader.SharedMemoryHeaderStruct.self)
            
            return true
        }
        
        func open() -> Bool {
            shm_fd = shm_open(shmKey, O_RDWR, 0)
            
            if shm_fd == -1 {
                print("[InjectionProtocol] Failed to open shared memory: \(String(cString: strerror(errno)))")
                return false
            }
            
            mappedMemory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0)
            
            if mappedMemory == MAP_FAILED {
                print("[InjectionProtocol] Failed to map memory: \(String(cString: strerror(errno)))")
                Darwin.close(shm_fd)
                shm_fd = -1
                mappedMemory = nil
                return false
            }
            
            return true
        }
        
        func close() {
            if let memory = mappedMemory {
                munmap(memory, size)
                mappedMemory = nil
            }
            
            if shm_fd != -1 {
                Darwin.close(shm_fd)
                shm_fd = -1
            }
        }
        
        func writeSpeedRatio(_ ratio: Float) -> Bool {
            guard let memory = mappedMemory else {
                return false
            }
            
            let clampedRatio = max(SpeedRatio.minimum, min(SpeedRatio.maximum, ratio))
            
            var header = memory.load(as: SharedMemoryHeader.SharedMemoryHeaderStruct.self)
            header.speedRatio = clampedRatio
            header.timestamp = UInt64(Date().timeIntervalSince1970)
            memory.storeBytes(of: header, as: SharedMemoryHeader.SharedMemoryHeaderStruct.self)
            
            msync(memory, size, MS_SYNC)
            
            return true
        }
        
        func readSpeedRatio() -> Float? {
            guard let memory = mappedMemory else {
                return nil
            }
            
            let header = memory.load(as: SharedMemoryHeader.SharedMemoryHeaderStruct.self)
            return header.speedRatio
        }
        
        func setActive(_ active: Bool) -> Bool {
            guard let memory = mappedMemory else {
                return false
            }
            
            var header = memory.load(as: SharedMemoryHeader.SharedMemoryHeaderStruct.self)
            header.isActive = active
            header.timestamp = UInt64(Date().timeIntervalSince1970)
            memory.storeBytes(of: header, as: SharedMemoryHeader.SharedMemoryHeaderStruct.self)
            
            msync(memory, size, MS_SYNC)
            
            return true
        }
        
        func isActive() -> Bool {
            guard let memory = mappedMemory else {
                return false
            }
            
            let header = memory.load(as: SharedMemoryHeader.SharedMemoryHeaderStruct.self)
            return header.isActive
        }
        
        func cleanup() {
            close()
            
            shm_unlink(shmKey)
        }
        
        deinit {
            close()
        }
    }
}

@_silgen_name("shm_open")
func shm_open(_ name: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32

@_silgen_name("shm_unlink")
func shm_unlink(_ name: UnsafePointer<CChar>!) -> Int32

@_silgen_name("ftok")
func ftok(_ path: UnsafePointer<CChar>!, _ id: Int32) -> key_t
