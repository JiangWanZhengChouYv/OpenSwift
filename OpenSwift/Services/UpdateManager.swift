import AppKit
import Combine
import Foundation

/// 应用「检查更新」服务。
///
/// 从 GitHub Release（tag=app）拉取 `app_update.json` 更新清单，与本地版本比较；
/// 有更新时引导用户下载 zip 到 ~/Downloads 并 reveal。网络/磁盘在后台队列执行，
/// UI（NSAlert）在主线程呈现。
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    /// GitHub Release 上以 tag "app" 发布更新清单的 API 地址。
    static let releaseAPIURL =
        "https://api.github.com/repos/JiangWanZhengChouYv/OpenSwift/releases/tags/app"

    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false

    private let workQueue = DispatchQueue(label: "com.openswift.update", qos: .userInitiated)

    private init() {}

    /// 主动检查更新，结果以 NSAlert 在主线程呈现。
    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        performFetch { [weak self] result in
            guard let self else { return }
            self.isChecking = false
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.showAlert(title: "检查更新失败", message: error.localizedDescription, style: .warning)
                case .success(let manifest):
                    let current = AppVersion.short
                    if PluginMarket.isVersion(manifest.version, newerThan: current) {
                        self.showUpdateAvailable(manifest)
                    } else {
                        self.showAlert(
                            title: "已是最新版本",
                            message: "当前已是最新版本 v\(current)",
                            style: .informational
                        )
                    }
                }
            }
        }
    }

    /// 下载更新包（仅由「有更新」弹窗调用）。
    func downloadUpdate(_ manifest: AppUpdateManifest) {
        guard !isDownloading, let url = URL(string: manifest.downloadURL) else { return }
        isDownloading = true
        let urlPath = URL(string: manifest.downloadURL)?.lastPathComponent ?? ""
        let fileName = urlPath.isEmpty ? "OpenSwift-v\(manifest.version).zip" : urlPath
        let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(fileName) ?? URL(fileURLWithPath: "/tmp/\(fileName)")
        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isDownloading = false
            }
            if let error {
                self.showAlert(title: "下载失败", message: error.localizedDescription, style: .warning)
                return
            }
            guard let tempURL else {
                self.showAlert(title: "下载失败", message: "未获取到文件", style: .warning)
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                self.finishDownload(destination, version: manifest.version)
            } catch {
                self.showAlert(title: "下载失败", message: error.localizedDescription, style: .warning)
            }
        }.resume()
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

    // MARK: - UI

    private func showUpdateAvailable(_ manifest: AppUpdateManifest) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(manifest.version)"
        alert.informativeText = manifest.notes?
            .replacingOccurrences(of: "\\n", with: "\n") ?? "可用新版本，是否下载？"
        alert.addButton(withTitle: "下载更新")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            downloadUpdate(manifest)
        }
    }

    private func finishDownload(_ url: URL, version: String) {
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            let alert = NSAlert()
            alert.messageText = "下载完成"
            alert.informativeText = "新版本 v\(version) 已下载到：\n\(url.path)\n\n请退出当前应用后，替换安装新版本。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = style
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}

/// 更新检查失败包装（把可读消息转换为 Error）。
private struct UpdateCheckError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
