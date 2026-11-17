import Foundation
import WindowfolkCore

// 完整提示词组合（design.md「PromptComposer」，Requirement 2.12）。

/// 把清单中的公共前缀、适用 Palette 色值和条目描述拼成一条完整提示词。
public enum PromptComposer {
    /// 段与段之间的分隔：一个空行。
    static let separator = "\n\n"

    /// 为 `key` 组合完整提示词。
    ///
    /// 输出依次为 `prefix`、空行、每个适用 Palette 一行、空行、`description`。
    /// 适用 Palette 取自 `AssetRules.palettes`，组顺序按 `PaletteGroup.allCases`，
    /// 色名顺序按 `PaletteColorName.allCases`，色值为大写 `#RRGGBB`。
    /// 没有适用 Palette 时省略中间段和一个分隔。
    ///
    /// 纯函数：同一清单对同一键每次返回逐字节相同的字符串。
    /// 清单中没有该条目或该键不在 Asset_Catalog 中时返回 nil。
    public static func compose(_ manifest: PromptManifest, key: String) -> String? {
        guard let entry = manifest.entry(for: key),
              let rules = AssetRules.rules(for: key) else { return nil }

        let applicable = Set(rules.palettes)
        let paletteLines: [String] = PaletteGroup.allCases.compactMap { group in
            guard applicable.contains(group), let colors = manifest.palettes[group] else { return nil }
            let parts = PaletteColorName.allCases.compactMap { name -> String? in
                colors[name].map { "\(name.rawValue) \($0.hex)" }
            }
            return "Palette \(group.rawValue): " + parts.joined(separator: ", ")
        }

        var sections = [manifest.prefix]
        if !paletteLines.isEmpty {
            sections.append(paletteLines.joined(separator: "\n"))
        }
        sections.append(entry.description)
        return sections.joined(separator: separator)
    }
}
