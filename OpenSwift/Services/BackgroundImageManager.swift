import Foundation

/// 界面背景图片缓存/下载服务。
/// 负责将本地图片复制到应用缓存目录，或将在线图片下载到本地，
/// 保证源文件被移动/删除后仍可正常显示。
class BackgroundImageManager {

    static let shared = BackgroundImageManager()

    private let errorDomain = "BackgroundImageManager"

    private init() {
        let folderURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.backgroundDirectoryURL = Self.makeBackgroundDirectory(from: folderURL)
    }

    private let fileManager = FileManager.default
    private let backgroundDirectoryURL: URL

    private static func makeBackgroundDirectory(from baseURL: URL?) -> URL {
        guard let baseURL = baseURL else {
            logError("无法定位 Application Support 目录", log: .openswift)
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        let folderURL = baseURL.appendingPathComponent("OpenSwift/Backgrounds", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            logError("创建背景目录失败: \(error)", log: .openswift)
        }
        return folderURL
    }

    /// 将本地图片完整复制到缓存目录，返回缓存后的绝对路径字符串。
    /// 源文件被删除后缓存仍可正常显示。
    func cacheLocalImage(from url: URL) -> String? {
        let destinationURL = newDestinationURL(for: url.lastPathComponent)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: url, to: destinationURL)
            logInfo("本地图片已缓存: \(url.path) -> \(destinationURL.path)", log: .openswift)
            return destinationURL.path
        } catch {
            logError("缓存本地图片失败 \(url.path): \(error)", log: .openswift)
            return nil
        }
    }

    /// 校验并返回规范化后的在线图片 URL。
    private func validatedRemoteURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString), url.scheme != nil else {
            logError("无效的图片链接: \(urlString)", log: .openswift)
            return nil
        }
        return url
    }

    /// 下载在线图片到缓存目录，返回本地绝对路径字符串。
    func downloadRemoteImage(from urlString: String) async throws -> String {
        guard let url = validatedRemoteURL(from: urlString) else {
            throw makeError("无效的图片链接: \(urlString)")
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard !data.isEmpty else {
            throw makeError("下载图片数据为空: \(urlString)")
        }

        let filename = self.remoteFilename(for: url)
        let destinationURL = newDestinationURL(for: filename)
        do {
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            throw makeError("写入图片缓冲失败: \(error.localizedDescription)")
        }

        logInfo("在线图片已下载: \(urlString) -> \(destinationURL.path)", log: .openswift)
        return destinationURL.path
    }

    /// 依据远程 URL 生成缓存文件名：优先 lastPathComponent，否则 UUID + 推断扩展名。
    private func remoteFilename(for url: URL) -> String {
        let lastComponent = url.lastPathComponent
        if !lastComponent.isEmpty, lastComponent.contains(".") {
            return lastComponent
        }
        let ext = (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
        return UUID().uuidString + "." + ext
    }

    /// 生成缓存目录下的目标 URL，使用 UUID + 原始扩展名避免重复与冲突。
    private func newDestinationURL(for filename: String) -> URL {
        let ext = (filename as NSString).pathExtension
        let base = (ext.isEmpty ? filename : (filename as NSString).deletingPathExtension)
        let name = "\(base)-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
        return backgroundDirectoryURL.appendingPathComponent(name)
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(domain: errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
