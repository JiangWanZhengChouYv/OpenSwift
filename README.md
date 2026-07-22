# OpenSwift

[![Build Status](https://img.shields.io/github/actions/workflow/status/JiangWanZhengChouYv/OpenSwift/build.yml?branch=main&label=Build&logo=github)](https://github.com/JiangWanZhengChouYv/OpenSwift/actions/workflows/build.yml)
[![SwiftLint](https://img.shields.io/github/actions/workflow/status/JiangWanZhengChouYv/OpenSwift/swiftlint.yml?branch=main&label=SwiftLint&logo=swift)](https://github.com/JiangWanZhengChouYv/OpenSwift/actions/workflows/swiftlint.yml)
[![Release](https://img.shields.io/github/v/release/JiangWanZhengChouYv/OpenSwift?label=Release&logo=github)](https://github.com/JiangWanZhengChouYv/OpenSwift/releases)
[![License](https://img.shields.io/github/license/JiangWanZhengChouYv/OpenSwift?label=License&logo=opensourceinitiative)](https://github.com/JiangWanZhengChouYv/OpenSwift/blob/main/LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B-007AFF?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.0%2B-FA7343?logo=swift)](https://swift.org/)
[![Stars](https://img.shields.io/github/stars/JiangWanZhengChouYv/OpenSwift?style=social)](https://github.com/JiangWanZhengChouYv/OpenSwift/stargazers)

一个用于 macOS 的进程速度控制工具，通过注入 C 动态库拦截目标进程的时间函数，实现对进程运行速度的实时调节（0.1x ~ 10x 倍速）。

[English](README_EN.md) | **中文**

---

## 功能特性

- **实时速度控制**：通过滑块或快捷按钮调节目标进程的运行速度，支持 0.1x 慢速到 10x 快速
- **多进程独立管理**：可同时启动多个进程，每个进程拥有独立的速度控制与状态显示
- **全局快捷键支持**：支持自定义全局快捷键（加速、减速、切换开关、重置等），无需切换窗口即可操作
- **应用启动器**：通过 AppLauncher 以 `DYLD_INSERT_LIBRARIES` 方式注入启动应用，支持 `.app` 包与普通可执行文件
- **进程列表与菜单栏集成**：侧栏显示已启动的进程状态（运行时间、速度、共享内存连接状态），窗口可最小化到菜单栏
- **命令行工具**：内置 `openswift` CLI，支持命令行启动、速度控制、清理等操作
- **平滑变速过渡**：倍率切换时自动平滑过渡，避免时间跳变或回退

## 使用场景

| 场景 | 描述 |
|------|------|
| 🎮 **游戏加速/减速** | 加速跳过冗长剧情，或减速挑战高难度操作 |
| 🔧 **软件测试** | 加速自动化测试，或慢速复现偶发 Bug |
| 🎬 **动画调试** | 减慢 UI 动画速度，精确观察动画细节 |
| 🔬 **逆向分析** | 控制目标进程时间流速，辅助动态分析 |
| ⏱️ **计时类应用测试** | 验证倒计时、计时器等时间相关功能 |

## 同类工具对比

| 特性 | OpenSwift | OpenSpeedy | Cheat Engine | Speed Hack |
|------|-----------|------------|--------------|------------|
| 支持平台 | macOS | Windows | Windows | Windows |
| 开源免费 | ✅ | ✅ | ✅ | ❌ |
| SwiftUI 原生界面 | ✅ | ❌ | ❌ | ❌ |
| 全局快捷键 | ✅ | ✅ | ✅ | ❌ |
| 多进程独立管理 | ✅ | ✅ | ✅ | ❌ |
| 菜单栏集成 | ✅ | ❌ | ❌ | ❌ |
| 命令行工具 | ✅ | ❌ | ❌ | ❌ |
| 注入已运行进程 | ❌（仅启动时注入） | ✅ | ✅ | ✅ |

---

## 快速开始

### 通过 HomeBrew Tap 安装（推荐）

```bash
# 添加 Tap
brew tap JiangWanZhengChouYv/openswift https://github.com/JiangWanZhengChouYv/OpenSwift

# 信任 Tap（第三方 Tap 需要手动信任）
brew trust jiangwanzhengchouyv/openswift

# 安装 GUI 应用
brew install --cask openswift
```

> 应用启动时会自动安装 `openswift` CLI 工具到系统路径。

**首次打开提示"已损坏"？** 执行以下命令移除隔离属性：

```bash
xattr -d com.apple.quarantine /Applications/OpenSwift.app
```

或右键点击应用 → 选择"打开"。

### 从 GitHub Releases 下载

直接从 [Releases 页面](https://github.com/JiangWanZhengChouYv/OpenSwift/releases) 下载最新版本的 ZIP 包，解压后将 `OpenSwift.app` 拖入 Applications 文件夹。

### 手动编译

#### 1. 环境要求

- **操作系统**：macOS 13.0 及以上
- **Xcode**：15.0+，命令行工具（`xcode-select --install`）
- **Swift**：5.0+
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**：用于从 `project.yml` 生成 Xcode 工程
- **SIP（System Integrity Protection）**：对目标可执行文件进行 dylib 注入时，可能需要部分禁用 SIP（可用于开发测试环境）

#### 2. 生成 Xcode 项目并运行

```bash
cd /Users/markzhang/Documents/OpenSpeedy-Mac
xcodegen generate        # 生成 OpenSwift.xcodeproj
open OpenSwift.xcodeproj # 在 Xcode 中打开并运行
```

> `project.yml` 已定义两个目标：`OpenSwift`（应用）与 `SpeedPatch`（dylib bundle）。`SpeedPatch.dylib` 会被嵌入到 `OpenSwift.app/Contents/PlugIns/SpeedPatch/` 中。

#### 3. 使用 OpenSwift

1. 在主界面点击"选择应用"，选择任意可执行文件或 `.app` 包
2. AppLauncher 会以 `DYLD_INSERT_LIBRARIES=SpeedPatch.dylib` 启动该应用
3. 在侧栏的进程列表中选中新启动的进程
4. **拖动滑块**调整速度（0.1x ~ 10x），或点击**快捷按钮**（0.5x、1x、2x、5x）
5. 观察目标进程——运行速度会随倍率变化

---

## 技术架构

整体采用三层架构：

1. **SwiftUI 主应用（`OpenSwift/`）**：提供 UI、进程管理、速度控制面板与全局快捷键服务
2. **C 动态库（`SpeedPatch/SpeedPatch.dylib`）**：通过 `fishhook` 拦截进程的时间函数，改写其对系统时间的感知
3. **POSIX 共享内存（`shm_open` + `mmap`）**：作为 OpenSwift 与目标进程之间的 IPC 通道，传递速度倍率与开关状态

**关键模块：**

| 模块 | 文件 | 职责 |
| ---- | ---- | ---- |
| SpeedControlManager | `OpenSwift/Services/SpeedControlManager.swift` | 管理与目标进程的共享内存连接，写入速度倍率与开关 |
| AppLauncher | `OpenSwift/Services/AppLauncher.swift` | 以 `DYLD_INSERT_LIBRARIES` 方式启动目标应用并注入 dylib |
| ProcessManager | `OpenSwift/Services/ProcessManager.swift` | 维护已注入进程的状态（PID、运行状态、共享内存连接） |
| HotkeyService | `OpenSwift/Services/HotkeyService.swift` | 注册/监听全局快捷键，映射到速度调节动作 |
| CLIManager | `OpenSwift/Services/CLIManager.swift` | 自动安装/更新 `openswift` CLI 工具 |
| SpeedPatch.dylib | `SpeedPatch/speedpatch.c` | 拦截 `mach_absolute_time`、`clock_gettime`、`gettimeofday`、`sleep`、`usleep`、`clock`、`CFAbsoluteTimeGetCurrent` 等时间函数 |
| fishhook | `SpeedPatch/fishhook.c` | Facebook 开源的 Mach-O 符号重绑定工具 |

### 工作原理

OpenSwift 的核心在于**用"假时间"替代目标进程感知到的"真时间"**。具体流程：

1. **启动与注入**：AppLauncher 通过设置环境变量 `DYLD_INSERT_LIBRARIES` 启动目标进程，使 dyld 在加载主程序前先加载 `SpeedPatch.dylib`。
2. **共享内存创建**：dylib 的 `constructor` 函数创建一块以 PID 命名的 POSIX 共享内存（`shm_open` + `mmap`）。
3. **函数重绑定**：调用 fishhook 把时间函数替换为带缩放逻辑的 hooked 版本。
4. **OpenSwift 连接共享内存**：Swift 端连接同一块共享内存。
5. **双向同步**：OpenSwift 写入速度倍率和开关状态，目标进程读取后缩放时间。
6. **清理**：进程退出时自动释放共享内存。

---

## CLI 命令行工具

OpenSwift 提供独立的 CLI 工具 `openswift`，应用启动时会自动安装到系统路径。

```bash
# 启动应用（自动注入 SpeedPatch）
openswift -o /Applications/MyApp.app

# 设置加速倍率
openswift speed <pid> 2.0

# 退出清理
openswift quit <pid>

# 帮助信息
openswift --help
```

---

## 路线图 Roadmap

### 短期（v0.x）
- [ ] **注入已运行进程**：支持对正在运行的进程注入 SpeedPatch（通过 task_for_pid 或 DYLD 注入）
- [ ] **预设速度配置**：支持保存和加载常用速度预设（游戏模式、测试模式等）
- [ ] **进程分组管理**：支持对多个进程进行分组，统一控制速度
- [ ] **速度热键配置增强**：支持针对不同进程设置独立的快捷键

### 中期（v1.x）
- [ ] **更多时间函数 Hook**：支持 `dispatch_after`、`NSTimer`、`CADisplayLink` 等
- [ ] **自动更新**：集成 Sparkle 实现应用内自动更新
- [ ] **国际化**：支持中英文双语
- [ ] **插件系统**：支持自定义脚本扩展功能

### 长期（v2.x）
- [ ] **内存修改功能**：类似 Cheat Engine 的内存搜索和修改
- [ ] **调试器集成**：集成 LLDB 调试功能
- [ ] **iOS 支持**：通过 USB 连接 iOS 设备进行速度控制
- [ ] **插件市场**：用户可分享和下载插件

---

## 常见问题 FAQ

### Q: 为什么应用打开提示"已损坏"？
A: 因为应用未经 Apple 公证，macOS 的 Gatekeeper 会阻止打开。执行 `xattr -d com.apple.quarantine /Applications/OpenSwift.app` 或右键点击选择"打开"即可。

### Q: 为什么注入后应用没反应？
A: 可能的原因：1) 目标应用有 SIP 保护，无法注入；2) 目标应用使用了不支持的时间函数；3) 共享内存连接失败。可以尝试用 TestApp 先测试注入是否正常。

### Q: 支持哪些时间函数？
A: 目前支持 `mach_absolute_time`、`clock_gettime`、`gettimeofday`、`sleep`、`usleep`、`clock`、`CFAbsoluteTimeGetCurrent`。对于 `DispatchSourceTimer`、`NSTimer` 等基于 RunLoop 的定时器，只要底层依赖上述时间函数就会生效。

### Q: 会被检测为外挂吗？
A: 本工具仅修改进程的时间感知，不修改游戏数据或内存。但某些带有反作弊系统的在线游戏可能会检测到 DYLD 注入，请谨慎使用，后果自负。

### Q: 为什么需要部分禁用 SIP？
A: macOS 的系统完整性保护（SIP）会阻止对系统进程和受保护应用的 DYLD 注入。对于普通用户自己下载的应用，通常不需要禁用 SIP。只有注入系统应用或某些受保护的应用时才需要。

### Q: 支持 Apple Silicon (M1/M2/M3) 吗？
A: 支持，SpeedPatch.dylib 同时包含 arm64 和 x86_64 架构。

### Q: 怎么卸载？
A: 删除 `/Applications/OpenSwift.app` 和 `/usr/local/bin/openswift`（或 `/opt/homebrew/bin/openswift`）即可。

---

## 构建命令

```bash
# 生成 Xcode 项目
xcodegen generate

# 编译项目
xcodebuild -project OpenSwift.xcodeproj -scheme OpenSwift -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# 运行 SwiftLint
swiftlint lint --strict
```

---

## 项目结构

```
OpenSpeedy-Mac/
├── OpenSwift/               # SwiftUI 主应用
│   ├── App/                 # 入口
│   ├── Models/              # 数据模型
│   ├── Services/            # 核心服务
│   ├── Views/               # UI 视图
│   ├── CLI/                 # 命令行工具
│   └── Assets.xcassets/     # 资源文件
├── SpeedPatch/              # C 语言动态库（注入用）
├── TestApp/                 # 测试应用
├── TimerTestApp/            # 计时器测试应用（SwiftUI）
├── Casks/                   # HomeBrew Cask
├── project.yml              # XcodeGen 项目定义
└── README.md
```

---

## 贡献

欢迎提交 Issue 和 Pull Request！

---

## License

MIT License — 可自由使用、修改、分发。
