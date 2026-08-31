import Foundation

/// 极简 YAML 子集解析器。
///
/// 仅覆盖本项目清单所需语法：顶层映射、空格缩进、数组「- 」项、
/// `key: value` 标量以及嵌套映射/数组。标量自动推断为布尔/整数/浮点/字符串。
struct SimpleYAMLParser {

    struct Row {
        let indent: Int
        let isList: Bool
        let content: String
    }

    /// 将 YAML 文本解析为一个类型擦除的字典。
    static func parse(_ yaml: String) throws -> [String: Any] {
        let rows = makeRows(yaml)
        guard !rows.isEmpty else {
            throw PluginParseError.emptyManifest
        }
        var position = 0
        let value = try parseBlock(rows, position: &position, baseIndent: rows[0].indent)
        guard let dict = value as? [String: Any] else {
            throw PluginParseError.invalidYAML("根节点必须是映射")
        }
        return dict
    }

    // MARK: - 行拆分

    private static func makeRows(_ yaml: String) -> [Row] {
        var rows: [Row] = []
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            let indent = line.prefix(while: { $0 == " " }).count
            let stripped = indent > 0 ? String(line.dropFirst(indent)) : String(line)
            let trimmedLine = stripped.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("#") {
                continue
            }
            let isList = trimmedLine.hasPrefix("- ")
            let content = isList
                ? String(trimmedLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                : trimmedLine
            if content.isEmpty {
                continue
            }
            rows.append(Row(indent: indent, isList: isList, content: content))
        }
        return rows
    }

    // MARK: - 递归块解析

    private static func parseBlock(_ rows: [Row], position: inout Int, baseIndent: Int) throws -> Any {
        guard position < rows.count else {
            throw PluginParseError.invalidYAML("块意外结束")
        }
        let first = rows[position]
        guard first.indent == baseIndent else {
            throw PluginParseError.invalidYAML("缩进不一致，期望 \(baseIndent) 得到 \(first.indent)")
        }
        if first.isList {
            return try parseListBlock(rows, position: &position, baseIndent: baseIndent)
        }
        return try parseMappingBlock(rows, position: &position, baseIndent: baseIndent)
    }

    private static func parseMappingBlock(
        _ rows: [Row],
        position: inout Int,
        baseIndent: Int
    ) throws -> [String: Any] {
        var dict = [String: Any]()
        var pendingKey: String?

        while position < rows.count {
            let row = rows[position]
            if row.indent < baseIndent {
                break
            }
            if row.indent > baseIndent {
                guard let key = pendingKey else {
                    throw PluginParseError.invalidYAML("无法归附子块到任何键")
                }
                let sub = try parseBlock(rows, position: &position, baseIndent: row.indent)
                dict[key] = sub
                pendingKey = nil
                continue
            }
            if row.isList {
                throw PluginParseError.invalidYAML("映射中不允许直接出现数组项")
            }
            let (key, value) = try splitMapping(row.content)
            if let value = value {
                dict[key] = value
                pendingKey = nil
            } else {
                pendingKey = key
            }
            position += 1
        }

        if let key = pendingKey {
            dict[key] = NSNull()
        }
        return dict
    }

    /// 数组块解析过程中维护的可变状态。
    private struct ListCursor {
        var items: [Any] = []
        var pendingKey: String?
        var lastElementIndex: Int?
        var lastElementIsScalar = false
    }

    /// 解析一个数组块。数组元素可以是标量或（以 `- key: value` 开头的）映射。
    private static func parseListBlock(
        _ rows: [Row],
        position: inout Int,
        baseIndent: Int
    ) throws -> [Any] {
        var cursor = ListCursor()

        while position < rows.count {
            let row = rows[position]
            if row.indent < baseIndent {
                break
            }
            if row.indent > baseIndent {
                try attachSubBlock(
                    rows,
                    position: &position,
                    baseIndent: row.indent,
                    cursor: &cursor
                )
                continue
            }
            if !row.isList {
                try appendContinuation(row, cursor: &cursor)
                position += 1
                continue
            }
            try appendNewItem(row, cursor: &cursor)
            position += 1
        }

        if let key = cursor.pendingKey, let index = cursor.lastElementIndex,
           var element = cursor.items[index] as? [String: Any] {
            element[key] = NSNull()
            cursor.items[index] = element
        }
        return cursor.items
    }

