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
  openswift speed <pid> <ratio> 设置目标进程的加速倍率（0.1~15.0）
  openswift quit <pid>          复位加速并清理目标进程的共享内存
  openswift patch <源.app> [输出.app]  为应用生成静态注入版本（无需 OpenSwift 启动）

选项:
  -h, --help                    显示此帮助信息

示例:
  openswift /Applications/MyApp.app
  openswift -o ./testapp
  openswift -r /Applications/MyApp.app
  openswift speed 12345 2.0     # 设置 2x 加速
  openswift quit 12345          # 复位加速并清理共享内存
  openswift patch /Applications/MyApp.app /Applications/MyApp_Speed.app
  openswift patch /Applications/MyApp.app          # 同目录生成 MyApp_Patched.app
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

if firstArg == "patch" {
    guard arguments.count >= 3 else {
        writeError("错误：patch 命令需要 <源.app> 参数")
        writeError("用法：openswift patch <源.app> [输出.app]")
        exit(1)
    }

    let source = URL(fileURLWithPath: arguments[2])
    let output: URL
    if arguments.count >= 4 {
        output = URL(fileURLWithPath: arguments[3])
    } else {
        let baseName = source.deletingPathExtension().lastPathComponent
        output = source.deletingLastPathComponent()
            .appendingPathComponent(baseName + "_Patched")
            .appendingPathExtension("app")
    }

    do {
        let resultURL = try patchAppCLI(source: source, output: output)
        let data = ("Patched: \(resultURL.path)\n").data(using: .utf8) ?? Data()
        FileHandle.standardOutput.write(data)
        exit(0)
    } catch {
        writeError("Error: \(error.localizedDescription)")
        exit(1)
    }
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

// MARK: - Patch 子命令辅助函数

private func runPatchCommand(_ path: String, _ args: [String]) throws {
    let p = Process()
    p.launchPath = path
    p.arguments = args
    let pipe = Pipe()
    p.standardError = pipe
    p.standardOutput = pipe
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "openswift.patch", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

private func getCLIExecutableURL() -> URL {
    if let exePath = Bundle.main.executablePath {
        return URL(fileURLWithPath: exePath)
    }
    return URL(fileURLWithPath: CommandLine.arguments[0])
}

private func getDylibPathForCLI() -> String? {
    let fm = FileManager.default
    let cliURL = getCLIExecutableURL()
    let cliDir = cliURL.deletingLastPathComponent()
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

    let bundleSubpath = "Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch"
    let bundleSubpath2 = "Contents/PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch"

    if let envPath = ProcessInfo.processInfo.environment["OPENSWIFT_DYLIB_PATH"] {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: envPath, isDirectory: &isDir) {
            if !isDir.boolValue {
                return envPath
            }
            let dirURL = URL(fileURLWithPath: envPath)
            let candidates = [
                dirURL.appendingPathComponent("SpeedPatch").path,
                dirURL.appendingPathComponent("SpeedPatch.dylib/Contents/MacOS/SpeedPatch").path,
                dirURL.appendingPathComponent(bundleSubpath).path
            ]
            for p in candidates {
                if fm.fileExists(atPath: p) { return p }
            }
        }
    }

    let candidates = [
        cliDir.appendingPathComponent("PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch").path,
        cliDir.appendingPathComponent("PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch").path,
        cliDir.appendingPathComponent("OpenSwift.app/\(bundleSubpath)").path,
        cwd.appendingPathComponent("SpeedPatch.dylib").path,
        cwd.appendingPathComponent("OpenSwift.app/\(bundleSubpath)").path,
        cwd.appendingPathComponent("OpenSwift.app/\(bundleSubpath2)").path
    ]

    for p in candidates {
        if fm.fileExists(atPath: p) {
            return p
        }
    }

    return nil
}

enum CLIPatchError: LocalizedError {
    case systemAppNotAllowed
    case sourceNotFound
    case copyFailed(String)
    case dylibNotFound(String)
    case invalidBundle(String)
    case codesignRemoveFailed(String)
    case codesignFailed(String)

    var errorDescription: String? {
        switch self {
        case .systemAppNotAllowed:
            return "不允许注入系统应用（/System/ 目录下的应用）"
        case .sourceNotFound:
            return "找不到源应用程序"
        case .copyFailed(let msg):
            return "复制应用失败: \(msg)"
        case .dylibNotFound(let msg):
            return "找不到 SpeedPatch.dylib: \(msg)"
        case .invalidBundle(let msg):
            return "无效的应用包: \(msg)"
        case .codesignRemoveFailed(let msg):
            return "移除原签名失败: \(msg)"
        case .codesignFailed(let msg):
            return "重新签名失败: \(msg)"
        }
    }
}

private func validateAndCopyPatchApp(source: URL, output: URL) throws {
    let fm = FileManager.default
    if source.path.hasPrefix("/System/") {
        throw CLIPatchError.systemAppNotAllowed
    }
    guard fm.fileExists(atPath: source.path) else {
        throw CLIPatchError.sourceNotFound
    }
    if fm.fileExists(atPath: output.path) {
        try fm.removeItem(at: output)
    }
    do {
        try fm.copyItem(at: source, to: output)
    } catch {
        throw CLIPatchError.copyFailed(error.localizedDescription)
    }
}

private func readPatchExecutable(bundle: URL) throws -> (Data, String) {
    let infoPlistURL = bundle.appendingPathComponent("Contents/Info.plist")
    guard let plistData = try? Data(contentsOf: infoPlistURL),
          let plistDict = try PropertyListSerialization.propertyList(
              from: plistData,
              options: [],
              format: nil
          ) as? [String: Any],
          let execName = plistDict["CFBundleExecutable"] as? String else {
        throw CLIPatchError.invalidBundle("无法读取 CFBundleExecutable")
    }
    let binPath = bundle.appendingPathComponent("Contents/MacOS/\(execName)")
    guard FileManager.default.fileExists(atPath: binPath.path) else {
        throw CLIPatchError.invalidBundle("主可执行文件不存在: \(execName)")
    }
    return (plistData, execName)
}

private func embedPatchDylib(in bundle: URL) throws {
    let fm = FileManager.default
    guard let dylibPath = getDylibPathForCLI(),
          fm.fileExists(atPath: dylibPath) else {
        throw CLIPatchError.dylibNotFound("请设置 OPENSWIFT_DYLIB_PATH 或将 CLI 与 OpenSwift.app 同目录部署")
    }
    let dylibURL = URL(fileURLWithPath: dylibPath)
    let frameworksURL = bundle.appendingPathComponent("Contents/Frameworks")
    if !fm.fileExists(atPath: frameworksURL.path) {
        try fm.createDirectory(at: frameworksURL, withIntermediateDirectories: true)
    }
    let destDylibURL = frameworksURL.appendingPathComponent("SpeedPatch")
    if fm.fileExists(atPath: destDylibURL.path) {
        try fm.removeItem(at: destDylibURL)
    }
    do {
        try fm.copyItem(at: dylibURL, to: destDylibURL)
    } catch {
        throw CLIPatchError.copyFailed("复制 dylib 到 Frameworks 失败: \(error.localizedDescription)")
    }
}

private func injectPatchEnvironment(plistData: Data, bundle: URL) throws {
    let infoPlistURL = bundle.appendingPathComponent("Contents/Info.plist")
    guard let plistDictMutable = try PropertyListSerialization.propertyList(
        from: plistData,
        options: .mutableContainersAndLeaves,
        format: nil
    ) as? NSMutableDictionary else {
        throw CLIPatchError.invalidBundle("Info.plist 格式异常")
    }
    let env: [String: String] = [
        "DYLD_INSERT_LIBRARIES": "@executable_path/../Frameworks/SpeedPatch",
        "DYLD_FORCE_FLAT_NAMESPACE": "1"
    ]
    plistDictMutable["LSEnvironment"] = env
    let outputData = try PropertyListSerialization.data(
        fromPropertyList: plistDictMutable,
        format: .xml,
        options: 0
    )
    try outputData.write(to: infoPlistURL)
}

private func resignPatchApp(at bundle: URL) throws {
    do {
        try runPatchCommand("/usr/bin/codesign", [
            "--remove-signature",
            "--all-architectures",
            "--deep",
            bundle.path
        ])
    } catch {
        throw CLIPatchError.codesignRemoveFailed(error.localizedDescription)
    }
    do {
        try runPatchCommand("/usr/bin/codesign", [
            "-f",
            "-s", "-",
            "--all-architectures",
            "--deep",
            "--preserve-metadata=identifier,entitlements,flags",
            bundle.path
        ])
    } catch {
        throw CLIPatchError.codesignFailed(error.localizedDescription)
    }
}

private func patchAppCLI(source: URL, output: URL) throws -> URL {
    try validateAndCopyPatchApp(source: source, output: output)
    let (plistData, _) = try readPatchExecutable(bundle: output)
    try embedPatchDylib(in: output)
    try injectPatchEnvironment(plistData: plistData, bundle: output)
    try resignPatchApp(at: output)
    return output
}
