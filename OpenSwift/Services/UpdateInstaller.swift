import Foundation

/// 更新包自动安装服务。
///
/// 校验下载 zip 的 sha256、解压到临时目录，并生成一个脱离本进程的 bash 助手脚本：
/// 等待当前应用完全退出后，用新包替换旧包（必要时走管理员权限）并重新启动，
/// 最后清理临时文件。
final class UpdateInstaller {
    static let shared = UpdateInstaller()

    /// 是否正在安装（防重入）。
    private(set) var isInstalling = false

    private let queue = DispatchQueue(label: "com.openswift.installer", qos: .userInitiated)

    private init() {}

    /// 校验并安装更新包；安装助手启动成功后回调 success，失败回调 failure。
    func install(
        zipURL: URL,
        manifest: AppUpdateManifest,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isInstalling else {
                completion(.failure(InstallError.message("安装已在执行中")))
                return
            }
            self.isInstalling = true
            self.performInstall(zipURL: zipURL, manifest: manifest, completion: completion)
        }
    }

    // MARK: - 安装流程

    private func performInstall(
        zipURL: URL,
        manifest: AppUpdateManifest,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // 1. sha256 校验
        guard let actual = sha256(of: zipURL) else {
            finish(.failure(InstallError.message("下载校验失败，请重试")), completion: completion)
            return
        }
        if let expected = manifest.sha256?.lowercased(), expected != actual {
            finish(.failure(InstallError.message("下载校验失败，请重试")), completion: completion)
            return
        }
        // 2. 解压到临时目录
        let stagingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenSwiftUpdate-\(UUID().uuidString)")
        do {
            try extract(zipURL: zipURL, to: stagingDir)
            let stagedApp = stagingDir.appendingPathComponent("OpenSwift.app")
            guard FileManager.default.fileExists(atPath: stagedApp.path) else {
                throw InstallError.message("更新包内未找到 OpenSwift.app")
            }
            // 3. 生成并启动脱离进程的安装助手
            let scriptURL = try writeHelperScript(stagedApp: stagedApp, stagingDir: stagingDir)
            try launchHelper(at: scriptURL)
            finish(.success(()), completion: completion)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            finish(.failure(error), completion: completion)
        }
    }

    /// 计算文件 sha256（小写十六进制）；失败返回 nil。
    private func sha256(of fileURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", fileURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
              let first = output.split(separator: " ").first else { return nil }
        return String(first).lowercased()
    }

    /// 解压 zip 到指定目录。
    private func extract(zipURL: URL, to stagingDir: URL) throws {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", stagingDir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.message("解压更新包失败")
        }
    }

    /// 生成「替换并重启」的 bash 助手脚本，返回脚本路径。
    ///
    /// AppleScript 字符串内取不到 bash 变量，osascript 的命令必须拼上真实路径。
    private func writeHelperScript(stagedApp: URL, stagingDir: URL) throws -> URL {
        let destPath = Bundle.main.bundleURL.path
        let pid = Foundation.ProcessInfo.processInfo.processIdentifier
        let esc = "\\\""
        let rmCmd = "rm -rf \(esc)\(destPath)\(esc)"
        let mvCmd = "mv \(esc)\(stagedApp.path)\(esc) \(esc)\(destPath)\(esc)"
        let osascript = "osascript -e 'do shell script \"\(rmCmd) && \(mvCmd)\" "
            + "with administrator privileges' >/dev/null 2>&1"
        let lines: [String] = [
            "#!/bin/bash",
            "OLD_PID=\(pid)",
            "DEST=\(destPath)",
            "STAGED=\(stagedApp.path)",
            "STAGING=\(stagingDir.path)",
            "# 1. wait for old process to fully exit",
            "while kill -0 \"$OLD_PID\" 2>/dev/null; do sleep 0.3; done",
            "sleep 1",
            "# 2. replace old bundle with new one (same path)",
            "replace() {",
            "  rm -rf \"\(destPath)\" && mv \"\(stagedApp.path)\" \"\(destPath)\"",
            "}",
            "if ! replace; then",
            "  # 3. permission fallback via admin authorization",
            "  \(osascript)",
            "fi",
            "# 4. relaunch new version",
            "open \"$DEST\"",
            "# 5. cleanup staging",
            "rm -rf \"$STAGING\"",
            "rm -f \"$0\"",
            ""
        ]
        let content = lines.joined(separator: "\n")
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openswift-install-\(UUID().uuidString).sh")
        do {
            try Data(content.utf8).write(to: scriptURL, options: .atomic)
        } catch {
            throw InstallError.message("写入安装脚本失败")
        }
        return scriptURL
    }

    /// 以脱离进程的方式启动安装助手（不等待，不阻塞）。
    private func launchHelper(at scriptURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        do {
            try process.run()
        } catch {
            throw InstallError.message("启动安装助手失败")
        }
    }

    /// 失败时复位安装状态并回调结果。
    private func finish(
        _ result: Result<Void, Error>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if case .failure = result {
            isInstalling = false
        }
        completion(result)
    }
}

/// 安装失败包装错误（消息直接展示给用户）。
private enum InstallError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}
