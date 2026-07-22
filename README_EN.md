# OpenSwift

[![Build Status](https://img.shields.io/github/actions/workflow/status/JiangWanZhengChouYv/OpenSwift/build.yml?branch=main&label=Build&logo=github)](https://github.com/JiangWanZhengChouYv/OpenSwift/actions/workflows/build.yml)
[![SwiftLint](https://img.shields.io/github/actions/workflow/status/JiangWanZhengChouYv/OpenSwift/swiftlint.yml?branch=main&label=SwiftLint&logo=swift)](https://github.com/JiangWanZhengChouYv/OpenSwift/actions/workflows/swiftlint.yml)
[![Release](https://img.shields.io/github/v/release/JiangWanZhengChouYv/OpenSwift?label=Release&logo=github)](https://github.com/JiangWanZhengChouYv/OpenSwift/releases)
[![License](https://img.shields.io/github/license/JiangWanZhengChouYv/OpenSwift?label=License&logo=opensourceinitiative)](https://github.com/JiangWanZhengChouYv/OpenSwift/blob/main/LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B-007AFF?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.0%2B-FA7343?logo=swift)](https://swift.org/)
[![Stars](https://img.shields.io/github/stars/JiangWanZhengChouYv/OpenSwift?style=social)](https://github.com/JiangWanZhengChouYv/OpenSwift/stargazers)

A macOS process speed control tool that intercepts time functions of target processes via C dynamic library injection, enabling real-time speed adjustment (0.1x ~ 10x).

**English** | [**中文**](README.md)

---

## Features

- **Real-time Speed Control**: Adjust target process speed via slider or quick buttons, supporting 0.1x slow to 10x fast
- **Multi-process Management**: Launch multiple processes simultaneously, each with independent speed control and status display
- **Global Hotkeys**: Customizable global hotkeys (speed up, slow down, toggle, reset, etc.) — no window switching needed
- **App Launcher**: Inject and launch apps via `DYLD_INSERT_LIBRARIES`, supporting both `.app` bundles and standalone executables
- **Menu Bar Integration**: Sidebar shows process status (uptime, speed, shared memory connection); window can minimize to menu bar
- **CLI Tool**: Built-in `openswift` CLI for launching, speed control, and cleanup from the command line
- **Smooth Speed Transitions**: Automatic smooth transition on speed change, preventing time jumps or rollback

## Use Cases

| Scenario | Description |
|----------|-------------|
| 🎮 **Game Speed** | Speed up to skip cutscenes, or slow down for difficult sections |
| 🔧 **Software Testing** | Accelerate automated tests, or slow down to reproduce bugs |
| 🎬 **Animation Debugging** | Slow down UI animations to observe every detail |
| 🔬 **Reverse Engineering** | Control target process time flow for dynamic analysis |
| ⏱️ **Timer Testing** | Verify countdowns, timers, and other time-related features |

## Comparison

| Feature | OpenSwift | Cheat Engine | Speed Hack |
|---------|-----------|--------------|------------|
| Platform | macOS | Windows | Windows |
| Open Source | ✅ | ✅ | ❌ |
| Native SwiftUI UI | ✅ | ❌ | ❌ |
| Global Hotkeys | ✅ | ✅ | ❌ |
| Multi-process | ✅ | ✅ | ❌ |
| Menu Bar | ✅ | ❌ | ❌ |
| CLI Tool | ✅ | ❌ | ❌ |
| Inject Running Process | ❌ (launch-time only) | ✅ | ✅ |

---

## Quick Start

### Install via HomeBrew Tap (Recommended)

```bash
# Add Tap
brew tap JiangWanZhengChouYv/openswift https://github.com/JiangWanZhengChouYv/OpenSwift

# Trust Tap (required for third-party taps)
brew trust jiangwanzhengchouyv/openswift

# Install GUI app
brew install --cask openswift
```

> The app automatically installs the `openswift` CLI tool to your system PATH on launch.

**"App is damaged" on first launch?** Run this to remove the quarantine attribute:

```bash
xattr -d com.apple.quarantine /Applications/OpenSwift.app
```

Or right-click the app → select "Open".

### Download from GitHub Releases

Download the latest ZIP from the [Releases page](https://github.com/JiangWanZhengChouYv/OpenSwift/releases), unzip, and drag `OpenSwift.app` to your Applications folder.

### Build from Source

#### 1. Requirements

- **OS**: macOS 13.0+
- **Xcode**: 15.0+, Command Line Tools (`xcode-select --install`)
- **Swift**: 5.0+
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**: Generates Xcode project from `project.yml`
- **SIP (System Integrity Protection)**: May need partial SIP disable for dylib injection (for dev/testing)

#### 2. Generate Xcode Project and Run

```bash
xcodegen generate
open OpenSwift.xcodeproj
```

#### 3. Using OpenSwift

1. Click "Select App" in the main interface and choose any executable or `.app` bundle
2. AppLauncher launches the app with `DYLD_INSERT_LIBRARIES=SpeedPatch.dylib`
3. Select the newly launched process in the sidebar
4. **Drag the slider** to adjust speed (0.1x ~ 10x), or click **quick buttons** (0.5x, 1x, 2x, 5x)
5. Observe the target process — speed changes with the ratio

---

## Technical Architecture

Three-layer architecture:

1. **SwiftUI App (`OpenSwift/`)**: UI, process management, speed control panel, global hotkey service
2. **C Dynamic Library (`SpeedPatch/SpeedPatch.dylib`)**: Intercepts time functions via `fishhook`
3. **POSIX Shared Memory (`shm_open` + `mmap`)**: IPC channel between OpenSwift and target process

### How It Works

OpenSwift replaces the "real time" that target processes perceive with "fake time":

1. **Injection**: AppLauncher sets `DYLD_INSERT_LIBRARIES` to load `SpeedPatch.dylib` before the main program
2. **Shared Memory**: dylib's `constructor` creates POSIX shared memory named by PID
3. **Function Rebinding**: fishhook replaces time functions with scaled versions
4. **Connection**: OpenSwift connects to the same shared memory
5. **Sync**: OpenSwift writes speed ratio and active flag; target process reads and scales time
6. **Cleanup**: Shared memory is automatically released on process exit

---

## CLI Tool

OpenSwift includes a standalone `openswift` CLI, auto-installed to system PATH on app launch.

```bash
# Launch app (auto-inject SpeedPatch)
openswift -o /Applications/MyApp.app

# Set speed ratio
openswift speed <pid> 2.0

# Cleanup
openswift quit <pid>

# Help
openswift --help
```

---

## Roadmap

### Short-term (v0.x)
- [ ] **Inject running processes**: Support injecting SpeedPatch into already-running processes
- [ ] **Speed presets**: Save and load common speed configurations (game mode, test mode, etc.)
- [ ] **Process groups**: Group multiple processes for unified speed control
- [ ] **Per-process hotkeys**: Independent hotkey configurations for different processes

### Mid-term (v1.x)
- [ ] **More time function hooks**: `dispatch_after`, `NSTimer`, `CADisplayLink`, etc.
- [ ] **Auto-update**: Integrate Sparkle for in-app updates
- [ ] **i18n**: Multi-language support
- [ ] **Plugin system**: Custom script extensions

### Long-term (v2.x)
- [ ] **Memory editing**: Cheat Engine-style memory search and modification
- [ ] **Debugger integration**: LLDB integration
- [ ] **iOS support**: Speed control for iOS devices via USB
- [ ] **Plugin marketplace**: Share and download community plugins

---

## FAQ

### Q: Why does the app say "damaged" on launch?
A: The app is not notarized by Apple, so macOS Gatekeeper blocks it. Run `xattr -d com.apple.quarantine /Applications/OpenSwift.app` or right-click → "Open".

### Q: Why is the injected app not responding?
A: Possible reasons: 1) SIP protection prevents injection; 2) The app uses unsupported time functions; 3) Shared memory connection failed. Try testing with the included TestApp first.

### Q: Which time functions are supported?
A: Currently supports `mach_absolute_time`, `clock_gettime`, `gettimeofday`, `sleep`, `usleep`, `clock`, `CFAbsoluteTimeGetCurrent`. RunLoop-based timers (`NSTimer`, `DispatchSourceTimer`) work if they depend on these functions internally.

### Q: Will this be detected as a cheat?
A: This tool only modifies process time perception — it doesn't modify game data or memory. However, online games with anti-cheat systems may detect DYLD injection. Use at your own risk.

### Q: Why do I need to disable SIP?
A: macOS SIP prevents DYLD injection into system processes and protected apps. For regular user-downloaded apps, SIP usually doesn't need to be disabled. It's only needed for system apps or protected applications.

### Q: Does it support Apple Silicon (M1/M2/M3)?
A: Yes, SpeedPatch.dylib includes both arm64 and x86_64 architectures.

### Q: How to uninstall?
A: Delete `/Applications/OpenSwift.app` and `/usr/local/bin/openswift` (or `/opt/homebrew/bin/openswift`).

---

## Build

```bash
# Generate Xcode project
xcodegen generate

# Build
xcodebuild -project OpenSwift.xcodeproj -scheme OpenSwift -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Lint
swiftlint lint --strict
```

---

## Contributing

Issues and Pull Requests are welcome!

---

## License

MIT License — free to use, modify, and distribute.
