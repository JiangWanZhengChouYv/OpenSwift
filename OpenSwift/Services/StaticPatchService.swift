import Foundation
import AppKit

enum StaticPatchError: LocalizedError {
    case systemAppNotAllowed
    case sourceNotFound
    case copyFailed(String)
    case dylibNotFound(String)
    case codesignRemoveFailed(String)
    case codesignFailed(String)
    case insertLoadFailed(String)
    case outputExistsNotOverwrite
    case invalidBundle(String)

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
        case .codesignRemoveFailed(let msg):
            return "移除原签名失败: \(msg)"
        case .codesignFailed(let msg):
            return "重新签名失败: \(msg)"
        case .insertLoadFailed(let msg):
            return "插入加载命令失败: \(msg)"
        case .outputExistsNotOverwrite:
            return "输出文件已存在且未允许覆盖"
        case .invalidBundle(let msg):
            return "无效的应用包: \(msg)"
        }
    }
}

class StaticPatchService {
    static let shared = StaticPatchService()
    private init() {}

    func patchApp(at sourceURL: URL, outputURL: URL, overwrite: Bool = false) throws -> URL {
        try validateSourceAndOutput(source: sourceURL, output: outputURL, overwrite: overwrite)
        try copyApp(from: sourceURL, to: outputURL)

        let infoPlistURL = outputURL.appendingPathComponent("Contents/Info.plist")
        let execName = try readExecutableName(from: infoPlistURL)
        try verifyExecutableExists(in: outputURL, execName: execName)

        try embedDylib(in: outputURL)
        try injectEnvironmentToPlist(at: infoPlistURL)
        try resignApp(at: outputURL)

        return outputURL
    }

    private func validateSourceAndOutput(source: URL, output: URL, overwrite: Bool) throws {
        if source.path.hasPrefix("/System/") {
            throw StaticPatchError.systemAppNotAllowed
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw StaticPatchError.sourceNotFound
        }
        if fm.fileExists(atPath: output.path) {
            guard overwrite else {
                throw StaticPatchError.outputExistsNotOverwrite
            }
            try fm.removeItem(at: output)
        }
    }

    private func copyApp(from source: URL, to output: URL) throws {
        do {
            try FileManager.default.copyItem(at: source, to: output)
        } catch {
            throw StaticPatchError.copyFailed(error.localizedDescription)
        }
    }

    private func readExecutableName(from plistURL: URL) throws -> String {
        guard let plistData = try? Data(contentsOf: plistURL),
              let plistDict = try PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let execName = plistDict["CFBundleExecutable"] as? String else {
            throw StaticPatchError.invalidBundle("无法读取 CFBundleExecutable")
        }
        return execName
    }

    private func verifyExecutableExists(in bundle: URL, execName: String) throws {
        let binPath = bundle.appendingPathComponent("Contents/MacOS/\(execName)")
        guard FileManager.default.fileExists(atPath: binPath.path) else {
            throw StaticPatchError.invalidBundle("主可执行文件不存在: \(execName)")
        }
    }

    private func embedDylib(in bundle: URL) throws {
        let dylibPath = try resolveDylibPath()
        let dylibURL = URL(fileURLWithPath: dylibPath)
        let fm = FileManager.default

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
            throw StaticPatchError.copyFailed("复制 dylib 到 Frameworks 失败: \(error.localizedDescription)")
        }
    }

    private func resignApp(at bundle: URL) throws {
        try runCommand("/usr/bin/codesign", [
            "--remove-signature",
            "--all-architectures",
            "--deep",
            bundle.path
        ])
        do {
            try runCommand("/usr/bin/codesign", [
                "-f",
                "-s", "-",
                "--all-architectures",
                "--deep",
                "--preserve-metadata=identifier,entitlements,flags",
                bundle.path
            ])
        } catch {
            throw StaticPatchError.codesignFailed(error.localizedDescription)
        }
    }

    func patchApp(at sourceURL: URL, adjacentPatchNamed name: String? = nil) throws -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let patchedName = name ?? "\(baseName)_Patched.app"
        let outputURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(patchedName)
        return try patchApp(at: sourceURL, outputURL: outputURL, overwrite: false)
    }

    private func resolveDylibPath() throws -> String {
        if let result = try? AppLauncher.shared.getDylibPath(),
           case .success(let path) = result,
           FileManager.default.fileExists(atPath: path) {
            return path
        }

        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let bundlePaths = [
            "Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch",
            "Contents/PlugIns/SpeedPatch.dylib/Contents/MacOS/SpeedPatch",
            "SpeedPatch.dylib"
        ]

        var candidates: [String] = []
        candidates.append(contentsOf: bundlePaths.map {
            bundleURL.appendingPathComponent($0).path
        })
        if let d = execDir {
            candidates.append(d.appendingPathComponent(
                "Contents/PlugIns/SpeedPatch/SpeedPatch.dylib/Contents/MacOS/SpeedPatch"
            ).path)
            candidates.append(d.appendingPathComponent("SpeedPatch.dylib").path)
        }
        candidates.append(fm.currentDirectoryPath
            .appending("/SpeedPatch.dylib"))

        for path in candidates {
            if fm.fileExists(atPath: path) {
                return path
            }
        }

        throw StaticPatchError.dylibNotFound(
            "已搜索: \(candidates.joined(separator: ", "))"
        )
    }

    private func injectEnvironmentToPlist(at plistURL: URL) throws {
        let plistData = try Data(contentsOf: plistURL)
        guard let plistDict = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? NSMutableDictionary else {
            throw StaticPatchError.invalidBundle("Info.plist 格式异常")
        }

        let env: [String: String] = [
            "DYLD_INSERT_LIBRARIES": "@executable_path/../Frameworks/SpeedPatch",
            "DYLD_FORCE_FLAT_NAMESPACE": "1"
        ]
        plistDict["LSEnvironment"] = env

        let outputData = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )
        try outputData.write(to: plistURL)
    }

    @discardableResult
    private func runCommand(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw StaticPatchError.insertLoadFailed(
                "启动进程失败: \(error.localizedDescription)"
            )
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let combined = [stderrStr, stdoutStr]
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            let message = combined.isEmpty
                ? "退出码 \(process.terminationStatus)"
                : combined
            if path.contains("codesign") && args.contains("--remove-signature") {
                throw StaticPatchError.codesignRemoveFailed(message)
            }
            throw StaticPatchError.insertLoadFailed(message)
        }

        return stdoutStr
    }
}
