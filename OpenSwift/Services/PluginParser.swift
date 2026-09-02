import Foundation

/// 插件清单解析相关的错误。
enum PluginParseError: LocalizedError {
    case emptyManifest
    case invalidYAML(String)
    case invalidJSON(String)
    case invalidPlist(String)
    case missingField(String)
    case invalidStructure(String)
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyManifest:
            return "插件清单为空"
        case .invalidYAML(let reason):
            return "YAML 解析失败: \(reason)"
        case .invalidJSON(let reason):
            return "JSON 解析失败: \(reason)"
        case .invalidPlist(let reason):
            return "Plist 解析失败: \(reason)"
        case .missingField(let field):
            return "插件清单缺少必需字段: \(field)"
        case .invalidStructure(let reason):
            return "插件清单结构异常: \(reason)"
        case .unreadableFile(let path):
            return "无法读取插件清单文件: \(path)"
        }
    }
}

/// 插件清单解析器。
///
/// 主路径使用内置的极简 YAML 子集解析器（无需任何第三方依赖），
/// 当 YAML 解析失败时依次回退到 JSON 和 plist 解析，尽量保证可用性。
struct PluginParser {

    /// 分析 YAML 字符串并构建插件清单模型。
    static func parse(_ content: String) throws -> PluginManifest {
        let dictionary = try parseIntoDictionary(content)
        return try toManifest(dictionary)
    }

    /// 读取指定路径的清单文件并解析。
    static func parseManifest(at url: URL) throws -> PluginManifest {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            return try parse(content)
        } catch let error as PluginParseError {
            throw error
        } catch {
            throw PluginParseError.unreadableFile(url.path)
        }
    }

    // MARK: - 结构化解析（YAML → JSON → plist 依次回退）

    private static func parseIntoDictionary(_ content: String) throws -> [String: Any] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginParseError.emptyManifest
        }

        // 主路径：自写极简 YAML 子集
        if let yaml = try? SimpleYAMLParser.parse(trimmed) {
            return yaml
        }

        // 回退一：JSON
        if let json = try? decodeAny(from: trimmed) as? [String: Any] {
            return json
        }

        // 回退二：plist（XML/二进制）
        if let data = trimmed.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) as? [String: Any] {
            return plist
        }

        // 全部失败，尝试以 JSON 内容给出更具体的提示
        if (try? decodeAny(from: trimmed)) == nil {
            throw PluginParseError.invalidJSON("内容不符合 JSON 语法")
        }
        throw PluginParseError.invalidYAML("无法识别的内容，且 JSON/plist 解析也未成功")
    }

    private static func decodeAny(from text: String) throws -> Any? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: - 字典 → 强类型模型

    private static func toManifest(_ dict: [String: Any]) throws -> PluginManifest {
        let id = try requiredString(dict, key: "id")
        let name = try requiredString(dict, key: "name")
        let version = try requiredString(dict, key: "version")

        let minAppVersion = dict["min_app_version"] as? String
        let descriptionText = dict["description"] as? String
        let script = dict["script"] as? String
        let hooklib = dict["hooklib"] as? String
        let hooklibEntry = dict["hooklib_entry"] as? String

        let ui = try buildUI(from: dict["ui"])
        let targets = try buildTargets(from: dict["targets"])

        return PluginManifest(
            id: id,
            name: name,
            version: version,
            minAppVersion: minAppVersion,
            descriptionText: descriptionText,
            ui: ui,
            targets: targets,
            script: script,
            hooklib: hooklib,
            hooklibEntry: hooklibEntry
        )
    }

    private static func requiredString(_ dict: [String: Any], key: String) throws -> String {
        guard let value = dict[key] as? String, !value.isEmpty else {
            throw PluginParseError.missingField(key)
        }
        return value
    }

    private static func buildUI(from value: Any?) throws -> [PluginUIElement] {
        guard let array = value as? [Any] else {
            return []
        }
        return try array.map { item -> PluginUIElement in
            guard let elementDict = item as? [String: Any] else {
                throw PluginParseError.invalidStructure("ui 数组元素应为映射")
            }
            let type = try requiredString(elementDict, key: "type")
            let key = try requiredString(elementDict, key: "key")
            let label = elementDict["label"] as? String
            let defaultValue = elementDict["default"].flatMap(PluginConfigValue.from)
            return PluginUIElement(type: type, key: key, label: label, defaultValue: defaultValue)
        }
    }

    private static func buildTargets(from value: Any?) throws -> [PluginTarget] {
        guard let array = value as? [Any] else {
            return []
        }
        return try array.map { item -> PluginTarget in
            guard let targetDict = item as? [String: Any] else {
                throw PluginParseError.invalidStructure("targets 数组元素应为映射")
            }
            return try buildTarget(from: targetDict)
        }
    }

    private static func buildTarget(from dict: [String: Any]) throws -> PluginTarget {
        let bundleId = dict["bundle_id"] as? String
        let process = dict["process"] as? String
        let uiSkip = dict["ui_skip"] as? Bool
        let speedHook = dict["speed_hook"] as? Bool
        let children = try buildTargets(from: dict["children"])
        return PluginTarget(
            bundleId: bundleId,
            process: process,
            uiSkip: uiSkip,
            speedHook: speedHook,
            children: children.isEmpty ? nil : children
        )
    }
}
