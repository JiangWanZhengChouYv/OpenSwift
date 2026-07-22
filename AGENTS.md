# OpenSwift 项目规则

## 项目概述

OpenSwift 是一个 macOS 应用加速器，通过 DYLD 注入 SpeedPatch.dylib 到目标进程，Hook 时间函数实现速度控制。使用 XcodeGen (project.yml) 生成 Xcode 项目，不提交 .xcodeproj。

## 命名规范

- 项目名称必须统一使用 'OpenSwift'（不要用 'OpenSpeedy'）
- dylib 必须命名为 'SpeedPatch.dylib'（不是 'libSpeedPatch.dylib'）
- 共享内存 key 前缀：`com.openswift.speedpatch.`
- Magic number：`0x5350444D (SPDM)`，版本：2

## 代码规范

### SwiftLint 配置

项目使用 SwiftLint 进行代码规范检查，配置文件为 `.swiftlint.yml`。

**启用的规则**：
- `line_length`: 警告 120 字符，错误 150 字符（忽略注释和 URL）
- `file_length`: 警告 400 行，错误 600 行
- `function_body_length`: 警告 50 行，错误 80 行
- `cyclomatic_complexity`: 警告 10，错误 15
- 标识符命名规范：变量名至少 3 字符（除常见的短变量如 `id`、`ok` 等）

**禁用的规则**：
- `trailing_whitespace`（行尾空格）
- `todo`（TODO 注释）

### CI 分离

- **Build CI** (`.github/workflows/build.yml`)：仅执行编译检查，不包含 SwiftLint
- **SwiftLint CI** (`.github/workflows/swiftlint.yml`)：独立的代码规范检查，提交后触发

**本地验证**：
```bash
# 运行 SwiftLint 检查
swiftlint lint --strict

# 编译项目
xcodebuild -project OpenSwift.xcodeproj -scheme OpenSwift -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## 构建方式

```bash
# 生成 Xcode 项目
xcodegen generate

# 完整编译（含 SpeedPatch 依赖）
xcodebuild -project OpenSwift.xcodeproj -scheme OpenSwift -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# 仅编译 SpeedPatch dylib
xcodebuild -project OpenSwift.xcodeproj -target SpeedPatch -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO

# 构建到指定目录
xcodebuild -project OpenSwift.xcodeproj -scheme OpenSwift -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CONFIGURATION_BUILD_DIR=临时

# 清理构建
xcodebuild -project OpenSwift.xcodeproj -scheme OpenSwift clean

# 编译测试应用
cd TestApp && bash build.sh
```

- 部署目标：macOS 13.0
- SpeedPatch 是 dylib bundle target，作为 OpenSwift 依赖自动编译
- dylib 实际路径：`OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch`
- CI：GitHub Actions（.github/workflows/build.yml）自动编译检查

## 测试加速功能

```bash
# 1. 编译测试应用
cd TestApp && gcc -o testapp testapp.c && codesign --force --sign - testapp

# 2. DYLD 注入启动测试应用（替换为实际 dylib 路径）
DYLD_INSERT_LIBRARIES="/path/to/SpeedPatch.dylib" ./testapp

# 3. 编译并运行速度控制测试工具
gcc -o speed_test speed_test.c
./speed_test <target_pid> 2.0 1   # 设置 2x 加速

# 4. 观察 testapp 输出：时间戳间隔应为 0.5 秒（2x 加速）
```

## 计时器测试应用 (TimerTestApp)

用于可视化测试 OpenSwift 速度控制功能的 GUI 应用。

### 编译

```bash
# 编译到临时目录
xcodebuild -project OpenSwift.xcodeproj -scheme TimerTestApp -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR=临时
```

### 使用方式

**方式 1：使用 openswift CLI 启动**
```bash
# 启动计时器应用（自动注入 SpeedPatch）
openswift -o 临时/TimerTestApp.app

# 设置加速倍率
openswift speed <PID> 2.0

