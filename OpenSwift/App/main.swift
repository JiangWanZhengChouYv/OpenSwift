import AppKit

// 极简化: 只做最基本的事情
// 关键点:
// 1. setActivationPolicy(.regular) 必须在 app.run() 之前调用
// 2. delegate 赋值前不要触发任何单例的 heavy 初始化
private let app = NSApplication.shared
app.setActivationPolicy(.regular)

private let delegate = AppDelegate()
app.delegate = delegate

app.run()
