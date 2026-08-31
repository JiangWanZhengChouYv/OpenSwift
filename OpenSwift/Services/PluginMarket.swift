import Combine
import Foundation

/// 插件市场服务。
///
/// 从 GitHub Release（tag=plugin）拉取插件清单，并提供下载、解压、解析、
/// 安装到 PluginStore 的一站式流程。所有网络与磁盘操作在后台队列执行，
/// 仅通过主线程更新 @Published 状态。
final class PluginMarket: ObservableObject {
    static let shared = PluginMarket()

    /// GitHub Release 上以 tag "plugin" 发布插件清单的 API 地址。
    static let releaseAPIURL =
        "https://api.github.com/repos/JiangWanZhengChouYv/OpenSwift/releases/tags/plugin"

    /// 判断 `lhs` 版本是否比 `rhs` 更新。
    /// 按 `.` 拆分后逐段比较 major→minor→patch，缺省段视为 0，可忽略前导零；
    /// 任一段无法解析为整数时返回 false。
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".")
        let rhsParts = rhs.split(separator: ".")
        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let lhsValue = index < lhsParts.count ? Int(lhsParts[index]) : 0
            let rhsValue = index < rhsParts.count ? Int(rhsParts[index]) : 0
            guard let lhsValue, let rhsValue else {
                return false
            }
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }
        return false
    }

    @Published private(set) var items: [PluginMarketItem] = []
    @Published var isFetching = false
    @Published var errorMessage: String? = nil
    @Published var downloadingPluginIDs: Set<String> = []

    /// Release assets 的 name -> browser_download_url 映射，供下载时定位 zip。
    private var assetURLs: [String: String] = [:]

    private let workQueue = DispatchQueue(label: "com.openswift.pluginmarket", qos: .userInitiated)

    private init() {}

    /// 拉取在线插件清单。
    func fetchCatalog() {
        guard !isFetching else { return }
        isFetching = true
        workQueue.async { [weak self] in
            self?.performFetchCatalog()
        }
    }

    /// 下载并安装指定插件。
    func downloadPlugin(_ item: PluginMarketItem) {
        guard !downloadingPluginIDs.contains(item.id) else { return }
        downloadingPluginIDs.insert(item.id)
        workQueue.async { [weak self] in
            self?.performDownload(item)
        }
    }

    // MARK: - 清单拉取

    private func performFetchCatalog() {
        guard let url = URL(string: Self.releaseAPIURL) else {
            finishFetchFailure("插件市场地址无效")
            return
        }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            self.workQueue.async {
                if let error {
                    self.finishFetchFailure("获取插件清单失败: \(error.localizedDescription)")
                    return
                }
                guard let data, let http = response as? HTTPURLResponse else {
                    self.finishFetchFailure("获取插件清单失败: 无有效响应")
                    return
                }
                if http.statusCode == 404 {
                    self.finishFetchFailure("插件市场尚未发布，请稍后再试")
                    return
                }
                guard http.statusCode == 200 else {
                    self.finishFetchFailure("获取插件清单失败: HTTP \(http.statusCode)")
                    return
                }
                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    self.assetURLs = Dictionary(
                        uniqueKeysWithValues: release.assets.map { ($0.name, $0.browserDownloadURL) }
                    )
                    guard let indexAsset = release.assets.first(where: { $0.name == "plugin_index.json" }) else {
                        self.finishFetchFailure("远端未提供插件清单")
                        return
                    }
                    self.downloadIndex(at: indexAsset.browserDownloadURL)
                } catch {
                    self.finishFetchFailure("解析插件市场信息失败: \(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }

    private func downloadIndex(at urlString: String) {
        guard let url = URL(string: urlString) else {
            finishFetchFailure("插件清单地址无效")
            return
        }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            self.workQueue.async {
                if let error {
                    self.finishFetchFailure("下载插件清单失败: \(error.localizedDescription)")
                    return
                }
                guard let data else {
                    self.finishFetchFailure("下载插件清单失败: 无有效数据")
                    return
                }
                do {
                    let items = try JSONDecoder().decode([PluginMarketItem].self, from: data)
                    DispatchQueue.main.async {
                        self.items = items
                        self.isFetching = false
                        self.errorMessage = nil
                    }
                } catch {
                    self.finishFetchFailure("解析插件清单失败: \(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }

    private func finishFetchFailure(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.isFetching = false
        }
    }

    // MARK: - 插件下载安装

    private func performDownload(_ item: PluginMarketItem) {
        guard let urlString = assetURLs[item.asset], let url = URL(string: urlString) else {
            finishDownloadFailure(item, message: "无法定位插件下载地址")
            return
        }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            self.workQueue.async {
                if let error {
                    self.finishDownloadFailure(item, message: "下载插件失败: \(error.localizedDescription)")
                    return
                }
                guard let data else {
                    self.finishDownloadFailure(item, message: "下载插件失败: 无有效数据")
                    return
                }
                self.installDownloaded(data, item: item)
            }
        }
        task.resume()
    }

    private func installDownloaded(_ data: Data, item: PluginMarketItem) {
        let fileManager = FileManager.default
        let zipURL = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        do {
            try data.write(to: zipURL)
            let directory = try PluginUnzipper.shared.unzip(at: zipURL)
            let manifest = try PluginParser.parseManifest(at: directory.appendingPathComponent("manifest.yml"))
            let plugin = Plugin(manifest: manifest, sourceDirectory: directory)
            DispatchQueue.main.async {
                PluginStore.shared.add(self.installedPlugin(plugin, preservingConfigFor: item.id))
                self.finishDownloadSuccess(item)
            }
        } catch {
            finishDownloadFailure(item, message: "安装插件失败: \(error.localizedDescription)")
        }
    }

    /// 覆盖安装已有插件时，将旧插件的运行时配置迁移到新插件，避免更新后配置丢失。
    private func installedPlugin(_ plugin: Plugin, preservingConfigFor id: String) -> Plugin {
        guard let existing = PluginStore.shared.plugin(withID: id) else {
            return plugin
        }
        let mergedConfig = existing.config.merging(plugin.config) { _, new in new }
        return Plugin(
            manifest: plugin.manifest,
            sourceDirectory: plugin.sourceDirectory,
            isEnabled: existing.isEnabled,
            config: mergedConfig
        )
    }

    private func finishDownloadSuccess(_ item: PluginMarketItem) {
        DispatchQueue.main.async {
            self.downloadingPluginIDs.remove(item.id)
            self.errorMessage = nil
        }
    }

    private func finishDownloadFailure(_ item: PluginMarketItem, message: String) {
        DispatchQueue.main.async {
            self.downloadingPluginIDs.remove(item.id)
            self.errorMessage = message
        }
    }
}

/// GitHub Release 返回结构中对资源的简化描述。
private struct GitHubRelease: Decodable {
    let assets: [GitHubReleaseAsset]
}

/// GitHub Release 中单个资源（name 与其下载地址）。
private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
