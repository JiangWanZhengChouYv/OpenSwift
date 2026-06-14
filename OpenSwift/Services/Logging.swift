import Foundation
import os.log

extension OSLog {
    static let openswift = OSLog(subsystem: "com.openswift.app", category: "App")
    static let launcher = OSLog(subsystem: "com.openswift.app", category: "Launcher")
    static let speed = OSLog(subsystem: "com.openswift.app", category: "SpeedControl")
    static let hotkey = OSLog(subsystem: "com.openswift.app", category: "Hotkey")
    static let settings = OSLog(subsystem: "com.openswift.app", category: "Settings")
}

@inlinable func logDebug(_ message: @autoclosure () -> String, log: OSLog) {
#if DEBUG
    os_log("%{public}@", log: log, type: .debug, message())
#endif
}

@inlinable func logInfo(_ message: @autoclosure () -> String, log: OSLog) {
    os_log("%{public}@", log: log, type: .info, message())
}

@inlinable func logError(_ message: @autoclosure () -> String, log: OSLog) {
    os_log("%{public}@", log: log, type: .error, message())
}
