import Foundation
import PropertyBased
import WindowfolkArtKit
import WindowfolkCore

// 合法 Prompt_Manifest 的共享生成器（design.md「生成器」表中的 `Gen.manifest`，任务 2.5）。
// ManifestRoundTripTests（Property 1）与 ManifestRejectionTests（Property 2）共用。
//
// 生成的清单满足 ManifestParser 的全部规则：
// - prefix 去掉空白后非空，可含多行、`\r\n`、空行、首尾空白；
// - 四组 Palette 都有必需颜色，`wood`、`plant` 随机带上可选的 `blush`；
// - 条目按 `AssetCatalog.all` 顺序各一条，帧数与目录一致，layout 为 `horizontal_no_gap`；
// - 描述 1 到 1000 个字符（含恰好 1 和恰好 1000 的边界），随机含引号、反斜杠、方括号、
//   换行、`\r\n`、制表符、中文、emoji、组合字符等；
// - 画布宽高为正整数；
// - 居民条目在 references 中列出本人设定图（位置随机），非居民条目不列任何设定图；
//   其余参考图来自固定的普通路径池，不会被 standardizingPath 归一成设定图路径。
// 解析时用 `ManifestGen.fileExists(for:)` 作为 fileExists，使所有引用的路径都“存在”。

/// 生成合法清单用到的素材与工具。
enum ManifestGen {
    /// 描述与前缀用的文本片段。单个片段可能含多个字符；拼接后相邻片段可能合并为一个字符
    /// （如 `\r` 与 `\n`、字母与组合符），长度在拼接后再截取。
    static let textChunks: [String] = [
        "a", "Z", "0", " ", "  ", "chibi", "2px outline", "sprite",
        "\"", "'", "\\", "\\n", "/", "[", "]", "{", "}", ":", ",", "#FF00AA",
        "\n", "\r\n", "\r", "\t", "\n\n",
        "你好", "小人", "窗台", "，", "。", "「引号」",
        "😀", "👩‍👩‍👧", "🇨🇳", "e\u{301}", "\u{301}", "é", "ß", "Ω", "ﬁ",
        "\u{200D}", "\u{2028}", "\u{FEFF}", "\u{1}", "\u{7F}", "<b>", "&amp;",
    ]

    /// 非设定图参考图路径池（相对仓库根目录）。
    static let extraReferencePaths: [String] = [
        "art/references/style.png",
        "art/references/pose_walk.png",
        "art/references/中文 参考.png",
        "art/references/[draft] \"v2\".png",
        "art/reference.png",
        "docs/mood board.jpg",
    ]

    /// 描述长度上限，取自解析器。
    static var maxDescription: Int { ManifestParser.maxDescriptionLength }

    /// 由片段拼出的文本。
    static var text: Generator<String, some SendableSequenceType> {
        Gen<String?>.element(of: textChunks).map { $0! }.array(of: 0...40).map { $0.joined() }
    }

    /// 1 到 1000 个字符的描述。约 1/10 恰好 1000 个字符，约 1/10 恰好 1 个字符。
    static var description: Generator<String, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...9),
            Gen<String?>.element(of: textChunks).map { $0! }.array(of: 1...80)
        ).map { pick, chunks -> String in
            var text = chunks.joined()
            switch pick {
            case 0:
                // 补足到 1000 个字符（“中”不会与前面的字符合并）。
                if text.count < maxDescription {
                    text += String(repeating: "中", count: maxDescription - text.count)
                }
            case 1:
                text = String(text.prefix(1))
            default:
                break
            }
            text = String(text.prefix(maxDescription))
            return text.isEmpty ? "x" : text
        }
    }

    /// 去掉空白后非空的前缀，可含多行、`\r\n` 与空行。
    static var prefix: Generator<String, some SendableSequenceType> {
        zip(text, text, Gen<Int>.int(in: 0...3)).map { head, tail, joiner -> String in
            let separator = ["\n", "\r\n", "\n\n", ""][joiner]
            let core = head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Cute chibi sprite" : head
            return core + separator + tail
        }
    }

    /// 四组 Palette，每组必需颜色齐全；`wood`、`plant` 随机带可选的 `blush`。
    static var palettes: Generator<[PaletteGroup: [PaletteColorName: RGB]], some SendableSequenceType> {
        let groups = PaletteGroup.allCases
        let colors = PaletteColorName.allCases
        return zip(
            Gen<UInt8>.uint8().array(of: groups.count * colors.count * 3),
            Gen<Bool>.bool.array(of: groups.count)
        ).map { bytes, extras -> [PaletteGroup: [PaletteColorName: RGB]] in
            var result: [PaletteGroup: [PaletteColorName: RGB]] = [:]
            for (g, group) in groups.enumerated() {
                let names = extras[g] ? colors : group.requiredColors
                var row: [PaletteColorName: RGB] = [:]
                for name in names {
                    let base = (g * colors.count + colors.firstIndex(of: name)!) * 3
                    row[name] = RGB(r: bytes[base], g: bytes[base + 1], b: bytes[base + 2])
                }
                result[group] = row
            }
            return result
        }
    }

    /// 单条目的随机部分：描述、画布宽高、额外参考图、设定图插入位置。
    struct EntryParts: Sendable {
        var description: String
        var width: Int
        var height: Int
        var extraReferences: [String]
        var sheetPosition: Int
    }

    static var entryParts: Generator<EntryParts, some SendableSequenceType> {
        zip(
            description,
            Gen<Int>.int(in: 1...8192),
            Gen<Int>.int(in: 1...8192),
            Gen<String?>.element(of: extraReferencePaths).map { $0! }.array(of: 0...3),
            Gen<Int>.int(in: 0...3)
        ).map { EntryParts(description: $0, width: $1, height: $2, extraReferences: $3, sheetPosition: $4) }
    }

    /// 按 Asset_Catalog 与 AssetRules 把随机部分组装成合法条目。
    static func entry(for spec: AssetSpec, _ parts: EntryParts) -> PromptEntry {
        var references = parts.extraReferences
        if let owner = AssetRules.rules(for: spec.key)?.owner {
            let index = min(parts.sheetPosition, references.count)
            references.insert(ManifestParser.characterSheetPath(owner), at: index)
        }
        return PromptEntry(
            key: spec.key,
            description: parts.description,
            frames: spec.frames,
            layout: .horizontalNoGap,
            canvas: PixelSize(width: parts.width, height: parts.height),
            references: references
        )
    }

    /// 清单中引用的全部参考图路径。
    static func referencedPaths(_ manifest: PromptManifest) -> Set<String> {
        Set(manifest.entries.flatMap(\.references))
    }

    /// 只认清单中引用的路径存在的 fileExists。
    static func fileExists(for manifest: PromptManifest) -> @Sendable (String) -> Bool {
        let paths = referencedPaths(manifest)
        return { paths.contains($0) }
    }
}

extension Gen where Value == PromptManifest {
    /// 合法清单：45 条（`AssetCatalog.all` 每项一条，按目录顺序），规则见文件头注释。
    static var manifest: Generator<PromptManifest, some SendableSequenceType> {
        zip(
            ManifestGen.prefix,
            ManifestGen.palettes,
            ManifestGen.entryParts.array(of: AssetCatalog.all.count)
        ).map { prefix, palettes, parts -> PromptManifest in
            PromptManifest(
                prefix: prefix,
                palettes: palettes,
                entries: Swift.zip(AssetCatalog.all, parts).map { ManifestGen.entry(for: $0, $1) }
            )
        }
    }
}
