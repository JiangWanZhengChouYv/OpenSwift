import Foundation

/// 插件 UI 控件的默认配置值。
/// 支持字符串 / 布尔 / 整数 / 浮点数四类，便于在多行 UI 控件中统一呈现。
enum PluginConfigValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case number(Double)

    /// 从类型擦除的解析值构建默认值。无法识别的类型返回 nil。
    static func from(_ value: Any) -> PluginConfigValue? {
        switch value {
        case let text as String:
            return .string(text)
        case let flag as Bool:
            return .bool(flag)
        case let integer as Int:
            return .integer(integer)
        case let number as Double:
            return .number(number)
        case let number as NSNumber:
            let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            if isBoolean {
                return .bool(number.boolValue)
            }
            if number.doubleValue.rounded() == number.doubleValue {
                return .integer(number.intValue)
            }
            return .number(number.doubleValue)
        default:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case string
        case bool
        case integer
        case number
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try container.decodeIfPresent(String.self, forKey: .string) {
            self = .string(text)
        } else if let flag = try container.decodeIfPresent(Bool.self, forKey: .bool) {
            self = .bool(flag)
        } else if let integer = try container.decodeIfPresent(Int.self, forKey: .integer) {
            self = .integer(integer)
        } else if let number = try container.decodeIfPresent(Double.self, forKey: .number) {
            self = .number(number)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "无法识别的插件配置值")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let text):
            try container.encode(text, forKey: .string)
        case .bool(let flag):
            try container.encode(flag, forKey: .bool)
        case .integer(let value):
            try container.encode(value, forKey: .integer)
        case .number(let value):
            try container.encode(value, forKey: .number)
        }
    }

    /// UI 呈现时可用的字符串描述。
    var displayValue: String {
        switch self {
        case .string(let text):
            return text
        case .bool(let flag):
            return flag ? "true" : "false"
        case .integer(let value):
            return String(value)
        case .number(let value):
            return String(format: "%.3f", value)
        }
    }
}

/// 插件清单中单个 UI 控件定义。
struct PluginUIElement: Codable, Equatable, Identifiable {
    /// 稳定标识复用自配置键。
    var id: String { key }

    let type: String
    let key: String
    let label: String?
    let defaultValue: PluginConfigValue?

    private enum CodingKeys: String, CodingKey {
        case type
        case key
        case label
        case defaultValue = "default"
    }
}

/// 插件清单中单个目标应用的定义。
struct PluginTarget: Codable, Equatable {
    let bundleId: String?
    let process: String?
    let uiSkip: Bool?
    let speedHook: Bool?
    let children: [PluginTarget]?

    private enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id"
        case process
        case uiSkip = "ui_skip"
        case speedHook = "speed_hook"
        case children
    }
}

/// 插件清单（manifest.yml）的强类型模型。
struct PluginManifest: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let version: String
    let minAppVersion: String?
    let descriptionText: String?
    let ui: [PluginUIElement]
    let targets: [PluginTarget]
    let script: String?
    let hooklib: String?
    /// L3 原生 hooklib 的入口符号名；缺省用 `SpeedPatchRegisterHook`。
    let hooklibEntry: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case minAppVersion = "min_app_version"
        case descriptionText = "description"
        case ui
        case targets
        case script
        case hooklib
        case hooklibEntry = "hooklib_entry"
    }
}
