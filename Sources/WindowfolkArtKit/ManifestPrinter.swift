import Foundation
import WindowfolkCore

// Prompt_Manifest 格式化（design.md「Prompt_Manifest 模型、解析与格式化」，Requirement 2.10）。
//
// 输出规则：
// - `JSONEncoder` 选项固定为 `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`，结尾补一个换行；
// - `prefix` 按 `\n` 切成字符串数组（解析时再用 `\n` 连接）；
// - `canvas` 写成 `WxH`，色值写成大写 `#RRGGBB`；
// - `entries` 按 `AssetCatalog.all` 顺序，不在目录中的键排在最后并保持原相对顺序；
// - 顶层 `version` 固定为 1。
// 键排序和固定选项保证同一清单对象每次输出逐字节相同。

public enum ManifestPrinter {
    /// 清单文件格式版本。
    public static let version = 1

    /// 把清单对象格式化为 UTF-8 JSON 文本。
    public static func print(_ manifest: PromptManifest) -> Data {
        let document = Document(
            entries: orderedEntries(manifest.entries).map(Entry.init),
            palettes: palettes(manifest.palettes),
            prefix: prefixLines(manifest.prefix),
            version: version
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // 文档只含字符串、整数、数组和字典，编码不会失败。
        guard var data = try? encoder.encode(document) else {
            preconditionFailure("Prompt_Manifest 编码失败")
        }
        data.append(0x0A)
        return data
    }

    /// 前缀按 `\n` 切成行；按 Unicode 标量切分，`\r\n` 中的 `\r` 留在上一行末尾，连接后原样还原。
    static func prefixLines(_ prefix: String) -> [String] {
        prefix.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// 条目按 Asset_Catalog 顺序排列；目录外的键排在最后，保持原相对顺序。
    static func orderedEntries(_ entries: [PromptEntry]) -> [PromptEntry] {
        let rank = Dictionary(
            AssetCatalog.all.enumerated().map { ($0.element.key, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries.enumerated()
            .sorted { lhs, rhs in
                let l = rank[lhs.element.key] ?? Int.max
                let r = rank[rhs.element.key] ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func palettes(_ palettes: [PaletteGroup: [PaletteColorName: RGB]]) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for (group, colors) in palettes {
            var row: [String: String] = [:]
            for (name, color) in colors {
                row[name.rawValue] = color.hex
            }
            result[group.rawValue] = row
        }
        return result
    }

    // MARK: - 编码用结构（属性名即 JSON 键，按 sortedKeys 输出）

    private struct Document: Encodable {
        var entries: [Entry]
        var palettes: [String: [String: String]]
        var prefix: [String]
        var version: Int
    }

    private struct Entry: Encodable {
        var canvas: String
        var description: String
        var frames: Int
        var key: String
        var layout: String
        var references: [String]

        init(_ entry: PromptEntry) {
            canvas = entry.canvas.canvasString
            description = entry.description
            frames = entry.frames
            key = entry.key
            layout = entry.layout.rawValue
            references = entry.references
        }
    }
}
