import AppKit
import os.log

let mainLog = OSLog(subsystem: "com.openswift.app", category: "App")
os_log("=== OpenSwift ===", log: mainLog, type: .info)
os_log("Step 1: Getting NSApplication.shared", log: mainLog, type: .debug)

let app = NSApplication.shared

os_log("Step 2: Setting activation policy to .regular", log: mainLog, type: .debug)
app.setActivationPolicy(.regular)

os_log("Step 3: Creating AppDelegate", log: mainLog, type: .debug)
let delegate = AppDelegate()

os_log("Step 4: Setting delegate", log: mainLog, type: .debug)
app.delegate = delegate

os_log("Step 5: Calling app.run()", log: mainLog, type: .debug)
app.run()
