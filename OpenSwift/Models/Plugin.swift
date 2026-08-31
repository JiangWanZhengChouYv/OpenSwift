import Foundation

/// 一个已导入本地的插件实例。
/// 包含其清单、安装时间、解压后所在的目录以及启用状态。
struct Plugin: Identifiable, Codable, Equatable {
    let manifest: PluginManifest
    var installedAt: Date
    var sourceDirectory: URL?
    var isEnabled: Bool
    /// 插件运行时配置（如 L2 开关联动值），随插件 JSON 一起持久化。
    var config: [String: PluginConfigValue]

    /// 稳定标识复用自清单 id。
    var id: String { manifest.id }

    var name: String { manifest.name }
    var version: String { manifest.version }

    init(
        manifest: PluginManifest,
        installedAt: Date = Date(),
        sourceDirectory: URL? = nil,
        isEnabled: Bool = true,
        config: [String: PluginConfigValue] = [:]
    ) {
        self.manifest = manifest
        self.installedAt = installedAt
        self.sourceDirectory = sourceDirectory
        self.isEnabled = isEnabled
        self.config = config
    }

    private enum CodingKeys: String, CodingKey {
        case manifest
        case installedAt
        case sourceDirectory
        case isEnabled
        case config
    }

    /// 手动解码以兼容旧版 JSON：缺失 config 字段时默认空字典，避免反序列化崩溃。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try container.decode(PluginManifest.self, forKey: .manifest)
        installedAt = try container.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
        sourceDirectory = try container.decodeIfPresent(URL.self, forKey: .sourceDirectory)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        config = try container.decodeIfPresent([String: PluginConfigValue].self, forKey: .config) ?? [:]
    }
}
