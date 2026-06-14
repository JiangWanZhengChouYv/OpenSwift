# OpenSwift 修复报告 (Fix Report)

**日期：** 2025-06-14
**编译状态：** ✅ 成功 (OpenSwift.app + SpeedPatch.dylib)
**测试：** `xcodebuild -scheme <scheme> -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO`

---

## 1. 架构概述

项目由两个主要目标组成：

| 目标 | 类型 | 职责 |
|------|------|------|
| **OpenSwift** | SwiftUI macOS App | 用户界面、进程管理、速度控制面板、全局热键 |
| **SpeedPatch** | C dylib | 被注入到目标进程，拦截时间相关函数 (mach_absolute_time, clock_gettime, gettimeofday 等) 并通过 POSIX 共享内存与主程序通信 |

两者之间通过 **POSIX 共享内存** 通信，共享内存中包含一份协议头：`magic`, `version`, `owner_pid`, `speed_ratio`, `is_enabled` 以及时间戳。

---

## 2. 修复清单

### Issue 1: `os_log_debug` / `os_log_info` / `os_log_error` 与 SDK 宏冲突

**文件：** `OpenSwift/Services/Logging.swift`（新建）

**问题：** 项目中的 Swift 代码使用了 `os_log_debug(message, log: .openswift)` 这样的调用，而 Apple SDK 在 `<os/log.h>` 中定义了同名的**宏**。由于 C 宏在 Swift 导入时被展开，`os_log_debug` 宏遮蔽了 Swift 函数，导致以下编译错误：

```
error: cannot find 'os_log_debug' in scope
error: macro 'os_log_debug' unavailable: function like macros not supported
```

**修复：**
1. 创建统一的 `Logging.swift`，提供 `logDebug` / `logInfo` / `logError` 三个函数（避免与 SDK 宏名冲突）
2. 在 `OSLog` 扩展中提供 `.openswift`, `.launcher`, `.speed`, `.hotkey`, `.settings` 五个日志分类
3. 使用 `os_log` + `#if DEBUG` 包裹 `logDebug`，Release 构建无调试日志开销
4. 全项目替换 `os_log_debug(...)` → `logDebug(..., log: .xxx)`，依此类推

**影响范围：**
- `OpenSwift/App/main.swift`
- `OpenSwift/Services/AppLauncher.swift`
- `OpenSwift/Services/AppLauncherViewModel.swift`
- `OpenSwift/Services/SpeedControlManager.swift`
- `OpenSwift/Services/ProcessManager.swift`
- `OpenSwift/Services/ProcessInjector.swift`
- `OpenSwift/Services/HotkeyService.swift`
- `OpenSwift/Services/HotkeyStorage.swift`
- `OpenSwift/Services/GlobalHotkeyManager.swift`
- `OpenSwift/Services/SettingsStorage.swift`
- `OpenSwift/Models/SpeedControlState.swift`
- `OpenSwift/Views/SettingsView.swift`
- `OpenSwift.xcodeproj/project.pbxproj`（将 `Logging.swift` 加入 Sources build phase）

**验证：** `xcodebuild -scheme OpenSwift` 通过，没有相关错误

---

### Issue 2: `SpeedControlState.swift` 中 `logError(_ message:)` 遮蔽全局 `logError`

**文件：** `OpenSwift/Models/SpeedControlState.swift`

**问题：** `SpeedControlState` 内定义了私有方法 `private func logError(_ message: String)`，内部调用全局 `logError`。该方法名与全局函数冲突，导致内部调用被解析为递归自调用（无限递归）。同时原来的格式字符串写法也不正确。

**修复：** 将私有方法重命名为 `recordError(_:)`，内部使用插值字符串正确调用全局 `logError`。

```swift
private func recordError(_ message: String) {
    logError("SpeedControl: \(message)", log: .speed)
    lastError = message
}
```

**影响范围：** `SpeedControlState.swift`

---

### Issue 3: `main.swift` 不依赖 `Logging.swift`

**文件：** `OpenSwift/App/main.swift`

**问题：** `main.swift` 作为独立入口点，之前调用了 `os_log_debug` / `os_log_info`。由于它不包含在通用模块中，不能依赖主项目的 `Logging.swift`。

**修复：** 直接使用 `os_log` 基础 API，在文件内部定义 `OSLog` 实例用于启动日志，不调用全局 helper。

```swift
let mainLog = OSLog(subsystem: "com.openswift.app", category: "App")
os_log("=== OpenSwift ===", log: mainLog, type: .info)
```

**影响范围：** `main.swift`

---