# 观察效果：计时器流逝速度应为正常的 2 倍
```

点击"开始"按钮启动计时器，然后用 `openswift speed` 设置加速倍率，观察计时器速度变化。

**方式 2：在 OpenSwift.app 中使用**
1. 打开 OpenSwift.app
2. 点击播放按钮选择 TimerTestApp.app
3. 使用速度滑块控制加速倍率

### 应用特性
- 秒表计时器，从 00:00:00.000 开始计时
- 显示格式：HH:mm:ss.SSS
- 更新频率：100Hz（每 0.01 秒更新）
- 支持开始/暂停/重置操作
- 使用 clock_gettime(CLOCK_MONOTONIC) 计算经过时间（已被 SpeedPatch hook，加速生效）
- 简洁的 SwiftUI 界面

## CLI 命令行工具 (openswift)

OpenSwift 提供独立的 CLI 工具 `openswift`，支持通过命令行启动或重启应用并注入 SpeedPatch.dylib。

### 构建 CLI

```bash
# 仅编译 CLI
xcodebuild -project OpenSwift.xcodeproj -target openswift-cli -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CONFIGURATION_BUILD_DIR=临时

# 产物位置：临时/openswift
```

### 使用方式

```bash
# 智能模式（运行中则重启，否则启动）
openswift <目录>

# DYLD 启动模式（直接以 DYLD 注入方式启动）
openswift -o <目录>

# DYLD 重启模式（先终止已运行进程，再启动）
openswift -r <目录>

# 速度控制（通过共享内存写入速度倍率，0.1~10.0）
openswift speed <pid> <ratio>

# 退出清理（复位加速并 shm_unlink 共享内存，幂等）
openswift quit <pid>

# 帮助信息
openswift --help
```

### CLI 安装方式

openswift CLI 是独立的可执行文件，有三种安装/部署方式：

#### 方式 1：与 OpenSwift.app 同目录部署（推荐）

将 `openswift` 二进制放到 `OpenSwift.app` 同级目录，CLI 会自动从 `.app` 内查找 SpeedPatch.dylib：

```bash
# 编译到同一目录
xcodebuild -project OpenSwift.xcodeproj -scheme OpenSwift -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR=临时
xcodebuild -project OpenSwift.xcodeproj -target openswift-cli -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR=临时

# 临时/openswift 会自动定位 临时/OpenSwift.app 内嵌的 SpeedPatch.dylib
临时/openswift -o TestApp/testapp
临时/openswift speed <pid> 2.0
临时/openswift quit <pid>
```

#### 方式 2：安装到系统 PATH

```bash
# 复制到 /usr/local/bin（需要 sudo）
sudo cp 临时/openswift /usr/local/bin/openswift
sudo chmod 755 /usr/local/bin/openswift

# 然后可以直接在任意目录调用
openswift -o /Applications/MyApp.app
```

注意：安装到 `/usr/local/bin` 后，CLI 无法自动定位 OpenSwift.app 内的 dylib，
需要使用环境变量 `OPENSWIFT_DYLIB_PATH` 指定 dylib 路径，或将 dylib 复制到 `/usr/local/lib/`。

#### 方式 3：环境变量指定 dylib 路径

适用于 CLI 与 OpenSwift.app 不在同一目录的场景：

```bash
# 指向 dylib 文件
export OPENSWIFT_DYLIB_PATH="/Applications/OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch"
openswift -o /Applications/MyApp.app

# 或指向包含 SpeedPatch.dylib 的目录
export OPENSWIFT_DYLIB_PATH="/path/to/dir"
openswift -o ./testapp
```

### dylib 路径定位

CLI 按以下顺序定位 SpeedPatch.dylib：
1. 环境变量 `OPENSWIFT_DYLIB_PATH` 指定的路径（文件或目录）
2. 与 CLI 同级的 `PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch`
3. 与 CLI 同级的 `PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch`
4. CLI 同级目录下的 `OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch`（CLI 与 .app 共存场景）
5. 当前工作目录下的 `SpeedPatch.dylib`
6. 当前工作目录下 `OpenSwift.app/Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch`

### 示例

```bash
# 完整编译 OpenSwift.app 和 openswift-cli 到临时目录
xcodebuild -project OpenSwift.xcodeproj -scheme OpenSwift -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR=临时
xcodebuild -project OpenSwift.xcodeproj -target openswift-cli -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR=临时

# 启动 testapp（CLI 与 OpenSwift.app 同目录自动定位 dylib）
临时/openswift -o TestApp/testapp

