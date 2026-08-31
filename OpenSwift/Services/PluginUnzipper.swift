import Foundation

/// 插件解压相关的错误。
enum PluginUnzipError: LocalizedError {
    case fileNotFound(String)
    case invalidArchive(String)
    case createTempDirectoryFailed(String)
    case unzipFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "找不到待解压的插件包: \(path)"
        case .invalidArchive(let reason):
            return "插件包不是有效的 zip 归档: \(reason)"
        case .createTempDirectoryFailed(let reason):
            return "创建临时目录失败: \(reason)"
        case .unzipFailed(let reason):
            return "解压插件失败: \(reason)"
        }
    }
}

/// 插件包解压器。
///
/// 使用系统内置的 `ditto` 将 zip 解压到临时目录，并定位其中的 manifest.yml，
/// 返回包含清单的目录路径；解压失败或缺少清单时抛出错误。
class PluginUnzipper {
    static let shared = PluginUnzipper()
    private init() {}

    /// 解压指定 zip 到临时目录，返回包含 manifest.yml 的目录路径。
    func unzip(at zipURL: URL) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: zipURL.path) else {
            throw PluginUnzipError.fileNotFound(zipURL.path)
        }

        // 解压到一个稳定的目录，确保源码文件跨应用重启保留。
        // 固定路径：~/Library/Application Support/com.openswift.app/Plugins/<UUID>
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PluginUnzipError.createTempDirectoryFailed("无法获取 Application Support 目录")
        }
        let pluginsDirectory = appSupport
            .appendingPathComponent("com.openswift.app", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        } catch {
            throw PluginUnzipError.createTempDirectoryFailed(error.localizedDescription)
        }

        let destinationDirectory = pluginsDirectory.appendingPathComponent("archive", isDirectory: true)
        try runDitto(source: zipURL, destination: destinationDirectory)

        guard let manifestDirectory = locateManifestDirectory(in: pluginsDirectory) else {
            try? fileManager.removeItem(at: pluginsDirectory)
            throw PluginUnzipError.invalidArchive("归档中缺少 manifest.yml")
        }
        return manifestDirectory
    }

    // MARK: - ditto 调用

    private func runDitto(source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", source.path, destination.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw PluginUnzipError.unzipFailed("无法启动 ditto: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let reason = String(data: errorData, encoding: .utf8) ?? "退出码 \(process.terminationStatus)"
            throw PluginUnzipError.unzipFailed(reason)
        }
    }

    /// 在解压目录内递归定位 manifest.yml，返回其所在目录。
    /// 支持 zip 顶层直接包含 manifest.yml，或包含一层子目录的情况。
    private func locateManifestDirectory(in rootDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "manifest.yml" {
                return fileURL.deletingLastPathComponent()
            }
        }
        return nil
    }
}
