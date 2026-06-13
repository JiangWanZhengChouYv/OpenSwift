import AppKit

print("[main] === OpenSwift 启动 ===")
print("[main] 步骤 1: 获取 NSApplication.shared")

let app = NSApplication.shared

print("[main] 步骤 2: 设置 setActivationPolicy(.regular)")
app.setActivationPolicy(.regular)

print("[main] 步骤 3: 创建 AppDelegate")
let delegate = AppDelegate()

print("[main] 步骤 4: 设置 delegate")
app.delegate = delegate

print("[main] 步骤 5: 调用 app.run()")
app.run()
