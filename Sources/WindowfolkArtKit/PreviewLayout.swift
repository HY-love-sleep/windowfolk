import Foundation
import WindowfolkCore

// 预览总览图布局（design.md「预览与设定图布局」，R7.2–R7.5）。
//
// 这里只做纯布局计算：背景色、每行标签与帧的矩形、缺失或不合规素材的标记区域。
// 读 PNG、缩放和 CoreText 绘制在 WindowfolkArtIO 的 PreviewRenderer（任务 10.5）。
//
// 坐标与 PixelRect 相同：原点在左上角，y 向下，单位为总览图像素。
// 「比例 2」表示素材的 1 个像素对应总览图的 1 个像素（即 @2x 原样）；
// 「比例 1」表示每帧缩小为 pt 宽 × pt 高个像素（R7.5）。

/// 总览图主题：深色或浅色背景（R7.1、R7.2）。
public enum PreviewTheme: String, Hashable, Sendable, CaseIterable {
    case dark, light

    /// 单一纯色背景。深色每通道 ≤ 48，浅色每通道 ≥ 208（R7.2）。不使用渐变或棋盘格。
    public var background: RGBA {
        switch self {
        case .dark: return RGBA(r: 32, g: 32, b: 36, a: 255)
        case .light: return RGBA(r: 232, g: 232, b: 228, a: 255)
        }
    }

    /// 标签和标记文字的颜色，与背景形成对比。
    public var foreground: RGBA {
        switch self {
        case .dark: return RGBA(r: 228, g: 228, b: 228, a: 255)
        case .light: return RGBA(r: 32, g: 32, b: 32, a: 255)
        }
    }

    /// 标记区域的填充色（不透明、与背景不同）。
    public var markerFill: RGBA {
        switch self {
        case .dark: return RGBA(r: 120, g: 40, b: 48, a: 255)
        case .light: return RGBA(r: 240, g: 176, b: 176, a: 255)
        }
    }

    /// Work_Directory 下 `preview/` 中的文件名。
    public var fileName: String { "preview_\(rawValue).png" }
}

public struct PreviewLayout: Hashable, Sendable {
    /// 一行：一个 Asset_Key 的标签、帧条或标记。
    public struct Row: Hashable, Sendable {
        public var key: String
        /// 标签文字矩形的左上角（等于 `labelRect` 的原点）。
        public var labelOrigin: PixelPoint
        /// 标签文字矩形：在行左侧，高度 ≥ `labelTextHeight`，不与任何帧或标记相交（R7.3）。
        public var labelRect: PixelRect
        /// 正常显示时的帧条：居民为比例 2 与比例 1 两条，其余为比例 2 一条（R7.5）。
        /// 有标记时为空，标记代替素材内容（R7.4）。
        public var strips: [Strip]
        /// 缺失或不合规时的标记；正常显示时为 nil。
        public var marker: Marker?
        /// 整行占用的区域（含标签区）。
        public var bounds: PixelRect
    }

    /// 一条帧条：素材全部帧按帧序从左到右排列。
    public struct Strip: Hashable, Sendable {
        /// 2 或 1。
        public var scale: Int
        /// 每帧在总览图中的目标矩形，按帧序排列；相邻两帧至少间隔 `frameGap` 像素（R7.3）。
        public var frameRects: [PixelRect]
    }

