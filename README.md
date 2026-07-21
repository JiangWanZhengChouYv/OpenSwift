# OpenSwift

一个用于 macOS 的进程速度控制工具，通过注入 C 动态库拦截目标进程的时间函数，实现对进程运行速度的实时调节（0.1x ~ 10x 倍速）。

## 功能特性

- **实时速度控制**：通过滑块或快捷按钮调节目标进程的运行速度，支持 0.1x 慢速到 10x 快速
- **多进程独立管理**：可同时启动多个进程，每个进程拥有独立的速度控制与状态显示
- **全局快捷键支持**：支持自定义全局快捷键（加速、减速、切换开关、重置等），无需切换窗口即可操作
- **应用启动器**：通过 AppLauncher 以 `DYLD_INSERT_LIBRARIES` 方式注入启动应用，支持 `.app` 包与普通可执行文件
- **进程列表与菜单栏集成**：侧栏显示已启动的进程状态（运行时间、速度、共享内存连接状态），窗口可最小化到菜单栏

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
| SpeedPatch.dylib | `SpeedPatch/speedpatch.c` | 拦截 `mach_absolute_time`、`clock_gettime`、`gettimeofday`、`sleep`、`usleep`、`clock`、`CFAbsoluteTimeGetCurrent` 等时间函数，按共享内存中的倍率缩放 |
| fishhook | `SpeedPatch/fishhook.c` | Facebook 开源的 Mach-O 符号重绑定工具，用于运行时替换函数实现 |
| TestApp | `TestApp/testapp.c` | 简单的 C 语言测试程序（每秒打印一次时间），用于验证注入与变速效果 |

## 项目结构

```
OpenSpeedy-Mac/
├── OpenSwift/               # SwiftUI 主应用
│   ├── App/                 # 入口（OpenSwiftApp.swift, main.swift）
│   ├── Models/              # 数据模型（HotkeyConfiguration, InjectedProcess, SpeedControlState）
│   ├── Services/            # 核心服务
│   │   ├── AppLauncher.swift
│   │   ├── AppSettings.swift
│   │   ├── ConfigurationManager.swift
│   │   ├── GlobalHotkeyManager.swift
│   │   ├── HotkeyService.swift
│   │   ├── HotkeyStorage.swift
│   │   ├── InjectionProtocol.swift
│   │   ├── LaunchAtLoginManager.swift
│   │   ├── MenuBarController.swift
│   │   ├── ProcessInjector.swift
│   │   ├── ProcessManager.swift
│   │   ├── SettingsStorage.swift
│   │   └── SpeedControlManager.swift
│   ├── Views/               # UI 视图
│   │   ├── ContentView.swift         # 主窗口
│   │   ├── SpeedControlPanel.swift   # 速度控制面板
│   │   ├── SpeedSliderView.swift     # 速度滑块
│   │   ├── QuickSpeedButtons.swift   # 快捷速度按钮
│   │   ├── SpeedToggle.swift         # 启停开关
│   │   ├── SpeedIndicator.swift      # 当前速度指示
│   │   ├── SpeedInputField.swift     # 数值输入
│   │   ├── ProcessListView.swift     # 进程列表
│   │   ├── ProcessRowView.swift      # 进程行
│   │   ├── LaunchedProcessCard.swift # 启动进程卡片
│   │   ├── ProcessControlCard.swift  # 进程控制卡片
│   │   ├── AppSelectorView.swift     # 应用选择器
│   │   ├── HotkeySettingsView.swift  # 快捷键设置
│   │   ├── HotkeyRecorderView.swift  # 快捷键录制
│   │   ├── FirstLaunchView.swift     # 新手引导
│   │   └── SettingsView.swift        # 设置
│   ├── Extensions/
│   ├── Info.plist
│   └── OpenSwift.entitlements
├── SpeedPatch/              # C 语言动态库（注入用）
│   ├── speedpatch.c         # 时间函数 hook 与共享内存逻辑
│   ├── speedpatch.h
│   ├── fishhook.c           # 符号重绑定实现
│   ├── fishhook.h
│   ├── build.sh             # 编译脚本
│   ├── Info.plist
│   └── SpeedPatch.entitlements
├── TestApp/                 # 测试应用（C 语言，每秒打印时间）
│   ├── testapp.c
│   ├── build.sh
│   └── test_injection.sh
├── project.yml              # XcodeGen 项目定义
├── .gitignore
└── README.md
```

## 快速开始

### 通过 HomeBrew 安装（推荐）