    /// 将更深的子块归属到上一个数组元素：标量元素被整体替换，映射元素填充空值键。
    private static func attachSubBlock(
        _ rows: [Row],
        position: inout Int,
        baseIndent: Int,
        cursor: inout ListCursor
    ) throws {
        let sub = try parseBlock(rows, position: &position, baseIndent: baseIndent)
        guard let index = cursor.lastElementIndex else {
            throw PluginParseError.invalidYAML("无法归附子块到数组元素")
        }
        if cursor.lastElementIsScalar {
            cursor.items[index] = sub
            cursor.lastElementIsScalar = false
            cursor.lastElementIndex = nil
            cursor.pendingKey = nil
            return
        }
        guard var element = cursor.items[index] as? [String: Any] else {
            throw PluginParseError.invalidYAML("无法归附子块到数组元素")
        }
        if let key = cursor.pendingKey {
            // 空值键（如 `- children:`）后跟更深子块：归属到该键
            element[key] = sub
            cursor.pendingKey = nil
        } else if let subDict = sub as? [String: Any] {
            // 带值键（如 `- type: toggle`）后跟续行属性：合并进当前元素
            for (k, v) in subDict {
                element[k] = v
            }
        }
        cursor.items[index] = element
        cursor.lastElementIsScalar = false
        cursor.lastElementIndex = nil
    }

    /// 处理当前映射元素的同名缩进续行属性。
    private static func appendContinuation(_ row: Row, cursor: inout ListCursor) throws {
        guard let index = cursor.lastElementIndex,
              var element = cursor.items[index] as? [String: Any] else {
            throw PluginParseError.invalidYAML("数组项缺少 '-' 前缀: \(row.content)")
        }
        let (key, value) = try splitMapping(row.content)
        if let value = value {
            element[key] = value
            cursor.pendingKey = nil
        } else {
            cursor.pendingKey = key
        }
        cursor.items[index] = element
    }

    /// 追加一个新的数组元素。
    private static func appendNewItem(_ row: Row, cursor: inout ListCursor) throws {
        let itemContent = row.content
        if let (key, value) = try? splitMapping(itemContent) {
            var element = [String: Any]()
            if let value = value {
                element[key] = value
                cursor.pendingKey = nil
            } else {
                element[key] = NSNull()
                cursor.pendingKey = key
            }
            cursor.items.append(element)
            cursor.lastElementIndex = cursor.items.count - 1
            cursor.lastElementIsScalar = false
        } else {
            cursor.items.append(scalarValue(itemContent))
            cursor.lastElementIndex = cursor.items.count - 1
            cursor.lastElementIsScalar = true
            cursor.pendingKey = nil
        }
    }

    // MARK: - 标量处理

    private static func splitMapping(_ text: String) throws -> (String, Any?) {
        guard let colonIndex = text.firstIndex(of: ":") else {
            throw PluginParseError.invalidYAML("缺少冒号: \(text)")
        }
        let key = String(text[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            throw PluginParseError.invalidYAML("空键: \(text)")
        }
        let rawValue = String(text[text.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)
        if rawValue.isEmpty {
            return (key, nil)
        }
        return (key, scalarValue(rawValue))
    }

    private static func scalarValue(_ raw: String) -> Any {
        if raw == "true" || raw == "false" {
            return raw == "true"
        }
        if raw == "null" || raw == "~" {
            return NSNull()
        }
        if let unquoted = stripQuotes(raw) {
            return unquoted
        }
        if raw.contains(".") {
            if let double = Double(raw) {
                return double
            }
        } else if let integer = Int(raw) {
            return integer
        }
        return raw
    }

    private static func stripQuotes(_ text: String) -> String? {
        guard text.count >= 2 else {
            return nil
        }
        let start = text.startIndex
        let end = text.index(before: text.endIndex)
        let first = text[start]
        let last = text[end]
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(text[text.index(after: start)..<end])
        }
        return nil
    }
}