    /// 缺失或不合规素材的标记（R7.4）。
    public struct Marker: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case missing
            case invalid([ValidationRule])
        }

        public var kind: Kind
        /// 与 Expected_Pixel_Size 等大的标记区域。
        public var rect: PixelRect
        /// 「缺失」，或按 `ValidationRule.allCases` 顺序列出的未通过规则名称，以「、」连接。
        public var text: String
        /// 标记文字的绘制区域：从标记左上角内缩 `markerTextInset` 起，向右延伸到画布内边距；
        /// 标记本身可能只有 32×12 像素，放不下完整的规则名称。
        public var textRect: PixelRect
    }

    public var canvas: PixelSize
    public var rows: [Row]

    // MARK: 常量

    /// 画布四周的空白。
    public static let margin = 16
    /// 左侧标签区宽度，容纳最长的 Asset_Key（如 `resident_a_celebrating`）。
    public static let labelWidth = 200
    /// 标签文字高度，≥ 10（R7.3）。
    public static let labelTextHeight = 14
    /// 标签区与帧区之间的空白。
    public static let labelGap = 12
    /// 同一帧条中相邻两帧之间的背景间隔，≥ 4（R7.3）。
    public static let frameGap = 8
    /// 比例 2 帧条与比例 1 帧条之间的空白。
    public static let stripGap = 32
    /// 相邻两行之间的空白。
    public static let rowGap = 12
    /// 标记文字相对标记左上角的内缩。
    public static let markerTextInset = 2

    /// 帧区左边界的 x 坐标。
    public static var contentX: Int { margin + labelWidth + labelGap }

    // MARK: 构造

    /// 全部 45 个 Asset_Key 都正常显示时的布局。
    public static func make() -> PreviewLayout {
        make(verdicts: Dictionary(uniqueKeysWithValues: AssetCatalog.all.map { ($0.key, AssetVerdict.pass) }))
    }

    /// 按 Asset_Catalog 顺序为 45 个 Asset_Key 各排一行（R7.3）。
    ///
    /// `verdicts` 中为 `.pass` 的键正常显示；`.missing` 或字典中没有的键标为「缺失」；
    /// `.fail` 的键标出未通过的规则名称（R7.4）。字典中不属于 Asset_Catalog 的键被忽略。
    /// 画布尺寸只取决于 Asset_Catalog，不随 `verdicts` 变化。
    public static func make(verdicts: [String: AssetVerdict]) -> PreviewLayout {
        let specs = AssetCatalog.all
        let contentWidth = specs.map { normalContentWidth($0) }.max() ?? 0
        let canvasWidth = contentX + contentWidth + margin
        let textRight = canvasWidth - margin

        var rows: [Row] = []
        rows.reserveCapacity(specs.count)
        var y = margin
        for spec in specs {
            let marker = markerKind(verdicts[spec.key])
            let row = makeRow(spec: spec, marker: marker, top: y, textRight: textRight)
            rows.append(row)
            y = row.bounds.maxY + rowGap
        }
        let canvasHeight = (rows.last.map { $0.bounds.maxY } ?? margin) + margin
        return PreviewLayout(canvas: PixelSize(width: canvasWidth, height: canvasHeight), rows: rows)
    }

    // MARK: 内部

    /// 居民素材画比例 2 与比例 1 两遍，其余只画比例 2（R7.5）。
    static func scales(for spec: AssetSpec) -> [Int] {
        AssetRules.rules(for: spec.key)?.owner != nil ? [2, 1] : [2]
    }

    /// 某比例下每帧的像素尺寸。比例 2 为 Expected_Pixel_Size 的每帧部分，比例 1 为 pt 尺寸。
    static func frameSize(_ spec: AssetSpec, scale: Int) -> PixelSize {
        if scale == 2 {
            return PixelSize(width: spec.expectedPixelWidth / spec.frames, height: spec.expectedPixelHeight)
        }
        return PixelSize(width: Int(spec.size.width.rounded()), height: Int(spec.size.height.rounded()))
    }

    private static func stripWidth(_ spec: AssetSpec, scale: Int) -> Int {
        let fw = frameSize(spec, scale: scale).width
        return spec.frames * fw + (spec.frames - 1) * frameGap
    }

    /// 正常显示时帧区的总宽度。
    private static func normalContentWidth(_ spec: AssetSpec) -> Int {
        let widths = scales(for: spec).map { stripWidth(spec, scale: $0) }
        return widths.reduce(0, +) + max(0, widths.count - 1) * stripGap
    }

    private static func markerKind(_ verdict: AssetVerdict?) -> Marker.Kind? {
        switch verdict {
        case .pass?: return nil
        case .missing?, nil: return .missing
        case let .fail(rules, _)?: return .invalid(rules)
        }
    }

    static func markerText(_ kind: Marker.Kind) -> String {
        switch kind {
        case .missing:
            return "缺失"
        case .invalid(let rules):
            let ordered = ValidationRule.allCases.filter { rules.contains($0) }
            return ordered.map(\.rawValue).joined(separator: "、")
        }
    }

    private static func makeRow(spec: AssetSpec, marker kind: Marker.Kind?, top: Int, textRight: Int) -> Row {
        // 行高取素材内容高度和标签高度中的较大者；内容和标签都在行内垂直居中。
        let contentHeight: Int
        if kind != nil {
            contentHeight = spec.expectedPixelHeight
        } else {
            contentHeight = scales(for: spec).map { frameSize(spec, scale: $0).height }.max() ?? 0
        }
        let rowHeight = max(contentHeight, labelTextHeight)
        let labelRect = PixelRect(x: margin, y: top + (rowHeight - labelTextHeight) / 2,
                                  width: labelWidth, height: labelTextHeight)

        var strips: [Strip] = []
        var marker: Marker?
        if let kind {
            let h = spec.expectedPixelHeight
            let rect = PixelRect(x: contentX, y: top + (rowHeight - h) / 2,
                                 width: spec.expectedPixelWidth, height: h)
            let textX = rect.x + markerTextInset
            let textHeight = max(labelTextHeight, h - 2 * markerTextInset)
            let textRect = PixelRect(x: textX, y: top + (rowHeight - textHeight) / 2,
                                     width: max(rect.width - 2 * markerTextInset, textRight - textX),
                                     height: textHeight)
            marker = Marker(kind: kind, rect: rect, text: markerText(kind), textRect: textRect)
        } else {
            var x = contentX
            for scale in scales(for: spec) {
                let size = frameSize(spec, scale: scale)
                let fy = top + (rowHeight - size.height) / 2
                var rects: [PixelRect] = []
                rects.reserveCapacity(spec.frames)
                for i in 0..<spec.frames {
                    rects.append(PixelRect(x: x + i * (size.width + frameGap), y: fy,
                                           width: size.width, height: size.height))
                }
                strips.append(Strip(scale: scale, frameRects: rects))
                x += stripWidth(spec, scale: scale) + stripGap
            }
        }

        let bounds = PixelRect(x: margin, y: top, width: textRight - margin, height: rowHeight)
        return Row(key: spec.key, labelOrigin: PixelPoint(x: labelRect.x, y: labelRect.y),
                   labelRect: labelRect, strips: strips, marker: marker, bounds: bounds)
    }
}
