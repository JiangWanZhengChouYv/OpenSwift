import AppKit
import Combine
import Foundation

/// 更新流程的阶段状态。
enum UpdatePhase: Equatable {
    case idle
    case checking
    case updateAvailable
    case latest
    case downloading
    case retrying
    case installing
    case finished
    case failed
}

/// 应用「检查更新」服务（图形化版）。
///
/// 从 GitHub Release（tag=app）拉取 `app_update.json`，比较版本后用图形化更新窗口
/// 引导用户下载；下载交给 `UpdateDownloader`（断点续传 + 失败 3s 自动重连）。
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    /// GitHub Release 上以 tag "app" 发布更新清单的 API 地址。
    static let releaseAPIURL =
        "https://api.github.com/repos/JiangWanZhengChouYv/OpenSwift/releases/tags/app"

    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var manifest: AppUpdateManifest?
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var downloadedURL: URL?

    private let workQueue = DispatchQueue(label: "com.openswift.update", qos: .userInitiated)
    private let windowController = UpdateWindowController()
    private let installer = UpdateInstaller.shared
    private var downloader: UpdateDownloader?

    private init() {}

    /// 检查更新：打开图形化窗口并开始检查。
    func checkForUpdates() {
        switch phase {
        case .downloading, .retrying:
            return
        default:
            break
        }
        windowController.show()
        phase = .checking
        statusMessage = nil
        manifest = nil
        progress = 0
        performFetch { [weak self] result in
            guard let self else { return }
            let current = AppVersion.short
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.phase = .failed
                    self.statusMessage = error.localizedDescription
                case .success(let newManifest):
                    self.manifest = newManifest
                    if PluginMarket.isVersion(newManifest.version, newerThan: current) {
                        self.phase = .updateAvailable
                    } else {
                        self.phase = .latest
                    }
                }
            }
        }
    }

    /// 开始下载当前清单指向的更新包（交给断点续传下载器）。
    func startDownload() {
        guard let manifest,
              let url = URL(string: manifest.downloadURL) else { return }
        let fileName = url.lastPathComponent.isEmpty
            ? "OpenSwift-v\(manifest.version).zip"
            : url.lastPathComponent
        let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(fileName) ?? URL(fileURLWithPath: "/tmp/\(fileName)")

        let downloader = UpdateDownloader()
        downloader.onProgress = { [weak self] fraction in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress = fraction
                self.phase = .downloading
                self.statusMessage = nil
            }
        }
        downloader.onRetrying = { [weak self] in
            DispatchQueue.main.async {
                self?.phase = .retrying
                self?.statusMessage = "连接中断，将在 3 秒后自动重试…"
            }
        }
        downloader.onSuccess = { [weak self] url in
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloadedURL = url
                self.progress = 1
                self.phase = .installing
                self.statusMessage = nil
                self.installDownloaded()
            }
        }
        downloader.onFailed = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.phase == .idle { return }
                self.phase = .failed
                self.statusMessage = message
            }
        }
        downloader.start(url: url, destination: destination, version: manifest.version)
        self.downloader = downloader
        progress = 0
        phase = .downloading
        statusMessage = nil
    }

    /// 自动安装已下载的更新包并重启应用。
    func installDownloaded() {
        guard let downloadedURL, let manifest else { return }
        installer.install(zipURL: downloadedURL, manifest: manifest) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.phase = .failed
                    self.statusMessage = "安装失败：\(error.localizedDescription)"
                case .success:
                    // 安装助手已分离运行：清理并退出，由助手完成替换与重启。
                    AppState.shared.shutdown()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    /// 在 Finder 中显示已下载的更新包。
    func revealDownloaded() {
        guard let downloadedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([downloadedURL])
    }

    /// 用户取消：停止下载并关闭窗口。
    func cancel() {
        downloader?.cancel()
        downloader = nil
        phase = .idle
        windowController.close()
    }

    /// 用户直接点了窗口关闭按钮：若仍在下载/重连则取消任务。
    func handleWindowClosed() {
        if phase == .downloading || phase == .retrying {
            downloader?.cancel()
            downloader = nil
            phase = .idle
        }
    }

    // MARK: - 清单拉取与比较

    private func performFetch(completion: @escaping (Result<AppUpdateManifest, Error>) -> Void) {
        guard let url = URL(string: Self.releaseAPIURL) else {
            completion(.failure(UpdateCheckError(message: "更新地址无效")))
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                let detail = "网络错误: \(error.localizedDescription)"
                self.workQueue.async { completion(.failure(UpdateCheckError(message: detail))) }
                return
            }
            guard let data, let http = response as? HTTPURLResponse else {
                self.workQueue.async { completion(.failure(UpdateCheckError(message: "无法获取更新清单"))) }
                return
            }
            if http.statusCode == 404 {
                self.workQueue.async { completion(.failure(UpdateCheckError(message: "更新清单尚未发布，请稍后再试"))) }
                return
            }
            guard http.statusCode == 200 else {
                let detail = "获取更新清单失败: HTTP \(http.statusCode)"
                self.workQueue.async { completion(.failure(UpdateCheckError(message: detail))) }
                return
            }
            do {
                let release = try JSONDecoder().decode(GitHubUpdateRelease.self, from: data)
                guard let asset = release.assets.first(where: { $0.name == "app_update.json" }) else {
                    self.workQueue.async { completion(.failure(UpdateCheckError(message: "远端未提供更新清单"))) }
                    return
                }
                self.fetchManifest(from: asset.browserDownloadURL, completion: completion)
            } catch {
                self.workQueue.async { completion(.failure(UpdateCheckError(message: "更新清单解析失败"))) }
            }
        }.resume()
    }

    private func fetchManifest(
        from urlString: String,
        completion: @escaping (Result<AppUpdateManifest, Error>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(.failure(UpdateCheckError(message: "更新清单地址无效")))
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error {
                let detail = "网络错误: \(error.localizedDescription)"
                self.workQueue.async { completion(.failure(UpdateCheckError(message: detail))) }
                return
            }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                self.workQueue.async { completion(.failure(UpdateCheckError(message: "无法读取更新清单"))) }
                return
            }
            do {
                let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
                self.workQueue.async { completion(.success(manifest)) }
            } catch {
                self.workQueue.async { completion(.failure(UpdateCheckError(message: "更新清单内容无效"))) }
            }
        }.resume()
    }
}

/// `app_update.json` 更新清单结构。
struct AppUpdateManifest: Decodable {
    let version: String
    let build: String?
    let notes: String?
    let downloadURL: String
    let sha256: String?

    private enum CodingKeys: String, CodingKey {
        case version
        case build
        case notes
        case downloadURL = "download_url"
        case sha256
    }
}

/// 更新检查失败包装（把可读消息转换为 Error）。
private struct UpdateCheckError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// GitHub Release 返回结构中对资源的简化描述。
private struct GitHubUpdateRelease: Decodable {
    let assets: [GitHubUpdateAsset]
}

private struct GitHubUpdateAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
