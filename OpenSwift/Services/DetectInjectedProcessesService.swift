import Foundation
import AppKit

private let kSharedMemoryKeyPrefix = "com.openswift.speedpatch."
private let kMagic: UInt32 = 0x5350444D
private let kMinVersion: UInt32 = 2
private let kSharedMemorySize: Int = 4096
private let kOffsetMagic: Int = 0
private let kOffsetVersion: Int = 4
private let kOffsetSpeedRatio: Int = 12
private let kOffsetIsActive: Int = 16

struct InjectedProcessMeta {
    let pid: pid_t
    let appName: String
    let appURL: URL
    let speedRatio: Float
    let isActive: Bool
    let launchMethod: LaunchMethod
}

class DetectInjectedProcessesService {
    static let shared = DetectInjectedProcessesService()
    private init() {}

    func scanAllUserProcesses() -> [pid_t: InjectedProcessMeta] {
        var result: [pid_t: InjectedProcessMeta] = [:]
        let currentPID = Foundation.ProcessInfo.processInfo.processIdentifier

        for app in runningApps() {
            let pid = app.processIdentifier
            guard pid >= 2 else { continue }
            guard pid != currentPID else { continue }

            if let meta = probeSharedMemory(pid, app: app) {
                result[pid] = meta
            }
        }

        return result
    }

    private func runningApps() -> [NSRunningApplication] {
        return NSWorkspace.shared.runningApplications
    }

    private func probeSharedMemory(_ pid: pid_t, app: NSRunningApplication) -> InjectedProcessMeta? {
        guard let (speedRatio, isActive) = probeSharedMemory(pid) else { return nil }

        let appName = app.localizedName ?? "Unknown"
        let appURL: URL
        if let url = app.bundleURL {
            appURL = url
        } else if let url = app.executableURL {
            appURL = url
        } else {
            appURL = URL(fileURLWithPath: "/")
        }

        return InjectedProcessMeta(
            pid: pid,
            appName: appName,
            appURL: appURL,
            speedRatio: speedRatio,
            isActive: isActive,
            launchMethod: .staticInjected
        )
    }

    private func probeSharedMemory(_ pid: pid_t) -> (speedRatio: Float, isActive: Bool)? {
        let key = kSharedMemoryKeyPrefix + String(pid)
        let fd = key.withCString { cKey in
            swift_shm_open(cKey, O_RDONLY, 0)
        }
        guard fd != -1 else { return nil }
        defer { close(fd) }

        let ptr = mmap(nil, kSharedMemorySize, PROT_READ, MAP_SHARED, fd, 0)
        guard ptr != MAP_FAILED, let p = ptr else { return nil }
        defer { munmap(p, kSharedMemorySize) }

        let magic = p.load(fromByteOffset: kOffsetMagic, as: UInt32.self)
        let version = p.load(fromByteOffset: kOffsetVersion, as: UInt32.self)
        guard magic == kMagic, version >= kMinVersion else { return nil }

        let ratio = p.load(fromByteOffset: kOffsetSpeedRatio, as: Float.self)
        let active = p.load(fromByteOffset: kOffsetIsActive, as: UInt8.self) != 0
        return (ratio, active)
    }
}
