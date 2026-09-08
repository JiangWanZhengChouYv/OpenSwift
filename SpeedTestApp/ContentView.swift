import SwiftUI
import AppKit
import Darwin
import Combine

// shm_open 是变参函数，Swift 不直接导入；@_silgen_name 直绑 C 符号
@_silgen_name("shm_open")
private func swift_shm_open(_ name: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32

/// 共享内存快照（对应 SpeedPatch 的 SharedMemoryHeader，偏移需一致）
struct SpeedSnapshot {
    var speedRatio: Float
    var isActive: Bool
    var wallclockHooked: Bool
    var ownerPID: pid_t
    var version: UInt32
}

struct ContentView: View {
    private static let magic: UInt32 = 0x5350444D
    private static let supportedVersion: UInt32 = 2
    private static let keyPrefix = "com.openswift.speedpatch."

    @State private var snapshot: SpeedSnapshot?
    @State private var lastError: String?
    @State private var readCount: Int = 0

    private let updateTimer = Timer.publish(every: 0.2, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            ratioDisplay

            Divider()

            statusBadge

            detailSection

            Text("OpenSwift 共享内存倍率检测")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(width: 420, height: 380)
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(updateTimer) { _ in
            poll()
        }
    }

    // MARK: - UI 组件

    private var ratioDisplay: some View {
        VStack(spacing: 4) {
            Text(ratioText)
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .foregroundColor(ratioIsActive ? .accentColor : .secondary)
            Text(isConnected ? "当前倍率" : "未检测到共享内存")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(.top, 24)
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(statusColor.opacity(0.15)))
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailRow(title: "本进程 PID", value: "\(getpid())")
            if let snapshot {
                detailRow(title: "内存 Owner PID", value: "\(snapshot.ownerPID)")
                detailRow(title: "协议版本", value: "\(snapshot.version)")
                detailRow(title: "挂钟 hook", value: snapshot.wallclockHooked ? "已启用" : "未启用")
            } else {
                detailRow(title: "内存 Owner PID", value: "-")
                detailRow(title: "协议版本", value: "-")
                detailRow(title: "挂钟 hook", value: "-")
            }
            if let lastError {
                detailRow(title: "错误", value: lastError)
            }
        }
        .font(.system(size: 13))
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
        .frame(maxWidth: 300)
    }

    // MARK: - 派生状态

    private var isConnected: Bool {
        snapshot != nil
    }

    private var ratioIsActive: Bool {
        snapshot?.isActive ?? false
    }

    private var ratioText: String {
        guard let snapshot else { return "—" }
        return String(format: "%.2fx", snapshot.speedRatio)
    }

    private var statusColor: Color {
        if !isConnected { return Color(NSColor.systemGray) }
        return snapshot?.isActive == true ? .green : .orange
    }

    private var statusText: String {
        if !isConnected { return "未连接" }
        return snapshot?.isActive == true ? "加速中" : "已连接（未启用）"
    }

    // MARK: - 轮询读取

    private func poll() {
        readCount += 1
        if let value = readSharedMemory() {
            snapshot = value
            lastError = nil
        } else if lastError == nil {
            snapshot = nil
        }
    }

    /// 读取本进程 PID 对应的共享内存（name = com.openswift.speedpatch.<pid>）
    private func readSharedMemory() -> SpeedSnapshot? {
        let name = Self.keyPrefix + String(getpid())
        let fd = swift_shm_open(name, O_RDONLY, 0)
        guard fd >= 0 else {
            if readCount == 1 {
                lastError = "shm_open 失败（未注入 SpeedPatch）"
            }
            return nil
        }
        defer { close(fd) }

        var statBuf = stat()
        guard fstat(fd, &statBuf) == 0, statBuf.st_size >= 40 else { return nil }

        let size = Int(statBuf.st_size)
        guard let base = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0),
              base != MAP_FAILED else { return nil }
        defer { munmap(base, size) }

        // 可变偏移位置用 loadUnaligned 安全读取
        let raw = UnsafeRawPointer(base)
        let magic = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let version = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let ownerPID = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        let ratio = raw.loadUnaligned(fromByteOffset: 12, as: Float.self)
        let isActive = raw.loadUnaligned(fromByteOffset: 16, as: UInt8.self) != 0
        let wallclock = raw.loadUnaligned(fromByteOffset: 32, as: UInt8.self) != 0

        guard magic == Self.magic, version == Self.supportedVersion else {
            if readCount == 1 {
                lastError = "magic/version 校验失败（非 OpenSwift 内存）"
            }
            return nil
        }

        return SpeedSnapshot(
            speedRatio: ratio,
            isActive: isActive,
            wallclockHooked: wallclock,
            ownerPID: pid_t(ownerPID),
            version: version
        )
    }
}
