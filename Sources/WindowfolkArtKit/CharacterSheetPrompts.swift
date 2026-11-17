import Foundation
import WindowfolkCore

// 设定图提示词（design.md「Character_Sheet 布局」，R1.1、R1.4）。
//
// `sheet generate` 用这里的固定描述调用 generations 接口。描述内容取自
// `docs/art-spec.md` 第 1 节，并逐项覆盖 R1.4 的确认清单；
// 完整提示词按 PromptComposer 的格式拼接：公共前缀、空行、该居民 Palette 一行、空行、描述。
// 色块行不让模型画，由 SheetLayout 直接填色（R1.5）。

public enum CharacterSheetPrompts {
    /// 设定图生成请求的画布：三视图各占 512×1024。
    public static let requestCanvas = PixelSize(width: 1536, height: 1024)

    /// 设定图的仓库相对路径。
    public static func sheetPath(for owner: ResidentOwner) -> String {
        "art/character_sheets/\(owner.residentID.rawValue).png"
    }

    /// 该居民对应的 Palette 组。
    public static func paletteGroup(for owner: ResidentOwner) -> PaletteGroup {
        switch owner {
        case .a: return .residentA
        case .b: return .residentB
        }
    }

    /// 三视图排版要求，两位居民共用。
    static let layoutText = """
        Character turnaround sheet of one character on a transparent background, \
        three full-body views of the same character at the same scale, arranged left to right \
        in three equal-width cells with no overlap: front view, side view facing right, back view. \
        Each view stands at the bottom of its cell and is horizontally centered in it. \
        The character fills most of the cell height. \
        Do not draw color swatches, labels, text, ground, shadows or background.
        """

    /// 两位居民共同的比例要求（R1.4 共同项）。
    static let proportionText = """
        Chibi proportions: head height about equal to body height (head-to-body ratio about 1:1), \
        the head makes up most of the figure, very short limbs. \
        Clear silhouette and soft colors that stay recognizable at 32pt.
        """

    /// 不含前缀和 Palette 的角色描述。
    public static func description(for owner: ResidentOwner) -> String {
        let character: String
        switch owner {
        case .a:
            // 都都：圆脸银渐层小猫。
            character = """
                The character is a round-faced silver shaded kitten. \
                Fur is a gradient from silver white to light gray; the back and the top of the head are slightly darker; \
                the limbs and belly are whitish. Round face, short nose, small triangular ears with pink inner ears, \
                big round emerald green or teal eyes. Fluffy tail with a slightly darker tip. \
                Curious, a little impatient and warm-hearted; often tilts its head.
                """
        case .b:
            // 嘟嘟：金丝熊（金黄色仓鼠）。
            character = """
                The character is a golden hamster. \
                Fur is golden with an orange tint; the belly and the area around the mouth are creamy white. \
                Round chubby body, small round ears, small shiny black eyes, puffed-out cheeks, \
                tiny front paws held together in front of the chest. The tail is almost invisible. \
                Slow, gentle and content.
                """
        }
        return [layoutText, character, proportionText].joined(separator: "\n")
    }

    /// 完整提示词：`prefix`、空行、`Palette <组名>: main #…, shadow #…, …`、空行、描述。
    ///
    /// 纯函数；清单缺少该居民 Palette 组时省略 Palette 段。
    public static func compose(_ manifest: PromptManifest, owner: ResidentOwner) -> String {
        let group = paletteGroup(for: owner)
        var sections = [manifest.prefix]
        if let colors = manifest.palettes[group] {
            let parts = PaletteColorName.allCases.compactMap { name -> String? in
                colors[name].map { "\(name.rawValue) \($0.hex)" }
            }
            sections.append("Palette \(group.rawValue): " + parts.joined(separator: ", "))
        }
        sections.append(description(for: owner))
        return sections.joined(separator: PromptComposer.separator)
    }
}
