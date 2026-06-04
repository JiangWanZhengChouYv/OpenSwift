import Foundation
import AppKit

struct ProcessInfo: Identifiable, Hashable {
    let id: UUID
    let pid: pid_t
    let name: String
    let path: String?
    let bundleIdentifier: String?
    let icon: NSImage?
    
    init(pid: pid_t, name: String, path: String? = nil, bundleIdentifier: String? = nil, icon: NSImage? = nil) {
        self.id = UUID()
        self.pid = pid
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.icon = icon
    }
    
    static func from(runningApp: NSRunningApplication) -> ProcessInfo {
        let pid = runningApp.processIdentifier
        let name = runningApp.localizedName ?? "Unknown"
        let bundleIdentifier = runningApp.bundleIdentifier
        let icon = runningApp.icon
        
        var path: String? = nil
        if let executableURL = runningApp.executableURL {
            path = executableURL.path
        }
        
        return ProcessInfo(
            pid: pid,
            name: name,
            path: path,
            bundleIdentifier: bundleIdentifier,
            icon: icon
        )
    }
    
    static func from(pid: pid_t, name: String) -> ProcessInfo {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "")
        
        for app in NSWorkspace.shared.runningApplications {
            if app.processIdentifier == pid {
                return from(runningApp: app)
            }
        }
        
        return ProcessInfo(
            pid: pid,
            name: name,
            path: nil,
            bundleIdentifier: nil,
            icon: NSWorkspace.shared.icon(forFileType: "app")
        )
    }
}

enum ProcessSortOption: String, CaseIterable {
    case name = "名称"
    case pid = "PID"
    
    var comparator: (ProcessInfo, ProcessInfo) -> Bool {
        switch self {
        case .name:
            return { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid:
            return { $0.pid < $1.pid }
        }
    }
}
