import Foundation

/// 一个已导入本地的插件实例。
/// 包含其清单、安装时间、解压后所在的目录以及启用状态。
struct Plugin: Identifiable, Codable, Equatable {
    let manifest: PluginManifest
    var installedAt: Date
    var sourceDirectory: URL?
    var isEnabled: Bool

    /// 稳定标识复用自清单 id。
    var id: String { manifest.id }

    var name: String { manifest.name }
    var version: String { manifest.version }

    init(
        manifest: PluginManifest,
        installedAt: Date = Date(),
        sourceDirectory: URL? = nil,
        isEnabled: Bool = true
    ) {
        self.manifest = manifest
        self.installedAt = installedAt
        self.sourceDirectory = sourceDirectory
        self.isEnabled = isEnabled
    }
}