### Issue 4: `Logging.swift` 未在 Xcode 项目文件中注册

**文件：** `OpenSwift.xcodeproj/project.pbxproj`

**问题：** `Logging.swift` 存在于磁盘上，但未在 `project.pbxproj` 的 `PBXBuildFile` / `PBXFileReference` / Services 组 / OpenSwift target 的 Sources build phase 中注册，导致 Xcode 编译时忽略该文件。

**修复：** 用脚本在 pbxproj 中插入：
- 一个 `PBXFileReference` 指向 `Logging.swift`
- 一个 `PBXBuildFile` 引用上述 file ref
- 将 file ref 加入 `Services` PBXGroup 的 children 列表
- 将 build file 加入 OpenSwift target 的 Sources build phase

**注意：** UUID 通过 Python `uuid.uuid4().hex[:24].upper()` 生成，符合 Xcode 习惯。

---

### Issue 5: `Logging.swift` 默认参数引用内部静态属性

**文件：** `OpenSwift/Services/Logging.swift`

**问题：** `logDebug(_:log: OSLog = .openswift)` 等函数使用 `OSLog.openswift` 作为默认值，但 Swift 不允许在 default argument expression 中引用 `internal` 访问级别的静态成员（尽管它在同一个文件内定义，但 Swift 编译器仍然拒绝）。

**修复：** 移除默认参数值，强制所有调用显式传入 `log: .xxx`，提高可读性也避免意外。

---

## 3. 编译验证

### 3.1 OpenSwift (App)

```
xcodebuild -scheme OpenSwift -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO
```

**结果：** ✅ BUILD SUCCEEDED

**残余警告（非致命，可按需修复）：**
- `HotkeyService.swift:177` —— `'NSUserNotification' was deprecated in macOS 11.0`
- `HotkeyService.swift:182` —— `'NSUserNotificationCenter' was deprecated in macOS 11.0`
- `ProcessInfo.swift:42` —— 未使用的 `runningApps` 常量

### 3.2 SpeedPatch (dylib)

```
xcodebuild -scheme SpeedPatch -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO
```

**结果：** ✅ BUILD SUCCEEDED

---

## 4. 建议的后续工作

- **替换弃用 API：** `NSUserNotification` / `NSUserNotificationCenter` 应迁移到 `UserNotifications` 框架（`UNUserNotificationCenter`）
- **移除未使用变量：** `ProcessInfo.swift:42` 的 `runningApps`
- **签名与公证：** 当前使用 `CODE_SIGNING_ALLOWED=NO` 跳过签名。实际分发时需要 Developer ID 证书、notarization 和 staple。
- **添加单元测试：** `SpeedControlManager` 的共享内存读写逻辑应补充测试；`AppLauncher` 的路径解析应添加 mock 测试。

---

## 5. 修改的文件列表

| # | 文件 | 修改类型 |
|---|------|----------|
| 1 | `OpenSwift/Services/Logging.swift` | **新建** —— 统一日志工具 |
| 2 | `OpenSwift/App/main.swift` | 修改 —— 直接使用 `os_log` |
| 3 | `OpenSwift/Services/AppLauncher.swift` | 修改 —— `os_log_*` → `log*` |
| 4 | `OpenSwift/Services/AppLauncherViewModel.swift` | 修改 —— `os_log_*` → `log*` |
| 5 | `OpenSwift/Services/SpeedControlManager.swift` | 修改 —— `os_log_*` → `log*` |
| 6 | `OpenSwift/Services/ProcessManager.swift` | 修改 —— `os_log_*` → `log*` + 内部 controller 字典 |
| 7 | `OpenSwift/Services/ProcessInjector.swift` | 修改 —— `os_log_*` → `log*` |
| 8 | `OpenSwift/Services/HotkeyService.swift` | 修改 —— `os_log_*` → `log*` |
| 9 | `OpenSwift/Services/HotkeyStorage.swift` | 修改 —— `os_log_*` → `log*` |
| 10 | `OpenSwift/Services/GlobalHotkeyManager.swift` | 修改 —— `os_log_*` → `log*` |
| 11 | `OpenSwift/Services/SettingsStorage.swift` | 修改 —— `os_log_*` → `log*` |
| 12 | `OpenSwift/Models/SpeedControlState.swift` | 修改 —— `logError` → `recordError`，添加显式 `log:` 参数 |
| 13 | `OpenSwift/Views/SettingsView.swift` | 修改 —— `os_log_*` → `log*` |
| 14 | `OpenSwift.xcodeproj/project.pbxproj` | 修改 —— 注册 `Logging.swift` 到 OpenSwift target |