# 使用环境变量指定 dylib 路径
OPENSWIFT_DYLIB_PATH="临时/SpeedPatch.dylib/Contents/MacOS/SpeedPatch" 临时/openswift -o TestApp/testapp

# 启动 .app 应用
openswift -o /Applications/MyApp.app

# 重启正在运行的应用
openswift -r /Applications/MyApp.app
```

### 注意事项

- macOS 大小写不敏感，根目录无法同时存在 `openswift`（文件）和 `OpenSwift`（目录），测试时使用 `临时/openswift`
- CLI 支持 `.app` 应用包和独立可执行文件
- CLI 源代码位于 `OpenSwift/CLI/` 目录，在 project.yml 的 OpenSwift target 中通过 `excludes: ["CLI/**"]` 排除以避免 main.stringsdata 冲突
- openswift-cli target 在 project.yml 中独立定义（type: tool）

### CLI 自动安装（OpenSwift.app 内置）

OpenSwift.app 启动时会自动安装/更新 `openswift` CLI 到系统可写的 bin 目录。

- **实现文件**：`OpenSwift/Services/CLIManager.swift`
- **调用时机**：`AppState.setup()` 中调用 `CLIManager.shared.setup()`
- **执行方式**：后台队列异步执行（不阻塞主线程）
- **内部 CLI 路径**：`OpenSwift.app/Contents/SharedSupport/openswift`
  - 注意：不能放在 `Contents/MacOS/` 下，因为 macOS 文件系统大小写不敏感，`openswift` 会和主程序 `OpenSwift` 冲突
- **project.yml 配置**：`destination: sharedSupport`（XcodeGen embed copy phase）
- **静态链接 Swift 标准库**：`SWIFT_FORCE_STATIC_STDLIBS: YES`，避免部署到其他机器找不到 Swift runtime
- **安装路径优先级**（按顺序尝试，选第一个可写的）：
  1. `/usr/local/bin/openswift`
  2. `/opt/homebrew/bin/openswift`
- **更新逻辑**：SHA-256 哈希对比，不一致则覆盖更新
- **错误处理**：静默失败，仅记录 OSLog（subsystem: com.openswift.app, category: CLI），不影响主应用启动

## 关键约束

- 共享内存必须使用固定大小数据结构（禁止动态数组）
- Swift 和 C 共享内存结构必须使用 `__attribute__((packed))` 保证内存布局一致
- SpeedPatch 创建共享内存；OpenSwift 只连接已存在的共享内存
- 跨进程同步使用原子读写，禁止使用 os_unfair_lock
- 单例初始化使用 '轻量 init + setup 方法' 模式，setup() 在窗口创建后调用
- 应用入口点使用纯 SwiftUI `App` 协议（`@main` + `Window` 场景），不再使用 AppKit `NSApplicationDelegate`
- 菜单栏使用 SwiftUI `MenuBarExtra`（macOS 13+），不再使用 `NSStatusBar`
- 菜单系统使用 SwiftUI `Commands` 和 `CommandMenu`，不再使用 `NSMenu`
- 应用退出使用 `CommandGroup(replacing: .appTermination)` 处理清理，不再依赖 `applicationWillTerminate`
- Swift 调用 POSIX 变参函数需使用 `@_silgen_name` 声明
- 菜单栏仅显示主界面
- .trae/、AGENTS.md、临时/、*.xcodeproj 一律加入 .gitignore
- 上传文件时设置 ALL_PROXY=http://127.0.0.1:7890

## 已知问题与修复记录

- **退出崩溃 (2026-07-20)**：`applicationWillTerminate` 调用 `saveWindowPosition()` 时访问已释放的 `mainWindow` 对象导致 `EXC_BAD_ACCESS`。修复：使用 `if let` 安全访问，在 `windowWillClose` 中清空引用。
- **加速无效修复 (2026-07-21)**：TimerTestApp 使用 `Date()` 计算经过时间，而 `Date()` 内部依赖 `CFAbsoluteTimeGetCurrent()`（挂钟时间），SpeedPatch 不 hook 挂钟时间导致加速无效。修复：改用 `clock_gettime(CLOCK_MONOTONIC)` 获取单调时钟时间（已被 SpeedPatch hook），加速效果正常。
- **找不到 SpeedPatch.dylib (2026-07-21)**：OpenSwift.app 启动时显示"找不到 SpeedPatch.dylib"，原因是 AppLauncher 的 `getDylibPath()` 方法未包含 bundle 格式的 dylib 路径。修复：在路径搜索列表中添加 `Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch`，与 CLI 的路径查找逻辑保持一致。
- **加速倍率切换时间卡住 (2026-07-21)**：使用 CLI 设置加速时出现"越加速越慢"，5.0x 时几乎不动。根因：从高速切换到低速时，单调性保护变量 `g_last_clock_ns` 已处于"未来"值，新计算的时间始终小于该值，触发保护逻辑导致时间几乎不增长。修复：检测到倍率或激活状态变化时，用当前真实时间重置基准时间和单调性保护变量，确保平滑过渡。同时修复 `g_base_clock_gettime_sec` 从 double 改为 int64_t 避免精度损失。
- **速度控制开关自动关闭 (2026-07-21)**：速度控制开关打开后会自动关闭。根因：`AppLauncherViewModel` 每 2 秒调用 `refreshLaunchedProcesses()`，用 `AppLauncher.getLaunchedProcesses()` 的返回值直接覆盖 ViewModel 数组，但 `AppLauncher` 的数组中 `isSpeedControlEnabled` 始终是初始值 `false`。修复：在刷新时合并现有状态，保留 `currentSpeed`、`isSpeedControlEnabled`、`isSharedMemoryConnected` 和 `speedController`。
- **加速倍率切换时间回退 (2026-07-21)**：从高速切换到低速时时间会回退。根因：倍率切换时用真实时间重置基准，导致之前加速后的时间与新基准不一致。修复：计算出当前加速后的时间，再反向推导出新的基准时间，确保时间不回退。
- **应用图标缺失 (2026-07-21)**：OpenSwift.app 在 Finder 和 Dock 中显示默认 macOS 图标。修复：创建 `OpenSwift/Assets.xcassets/AppIcon.appiconset/` 目录，生成包含 16x16、32x32、128x128、256x256、512x512（含 @2x）尺寸的图标文件和 Contents.json 配置，编译后应用显示蓝色速度风格图标。
- **加速倍率切换时间跳变 (2026-07-21)**：从低速切换到高速时时间会往前跳，从高速切换到低速时时间会停顿几秒钟。修复：在 `speedpatch.c` 的 `hooked_clock_gettime` 中实现平滑过渡算法，当倍率或激活状态变化时，基于当前真实时间和上一次返回的加速时间计算新基准：`base_new = (T_real * ratio - T_last) / (ratio - 1)`，确保时间连续平滑过渡。
- **SwiftLint 误报 (2026-07-21)**：`swiftlint lint --strict` 检查到 `build/` 目录下自动生成的 `GeneratedAssetSymbols.swift` 文件违规。修复：在 `.swiftlint.yml` 中添加 `excluded: - build/ - DerivedData/`，排除编译生成文件。
- **退出崩溃修复 (2026-07-21)**：点击窗口关闭按钮或按 Cmd+Q 退出时出现 `EXC_BAD_ACCESS` 崩溃。根因：`applicationWillTerminate` 中同步执行 `cleanupAll()` 导致线程安全问题和对象释放冲突。修复：将 `cleanupAll()` 移到后台队列异步执行，避免主线程释放冲突。
- **应用图标更新 (2026-07-21)**：更新应用图标为仪表盘风格的速度主题设计，包含 16x16、32x32、128x128、256x256、512x512（含 @2x）尺寸，体现速度控制软件的专业形象。
- **退出崩溃修复 v2 (2026-07-21)**：应用退出时仍然崩溃。根因：`ProcessManager.deinit` 和 `applicationWillTerminate` 都调用了 `cleanupAll()`，导致双重清理和对象过度释放；`SpeedControlManager.deinit` 使用 `ioQueue.sync` 可能导致死锁。修复：移除 `ProcessManager.deinit` 中的 `cleanupAll()` 调用；将 `SpeedControlManager.deinit` 中的 `ioQueue.sync` 改为 `ioQueue.async`；恢复 `applicationWillTerminate` 中的 `cleanupAll()` 同步调用。验证：三次退出测试均无崩溃。
- **退出崩溃修复 v3 (2026-07-21)**：应用退出时仍然崩溃。根因：`deinit` 中的通知观察器移除与 `applicationWillTerminate` 的资源清理存在竞争，导致自动释放池弹出阶段访问已释放对象。修复：为 `MenuBarController`、`AppLauncherViewModel`、`ProcessManager`、`AppLauncher` 添加显式 `shutdown()` 方法，将通知观察器移除从 `deinit` 迁移到 `shutdown()`；重构 `applicationWillTerminate` 按正确顺序清理：UI（状态栏）→ timer → 窗口释放 → 业务对象 shutdown → 保存设置 → `cleanupAll()`。禁用 SwiftLint `notification_center_detachment` 规则以支持显式清理模式。验证：连续 5 次退出测试无崩溃，速度控制 2x 加速正常。
- **退出崩溃修复 v4 (2026-07-21)**：应用退出时仍然崩溃。根因：`ContentView` 中使用 `@StateObject` 持有全局单例（`SpeedControlState.shared`、`HotkeyService.shared`、`AppSettings.shared`、`AppLauncherViewModel.shared`），SwiftUI 的生命周期管理与手动管理冲突，导致引用计数混乱；`onAppear` 中添加的 `OpenAppSelector` 通知观察器未在 `onDisappear` 中移除。修复：移除 `@StateObject` 对单例的持有，改为直接通过 `.shared` 访问；添加 `onDisappear` 正确移除通知观察器；使用 `NSObjectProtocol` 保存观察器引用。验证：连续 5 次退出测试无崩溃，速度控制 2x 加速正常。
- **退出崩溃修复 v5 (2026-07-21)**：应用无法正常退出，`applicationWillTerminate` 完整执行后进程仍在运行（卡在 RunLoop 等待事件），用户看到"意外退出"。根因：`HotkeyService` 使用 `NSEvent.addGlobalMonitorForEvents` 注册的全局事件监听器在退出时未被清理，该监听器在 RunLoop 中注册事件源，保持 RunLoop 活跃，阻止应用正常退出。之前的测试用 `kill` 发送 SIGTERM 直接终止进程，绕过了 AppKit 退出流程，所以未能发现此问题。修复：在 `applicationWillTerminate` 的 UI 清理步骤中添加 `HotkeyService.shared.unregisterHotkeys()` 调用，确保全局事件监听器在退出前被移除。验证：连续 5 次正常退出测试均在 1 秒内完成，无崩溃日志，速度控制 2x 加速正常。
- **退出崩溃修复 v6 (2026-07-21)**：应用退出时仍然崩溃，崩溃发生在 `objc_release`，线程栈显示 `_AXXMIGPerformAction`（辅助功能 API），`voucherInfos` 显示 `originatorName: System Events`。根因：当用户点击关闭按钮时，`NSEvent.addGlobalMonitorForEvents` 注册的全局事件监听器依赖辅助功能权限，虽然调用了 `unregisterHotkeys()`，但辅助功能系统（System Events）仍然可能有未完成的回调，这些回调持有对已释放对象的引用，导致 `objc_release` 访问无效内存。修复：调整 `applicationWillTerminate` 中清理顺序，将 `HotkeyService.shared.unregisterHotkeys()` 移到最先执行，确保全局快捷键监听器在其他资源清理前被移除，避免辅助功能系统回调已释放对象。验证：连续 5 次正常退出测试均通过，无崩溃日志，速度控制 2x 加速正常。
- **整体重构 (2026-07-21)**：对整个项目进行架构重构，包括：
  - **生命周期管理**：为所有服务类（ProcessManager、SpeedControlManager、HotkeyService、AppLauncher、MenuBarController 等）添加显式 `shutdown()` 方法，将清理逻辑从 `deinit` 迁移到 `shutdown()`，在 `applicationWillTerminate` 中按正确顺序调用
  - **线程安全**：为 ProcessManager 添加 `stateQueue` DispatchQueue，串行化所有共享状态访问（injectedProcesses、processGroups、speedControllers 等），防止数据竞争
  - **模块化**：将 ProcessManager 的右键菜单功能拆分到 `ProcessManager+ContextMenu.swift` 扩展文件，降低主文件复杂度
  - **代码质量**：修复所有 SwiftLint 违规，确保代码符合项目规范
  - **验证**：编译通过，GitHub Actions Build 和 SwiftLint 均成功，功能完整性保持不变
- **SwiftUI 迁移 (2026-07-21)**：将应用从混合架构（SwiftUI + AppKit）迁移到纯 SwiftUI：
  - **部署目标提升**：从 macOS 12.0 提升到 macOS 13.0，以支持 `MenuBarExtra` 等 SwiftUI macOS 13 特性
  - **应用入口重写**：删除 `OpenSwift/App/main.swift` 和 `AppDelegate`，使用纯 SwiftUI `@main` + `App` 协议 + `Window` 场景管理主窗口
  - **菜单栏重写**：删除 `MenuBarController` 中的 `NSStatusBar`/`NSStatusItem`/`NSMenu` 代码，改用 SwiftUI `MenuBarExtra`，绑定 `AppSettings.showInMenuBar` 控制显示/隐藏
  - **菜单系统重写**：使用 SwiftUI `Commands`、`CommandMenu` 和 `CommandGroup` 替代 `NSMenu` 手动菜单
  - **退出清理迁移**：使用 `CommandGroup(replacing: .appTermination)` 处理退出时的资源清理，不再依赖 `applicationWillTerminate`
  - **验证**：编译通过，SwiftLint 无违规，GitHub Actions Build 和 SwiftLint 均成功
- **启动崩溃修复 (2026-07-21)**：SwiftUI 迁移后应用启动立即崩溃，崩溃发生在类型元数据解码阶段，递归调用 `GraphHost.flushTransactions()` 超过 1700 次导致堆栈溢出。根因：`OpenSwiftApp.swift` 中使用 `@StateObject` 持有单例 `AppSettings.shared`，SwiftUI 尝试管理单例生命周期导致冲突；`MenuBarExtra` 的 `isInserted` 绑定到单例的 `@Published` 属性，导致状态变化触发递归更新。修复：将 `@StateObject` 替换为本地 `@State` 变量管理 `showMenuBar` 状态，移除对 `AppSettings` 单例的环境对象依赖，直接通过 `AppSettings.shared` 访问或使用 `@Binding` 传递状态。验证：编译通过，SwiftLint 无违规，应用启动正常。
- **HomeBrew 上架 (2026-07-21)**：创建 HomeBrew Tap 支持，包含 Formula（CLI）和 Cask（GUI）：
  - **Formula**: `Formula/openswift.rb` - 安装 CLI 工具到 `/usr/local/bin/openswift`
  - **Cask**: `Casks/openswift.rb` - 安装 GUI 应用到 `/Applications/OpenSwift.app`
  - **README 更新**: 添加 HomeBrew 安装说明（Tap、CLI、Cask 命令）
  - **使用方式**: `brew tap JiangWanZhengChouYv/OpenSwift && brew install openswift && brew install --cask openswift`
- **HomeBrew Cask 提交 (2026-07-21)**：提交 PR 到官方 homebrew-cask 仓库：
  - **移除 Formula**: 删除 `Formula/openswift.rb`（CLI 由应用自动安装）
  - **Cask 更新**: 添加 `license "MIT"` 字段以符合官方规范
  - **README 简化**: 仅保留 `brew install --cask openswift` 安装方式
  - **PR**: https://github.com/Homebrew/homebrew-cask/pull/276238
- **HomeBrew Tap 安装方式 (2026-07-21)**：因官方 Cask 需要代码签名和仓库知名度，改为使用 Tap 方式：
  - **安装方式**: `brew tap JiangWanZhengChouYv/openswift https://github.com/JiangWanZhengChouYv/OpenSwift && brew trust jiangwanzhengchouyv/openswift && brew install --cask openswift`
  - **更新 README**: 添加 Tap 安装说明，使用完整 URL 方式 tap（因仓库名非 homebrew-xxx 格式），包含 trust 步骤和 xattr 隔离属性移除说明
  - **官方 Cask**: 等待项目积累足够 stars（>225）和代码签名后重新提交
