import Foundation

/// 插件市场中单个可下载条目。
struct PluginMarketItem: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let version: String
    let description: String
    let asset: String
}
