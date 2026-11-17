import Foundation
import WindowfolkCore

// Prompt_Manifest_Parser（design.md「Prompt_Manifest 模型、解析与格式化」）。
//
// 解析分两步：先用 JSONSerialization 判定语法，语法错误按
// NSJSONSerializationErrorIndex 换算成行号；语法正确时用 JSONDecoder 读出原始字典
// （JSONSerialization 会删掉字符串开头的 U+FEFF），再逐项检查并收集全部问题，
// 只有问题列表为空时才返回 PromptManifest（R1.6、R2.8、R2.9、R2.13）。

/// 解析失败时的问题列表。
///
/// `Result` 要求 Failure 遵循 `Error`，`[ManifestIssue]` 本身不满足，因此用这个包装类型。
/// 它是随机访问集合，也可以用数组字面量构造，使用方式与 `[ManifestIssue]` 基本相同。
public struct ManifestIssues: Error, Hashable, Sendable, RandomAccessCollection,
    ExpressibleByArrayLiteral, CustomStringConvertible {
    public var issues: [ManifestIssue]

    public init(_ issues: [ManifestIssue]) { self.issues = issues }
    public init(arrayLiteral elements: ManifestIssue...) { self.issues = elements }

    public var startIndex: Int { issues.startIndex }
    public var endIndex: Int { issues.endIndex }
    public subscript(position: Int) -> ManifestIssue { issues[position] }

    /// 每个问题一行。
    public var description: String { issues.map(\.description).joined(separator: "\n") }
}

public enum ManifestParser {
    /// 两位居民 Character_Sheet 的固定路径（相对仓库根目录）。
    public static func characterSheetPath(_ owner: ResidentOwner) -> String {
        "art/character_sheets/\(owner.residentID.rawValue).png"
    }

    /// 描述长度上限（字符数）。
    public static let maxDescriptionLength = 1000

    /// 解析清单文件内容。
    ///
    /// - Parameters:
    ///   - data: 文件内容，须为 UTF-8 JSON。
    ///   - fileExists: 判断参考图路径（按文件中写法原样传入，相对仓库根目录）是否存在。
    /// - Returns: 无问题时返回清单对象，条目按 Asset_Catalog 顺序；否则返回全部问题。
    public static func parse(
        _ data: Data,
        fileExists: (String) -> Bool
    ) -> Result<PromptManifest, ManifestIssues> {
        if let offset = firstInvalidUTF8Offset(data) {
            return .failure([ManifestIssue(
                location: .line(lineNumber(atByteOffset: offset, in: data)),
                message: "文件不是合法的 UTF-8 文本"
            )])
        }

        let root: Any
        do {
            // JSONSerialization 只用来判定语法并给出错误偏移；它会删掉字符串开头的 U+FEFF，
            // 所以取值改用 JSONDecoder 读出的树（jsonObject(from:)）。
            let checked = try JSONSerialization.jsonObject(with: data, options: [])
            root = (try? jsonObject(from: data)) ?? checked
        } catch {
            let info = (error as NSError).userInfo
            let line: Int
            if let offset = info["NSJSONSerializationErrorIndex"] as? Int {
                line = lineNumber(atByteOffset: offset, in: data)
            } else {
                line = lineNumber(atByteOffset: data.count, in: data)
            }
            return .failure([ManifestIssue(location: .line(line), message: "JSON 语法错误，无法解析")])
        }

        guard let document = root as? [String: Any] else {
            return .failure([ManifestIssue(location: .document(field: "root"), message: "顶层必须是 JSON 对象")])
        }

        var issues: [ManifestIssue] = []
        checkVersion(document, issues: &issues)
        let prefix = parsePrefix(document, issues: &issues)
        let palettes = parsePalettes(document, issues: &issues)
        let entries = parseEntries(document, fileExists: fileExists, issues: &issues)

        guard issues.isEmpty, let prefix, let entries else {
            return .failure(ManifestIssues(issues))
        }
        return .success(PromptManifest(prefix: prefix, palettes: palettes, entries: entries))
    }