```bash
# 添加 Tap
brew tap JiangWanZhengChouYv/OpenSwift

# 安装 CLI 工具
brew install openswift

# 安装 GUI 应用
brew install --cask openswift
```

### 手动安装

#### 1. 环境要求

- **操作系统**：macOS 13.0 及以上
- **Xcode**：15.0+，命令行工具（`xcode-select --install`）
- **Swift**：5.0+
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**：用于从 `project.yml` 生成 Xcode 工程
- **SIP（System Integrity Protection）**：对目标可执行文件进行 dylib 注入时，可能需要部分禁用 SIP（可用于开发测试环境）

### 2. 编译 SpeedPatch.dylib

```bash
cd SpeedPatch
./build.sh
```

`build.sh` 使用 `clang` 以 `-dynamiclib` 方式编译 `speedpatch.c` 与 `fishhook.c`，产物为 `SpeedPatch/SpeedPatch.dylib`。

### 3. 编译 TestApp

```bash
cd TestApp
./build.sh
```

产物为 `TestApp/testapp`，一个每秒打印一次当前时间的简单程序（用于验证变速效果）。

### 4. 生成 Xcode 项目并运行 OpenSwift

```bash
cd /Users/markzhang/Documents/OpenSpeedy-Mac
xcodegen generate        # 生成 OpenSwift.xcodeproj
open OpenSwift.xcodeproj # 在 Xcode 中打开并运行
```

> `project.yml` 已定义两个目标：`OpenSwift`（应用）与 `SpeedPatch`（dylib bundle）。`SpeedPatch.dylib` 会被嵌入到 `OpenSwift.app/Contents/PlugIns/SpeedPatch/` 中。

### 5. 使用 OpenSwift

1. 在主界面点击"选择应用"，选择 `TestApp/testapp`（或任意可执行文件/`.app` 包）
2. AppLauncher 会以 `DYLD_INSERT_LIBRARIES=SpeedPatch.dylib` 启动该应用，SpeedPatch 的 `constructor` 函数会自动创建共享内存并 hook 时间函数
3. 在侧栏的进程列表中选中新启动的进程
4. **拖动滑块**调整速度（0.1x ~ 10x），或点击**快捷按钮**（0.5x、1x、2x、5x）
5. 观察目标进程输出——时间打印频率将随速度倍率变化（速度 > 1 时打印变快，< 1 时变慢）

## 工作原理

OpenSwift 的核心在于**用"假时间"替代目标进程感知到的"真时间"**。具体流程：

1. **启动与注入**：AppLauncher 通过设置环境变量 `DYLD_INSERT_LIBRARIES` 启动目标进程，使 dyld 在加载主程序前先加载 `SpeedPatch.dylib`。
2. **共享内存创建**：dylib 的 `constructor` 函数 `speedpatch_init` 创建一块以 PID 命名的 POSIX 共享内存（`shm_open` + `mmap`），写入头部（版本号、速度倍率、开关状态、时间戳）。
3. **函数重绑定**：调用 fishhook 的 `rebind_symbols` 把 `mach_absolute_time`、`clock_gettime`、`gettimeofday`、`sleep`、`usleep`、`clock`、`CFAbsoluteTimeGetCurrent` 替换为带缩放逻辑的 hooked 版本。
4. **OpenSwift 连接共享内存**：Swift 端的 `SpeedControlManager` 以同一共享内存名称 `com.openswift.speedpatch.<pid>` 打开并映射同一块内存。
5. **双向同步**：
   - OpenSwift 写入 `speed_ratio`（0.1~10.0）和 `is_active`（0/1），并调用 `msync` 刷新到物理页
   - 目标进程在每次被 hook 的时间函数中读取这些值，对返回的时间值进行 `original / ratio` 缩放，或对 sleep 时长做相同缩放
6. **清理**：当目标进程退出时，SpeedPatch 的 `destructor` 会 `munmap` 并 `shm_unlink` 释放共享内存；OpenSwift 侧也会在检测到进程终止后断开连接

## 构建命令

```bash
# 生成 Xcode 项目
cd /Users/markzhang/Documents/OpenSpeedy-Mac
xcodegen generate

# 编译 SpeedPatch.dylib
cd SpeedPatch && ./build.sh

# 编译 TestApp
cd ../TestApp && ./build.sh
```

## 目录权限说明

- `.gitignore` 已正确配置，`xcuserdata/`、`DerivedData/`、用户私有 schemes、编译产物（`*.dylib`、`testapp` 等）不会被提交
- XcodeGen 生成的 `OpenSwift.xcodeproj/` 为临时产物，内容由 `project.yml` 管理

## License

MIT License — 可自由使用、修改、分发。
