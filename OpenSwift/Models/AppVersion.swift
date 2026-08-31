import Foundation

/// 从 Bundle 读取应用版本信息。
///
/// 优先直接解析 Info.plist 文件，失败时回退到 `Bundle.main` 的 infoDictionary，
/// 仍拿不到才返回 nil（由调用方给缺省值），避免误把确有的版本显示成缺省值 1.0。
enum AppVersion {
    /// "版本号 (build)" 的展示串，例如 `2.1.0 (1)`。
    static let presentable: String = {
        let version = bundleKey("CFBundleShortVersionString") ?? "未知"
        let build = bundleKey("CFBundleVersion") ?? "1"
        return "\(version) (\(build))"
    }()

    /// 纯版本号，例如 `2.1.0`。
    static var short: String {
        bundleKey("CFBundleShortVersionString") ?? "未知"
    }

    private static func bundleKey(_ key: String) -> String? {
        if let url = Bundle.main.url(forResource: "Info", withExtension: "plist"),
           let value = NSDictionary(contentsOf: url)?[key] as? String,
           !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           !value.isEmpty {
            return value
        }
        return nil
    }
}