    // MARK: - 文档级字段

    /// `version` 可以省略；写了就必须是 1。
    private static func checkVersion(_ document: [String: Any], issues: inout [ManifestIssue]) {
        guard let raw = document["version"] else { return }
        if integer(raw) != 1 {
            issues.append(ManifestIssue(location: .document(field: "version"), message: "只支持 version 1"))
        }
    }

    /// `prefix` 是字符串数组，用 `\n` 连接；拼接后为空白视为缺失。
    private static func parsePrefix(_ document: [String: Any], issues: inout [ManifestIssue]) -> String? {
        guard let raw = document["prefix"] else {
            issues.append(ManifestIssue(location: .document(field: "prefix"), message: "缺少公共提示词前缀"))
            return nil
        }
        guard let lines = raw as? [String] else {
            issues.append(ManifestIssue(location: .document(field: "prefix"), message: "公共提示词前缀必须是字符串数组"))
            return nil
        }
        let prefix = lines.joined(separator: "\n")
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues.append(ManifestIssue(location: .document(field: "prefix"), message: "公共提示词前缀为空"))
            return nil
        }
        return prefix
    }

    /// 四组 Palette 各自的必需颜色都要存在且为 `#RRGGBB`。
    /// 组内其他已知颜色名也会检查格式并保留；未知组名和颜色名忽略。
    private static func parsePalettes(
        _ document: [String: Any],
        issues: inout [ManifestIssue]
    ) -> [PaletteGroup: [PaletteColorName: RGB]] {
        var result: [PaletteGroup: [PaletteColorName: RGB]] = [:]
        guard let raw = document["palettes"] else {
            for group in PaletteGroup.allCases {
                issues.append(ManifestIssue(location: .palette(group: group.rawValue, color: nil), message: "缺少该组 Palette"))
            }
            return result
        }
        guard let groups = raw as? [String: Any] else {
            issues.append(ManifestIssue(location: .document(field: "palettes"), message: "palettes 必须是 JSON 对象"))
            return result
        }

        for group in PaletteGroup.allCases {
            guard let groupRaw = groups[group.rawValue] else {
                issues.append(ManifestIssue(location: .palette(group: group.rawValue, color: nil), message: "缺少该组 Palette"))
                continue
            }
            guard let colors = groupRaw as? [String: Any] else {
                issues.append(ManifestIssue(location: .palette(group: group.rawValue, color: nil), message: "Palette 必须是 JSON 对象"))
                continue
            }
            var parsed: [PaletteColorName: RGB] = [:]
            let required = Set(group.requiredColors)
            for name in PaletteColorName.allCases {
                guard let value = colors[name.rawValue] else {
                    if required.contains(name) {
                        issues.append(ManifestIssue(
                            location: .palette(group: group.rawValue, color: name.rawValue),
                            message: "缺少该颜色"
                        ))
                    }
                    continue
                }
                guard let text = value as? String, let rgb = RGB(hex: text) else {
                    issues.append(ManifestIssue(
                        location: .palette(group: group.rawValue, color: name.rawValue),
                        message: "色值必须是 #RRGGBB 形式"
                    ))
                    continue
                }
                parsed[name] = rgb
            }
            result[group] = parsed
        }
        return result
    }

    // MARK: - 条目

    private static func parseEntries(
        _ document: [String: Any],
        fileExists: (String) -> Bool,
        issues: inout [ManifestIssue]
    ) -> [PromptEntry]? {
        guard let raw = document["entries"] else {
            issues.append(ManifestIssue(location: .document(field: "entries"), message: "缺少条目列表"))
            return nil
        }
        guard let list = raw as? [Any] else {
            issues.append(ManifestIssue(location: .document(field: "entries"), message: "entries 必须是数组"))
            return nil
        }

        var byKey: [String: PromptEntry] = [:]
        var seen: Set<String> = []
        var allValid = true

        for (index, item) in list.enumerated() {
            guard let object = item as? [String: Any] else {
                issues.append(ManifestIssue(location: .document(field: "entries[\(index)]"), message: "条目必须是 JSON 对象"))
                allValid = false
                continue
            }
            guard let key = object["key"] as? String else {
                issues.append(ManifestIssue(location: .document(field: "entries[\(index)].key"), message: "条目缺少 Asset_Key"))
                allValid = false
                continue
            }

            let spec = AssetCatalog.spec(key)
            if spec == nil {
                issues.append(ManifestIssue(location: .entry(key: key, field: "key"), message: "未知的 Asset_Key"))
                allValid = false
            }
            if !seen.insert(key).inserted {
                issues.append(ManifestIssue(location: .entry(key: key, field: "key"), message: "Asset_Key 重复"))
                allValid = false
            }

            let before = issues.count
            let entry = parseEntry(key: key, object: object, spec: spec, fileExists: fileExists, issues: &issues)
            if issues.count != before { allValid = false }
            if let entry, spec != nil, byKey[key] == nil {
                byKey[key] = entry
            }
        }

        for spec in AssetCatalog.all where !seen.contains(spec.key) {
            issues.append(ManifestIssue(location: .entry(key: spec.key, field: "key"), message: "缺少该 Asset_Key 的条目"))
            allValid = false
        }

        guard allValid else { return nil }
        return AssetCatalog.all.compactMap { byKey[$0.key] }
    }

    private static func parseEntry(
        key: String,
        object: [String: Any],
        spec: AssetSpec?,
        fileExists: (String) -> Bool,
        issues: inout [ManifestIssue]
    ) -> PromptEntry? {
        func report(_ field: String, _ message: String) {
            issues.append(ManifestIssue(location: .entry(key: key, field: field), message: message))
        }

        var description: String?
        if let text = object["description"] as? String {
            if (1...maxDescriptionLength).contains(text.count) {
                description = text
            } else {
                report("description", "描述长度必须在 1 到 \(maxDescriptionLength) 个字符之间（当前 \(text.count)）")
            }
        } else {
            report("description", object["description"] == nil ? "缺少描述" : "描述必须是字符串")
        }

        var frames: Int?
        if let raw = object["frames"], let value = integer(raw), value > 0 {
            if let spec, spec.frames != value {
                report("frames", "帧数 \(value) 与 Asset_Catalog 的 \(spec.frames) 不一致")
            } else {
                frames = value
            }
        } else {
            report("frames", object["frames"] == nil ? "缺少帧数" : "帧数必须是正整数")
        }

        var layout: FrameLayout?
        if let text = object["layout"] as? String, let value = FrameLayout(rawValue: text) {
            layout = value
        } else {
            report("layout", object["layout"] == nil
                ? "缺少排列方式"
                : "排列方式必须是 \(FrameLayout.horizontalNoGap.rawValue)")
        }

        var canvas: PixelSize?
        if let text = object["canvas"] as? String, let value = PixelSize(canvas: text) {
            canvas = value
        } else {
            report("canvas", object["canvas"] == nil ? "缺少生成画布尺寸" : "画布尺寸必须写成 WxH，W、H 为正整数")
        }

        let references = parseReferences(
            key: key, raw: object["references"], fileExists: fileExists, report: report
        )

        guard let description, let frames, let layout, let canvas, let references else { return nil }
        return PromptEntry(
            key: key, description: description, frames: frames,
            layout: layout, canvas: canvas, references: references
        )
    }

    /// 参考图：省略视为空列表；每条路径必须存在；居民条目必须列出本人设定图且不列另一位的，
    /// 非居民条目不得列任一设定图（R2.6、R2.13）。比较前做 `standardizingPath`。
    private static func parseReferences(
        key: String,
        raw: Any?,
        fileExists: (String) -> Bool,
        report: (String, String) -> Void
    ) -> [String]? {
        let field = "references"
        var paths: [String] = []
        if let raw {
            guard let strings = raw as? [String] else {
                report(field, "参考图必须是字符串数组")
                return nil
            }
            paths = strings
        }

        var valid = true
        for path in paths where !fileExists(path) {
            report(field, "参考图不存在：\(path)")
            valid = false
        }

        // Asset_Key 未知时无法判断归属，跳过设定图规则。
        if let rules = AssetRules.rules(for: key) {
            let standardized = Set(paths.map { ($0 as NSString).standardizingPath })
            func listed(_ owner: ResidentOwner) -> Bool {
                standardized.contains(characterSheetPath(owner))
            }
            if let owner = rules.owner {
                if !listed(owner) {
                    report(field, "居民条目必须列出本人设定图 \(characterSheetPath(owner))")
                    valid = false
                }
                for other in ResidentOwner.allCases where other != owner && listed(other) {
                    report(field, "居民条目不能列出另一位居民的设定图 \(characterSheetPath(other))")
                    valid = false
                }
            } else {
                for owner in ResidentOwner.allCases where listed(owner) {
                    report(field, "非居民条目不能列出居民设定图 \(characterSheetPath(owner))")
                    valid = false
                }
            }
        }
        return valid ? paths : nil
    }

    // MARK: - 工具

    /// 把 JSON 文本读成与 `JSONSerialization.jsonObject` 同形的树：
    /// `[String: Any]`、`[Any]`、`String`、`NSNumber`（布尔值为 CFBoolean）、`NSNull`。
    ///
    /// 用 JSONDecoder 读取，字符串和键逐个 Unicode 标量原样保留（含开头的 U+FEFF）。
    public static func jsonObject(from data: Data) throws -> Any {
        try JSONDecoder().decode(JSONTree.self, from: data).value
    }

    /// JSONDecoder 用的通用 JSON 值。
    private struct JSONTree: Decodable {
        let value: Any

        private struct Key: CodingKey {
            let stringValue: String
            init(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            if let object = try? decoder.container(keyedBy: Key.self) {
                var result: [String: Any] = [:]
                for key in object.allKeys {
                    result[key.stringValue] = try object.decode(JSONTree.self, forKey: key).value
                }
                value = result
            } else if var array = try? decoder.unkeyedContainer() {
                var result: [Any] = []
                while !array.isAtEnd {
                    result.append(try array.decode(JSONTree.self).value)
                }
                value = result
            } else {
                let single = try decoder.singleValueContainer()
                if single.decodeNil() {
                    value = NSNull()
                } else if let bool = try? single.decode(Bool.self) {
                    value = NSNumber(value: bool)
                } else if let int = try? single.decode(Int.self) {
                    value = NSNumber(value: int)
                } else if let double = try? single.decode(Double.self) {
                    value = NSNumber(value: double)
                } else {
                    value = try single.decode(String.self)
                }
            }
        }
    }

    /// JSON 数字中的整数；布尔值和非整数返回 nil。
    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// 字节偏移所在的行号（从 1 开始）：偏移前的换行符个数加 1。
    static func lineNumber(atByteOffset offset: Int, in data: Data) -> Int {
        let end = min(max(offset, 0), data.count)
        return data.prefix(end).reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    /// 第一个非法 UTF-8 字节的偏移；全部合法时返回 nil。
    private static func firstInvalidUTF8Offset(_ data: Data) -> Int? {
        if String(data: data, encoding: .utf8) != nil { return nil }
        var parser = Unicode.UTF8.ForwardParser()
        var iterator = data.makeIterator()
        var offset = 0
        while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded):
                offset += encoded.count
            case .emptyInput:
                return nil
            case .error:
                return offset
            }
        }
    }
}
