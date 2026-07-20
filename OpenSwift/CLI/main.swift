import Foundation
import AppKit

/// OpenSwift CLI 入口点
/// 负责解析命令行参数并调用相应的命令

/// 显示帮助信息
func showHelp() {
    let helpText = """
OpenSwift CLI - macOS 应用加速器命令行工具

用法:
  openswift <目录>              智能模式（运行中则重启，否则启动）
  openswift -o <目录>           DYLD 启动模式（直接以 DYLD 注入方式启动）
  openswift -r <目录>           DYLD 重启模式（先终止已运行进程，再启动）
  openswift speed <pid> <ratio> 设置目标进程的加速倍率（0.1~10.0）
  openswift quit <pid>          复位加速并清理目标进程的共享内存

选项:
  -h, --help                    显示此帮助信息

示例:
  openswift /Applications/MyApp.app
  openswift -o ./testapp
  openswift -r /Applications/MyApp.app
  openswift speed 12345 2.0     # 设置 2x 加速
  openswift quit 12345          # 复位加速并清理共享内存
"""
    let data = helpText.data(using: .utf8) ?? Data()
    FileHandle.standardOutput.write(data)
}

/// 输出错误信息到 stderr
func writeError(_ message: String) {
    let data = (message + "\n").data(using: .utf8) ?? Data()
    FileHandle.standardError.write(data)
}

// MARK: - 参数解析与入口

let arguments = CommandLine.arguments

// 无参数时显示帮助并以状态码 1 退出
if arguments.count < 2 {
    showHelp()
    exit(1)
}

let firstArg = arguments[1]

// 处理帮助选项
if firstArg == "-h" || firstArg == "--help" {
    showHelp()
    exit(0)
}

// 处理子命令：speed / quit
if firstArg == "speed" {
    // openswift speed <pid> <ratio>
    guard arguments.count >= 4 else {
        writeError("错误：speed 命令需要 <pid> 和 <ratio> 参数")
        writeError("用法：openswift speed <pid> <ratio>")
        exit(1)
    }

    guard let pid = pid_t(arguments[2]) else {
        writeError("错误：无效的 PID - \(arguments[2])")
        exit(1)
    }

    guard let ratio = Float(arguments[3]) else {
        writeError("错误：无效的速度倍率 - \(arguments[3])")
        exit(1)
    }

    let exitCode = setSpeed(pid: pid, ratio: ratio)
    exit(exitCode)
}

if firstArg == "quit" {
    // openswift quit <pid>
    guard arguments.count >= 3 else {
        writeError("错误：quit 命令需要 <pid> 参数")
        writeError("用法：openswift quit <pid>")
        exit(1)
    }

    guard let pid = pid_t(arguments[2]) else {
        writeError("错误：无效的 PID - \(arguments[2])")
        exit(1)
    }

    let exitCode = quitAndCleanup(pid: pid)
    exit(exitCode)
}

// 解析命令模式和目标路径
let mode: String
let targetPath: String

if firstArg == "-o" || firstArg == "-r" {
    // 带选项的命令格式：openswift -o <目录> 或 openswift -r <目录>
    guard arguments.count >= 3 else {
        writeError("错误：缺少目标路径参数")
        showHelp()
        exit(1)
    }
    mode = firstArg
    targetPath = arguments[2]
} else if firstArg.hasPrefix("-") {
    // 未知的选项
    writeError("错误：未知选项 \(firstArg)")
    showHelp()
    exit(1)
} else {
    // 智能模式：openswift <目录>
    mode = ""
    targetPath = firstArg
}

// 执行对应的命令
let exitCode: Int32
switch mode {
case "-o":
    exitCode = launchWithDYLD(at: targetPath)
case "-r":
    exitCode = restartWithDYLD(at: targetPath)
default:
    exitCode = smartMode(at: targetPath)
}

exit(exitCode)
