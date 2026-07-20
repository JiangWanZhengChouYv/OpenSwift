import Foundation

@_silgen_name("shm_open")
func shm_open(_ name: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32

@_silgen_name("shm_unlink")
func shm_unlink(_ name: UnsafePointer<CChar>!) -> Int32

private func openSharedMemory(pid: pid_t) -> (fd: Int32, pointer: UnsafeMutableRawPointer)? {
    let key = sharedMemoryKeyPrefix + String(pid)

    let fd = key.withCString { cKey in
        shm_open(cKey, O_RDWR, 0)
    }

    if fd == -1 {
        return nil
    }

    let mapped = mmap(nil,
                      SharedMemoryLayout.size,
                      PROT_READ | PROT_WRITE,
                      MAP_SHARED,
                      fd,
                      0)

    guard let pointer = mapped, pointer != MAP_FAILED else {
        close(fd)
        return nil
    }

    return (fd, pointer)
}

private func closeSharedMemory(fd: Int32, pointer: UnsafeMutableRawPointer) {
    msync(pointer, SharedMemoryLayout.size, MS_SYNC)
    munmap(pointer, SharedMemoryLayout.size)
    close(fd)
}

func setSpeed(pid: pid_t, ratio: Float) -> Int32 {
    var clampedRatio = ratio
    if clampedRatio < minSpeedRatio {
        print("警告：速度倍率 \(ratio) 低于最小值 \(minSpeedRatio)，已截断")
        clampedRatio = minSpeedRatio
    } else if clampedRatio > maxSpeedRatio {
        print("警告：速度倍率 \(ratio) 超过最大值 \(maxSpeedRatio)，已截断")
        clampedRatio = maxSpeedRatio
    }

    guard let (fd, pointer) = openSharedMemory(pid: pid) else {
        writeError("错误：找不到进程 \(pid) 的共享内存")
        return 1
    }

    defer {
        closeSharedMemory(fd: fd, pointer: pointer)
    }

    let magic = pointer.load(fromByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
    let version = pointer.load(fromByteOffset: SharedMemoryLayout.offsetVersion, as: UInt32.self)
    if magic != SharedMemoryLayout.magicNumber {
        let expected = String(format: "%08X", SharedMemoryLayout.magicNumber)
        let actual = String(format: "%08X", magic)
        writeError("错误：共享内存 magic 不匹配（期望 0x\(expected)，实际 0x\(actual)）")
        return 1
    }
    if version < 2 {
        writeError("错误：共享内存版本不兼容（\(version)），需要 >= 2")
        return 1
    }

    pointer.storeBytes(of: clampedRatio,
                       toByteOffset: SharedMemoryLayout.offsetSpeedRatio,
                       as: Float32.self)
    pointer.storeBytes(of: UInt8(1),
                       toByteOffset: SharedMemoryLayout.offsetIsActive,
                       as: UInt8.self)
    let now = UInt64(Date().timeIntervalSince1970)
    pointer.storeBytes(of: now,
                       toByteOffset: SharedMemoryLayout.offsetTimestamp,
                       as: UInt64.self)
    msync(pointer, SharedMemoryLayout.size, MS_SYNC)

    print("已设置进程 \(pid) 的加速倍率为 \(clampedRatio)x（已启用）")
    return 0
}

func quitAndCleanup(pid: pid_t) -> Int32 {
    let key = sharedMemoryKeyPrefix + String(pid)

    guard let (fd, pointer) = openSharedMemory(pid: pid) else {
        print("进程 \(pid) 的共享内存不存在或已清理")
        return 0
    }

    defer {
        closeSharedMemory(fd: fd, pointer: pointer)
    }

    let magic = pointer.load(fromByteOffset: SharedMemoryLayout.offsetMagic, as: UInt32.self)
    if magic != SharedMemoryLayout.magicNumber {
        let magicHex = String(format: "%08X", magic)
        writeError("警告：共享内存 magic 不匹配（0x\(magicHex)），仍尝试清理")
    }

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

    let unlinkResult = key.withCString { cKey in
        shm_unlink(cKey)
    }

    if unlinkResult == -1 && errno != ENOENT {
        writeError("警告：shm_unlink 失败：\(String(cString: strerror(errno)))")
    }

    print("已清理进程 \(pid) 的共享内存（速度复位为 1.0x，加速已禁用）")
    return 0
}
