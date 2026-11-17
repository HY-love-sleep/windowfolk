import Foundation
import WindowfolkCore

// Prompt_Manifest 的数据模型（design.md「Prompt_Manifest 模型、解析与格式化」）。
// 解析见 ManifestParser，格式化见 ManifestPrinter。

/// 四组 Palette。`allCases` 顺序即 Prompt_Composer 输出各组色值的顺序。
public enum PaletteGroup: String, CaseIterable, Hashable, Sendable {
    case residentA = "resident_a"
    case residentB = "resident_b"
    case wood
    case plant

    /// 该组必须包含的颜色（Requirement 1.2）：两组居民 5 色，木制物件与植物 4 色。
    /// 顺序按 `PaletteColorName.allCases`。
    public var requiredColors: [PaletteColorName] {
        switch self {
        case .residentA, .residentB:
            return PaletteColorName.allCases
        case .wood, .plant:
            return [.main, .shadow, .highlight, .outline]
        }
    }
}

/// Palette 颜色名。`allCases` 顺序即固定顺序：主色、阴影色、高光色、描边色、腮红色。
public enum PaletteColorName: String, CaseIterable, Hashable, Sendable {
    case main
    case shadow
    case highlight
    case outline
    case blush
}

/// 8 位 RGB 颜色。文件中写成 `#RRGGBB`，解析时大小写不敏感，输出统一为大写。
public struct RGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// 解析 `#RRGGBB`（`#` 后恰好 6 位十六进制数字，大小写都可以）；格式不符时返回 nil。
    public init?(hex: String) {
        let scalars = Array(hex.unicodeScalars)
        guard scalars.count == 7, scalars[0] == "#" else { return nil }
        var values: [UInt8] = []
        values.reserveCapacity(3)
        for index in stride(from: 1, to: 7, by: 2) {
            guard let high = RGB.hexDigit(scalars[index]),
                  let low = RGB.hexDigit(scalars[index + 1]) else { return nil }
            values.append(high << 4 | low)
        }
        self.init(r: values[0], g: values[1], b: values[2])
    }

    /// 大写 `#RRGGBB`。
    public var hex: String {
        "#" + [r, g, b].map { RGB.twoDigits($0) }.joined()
    }

    private static func hexDigit(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)        // 0-9
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)   // A-F
        case 0x61...0x66: return UInt8(scalar.value - 0x61 + 10)   // a-f
        default: return nil
        }
    }

    private static func twoDigits(_ value: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(value >> 4)], digits[Int(value & 0x0F)]])
    }
}

/// 像素尺寸。清单中的画布写成 `WxH`。
public struct PixelSize: Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// 解析 `WxH`：两个由 `x` 分隔的正整数（只允许 ASCII 数字）；否则返回 nil。
    public init?(canvas text: String) {
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = PixelSize.positiveInt(parts[0]),
              let height = PixelSize.positiveInt(parts[1]) else { return nil }
        self.init(width: width, height: height)
    }

    /// `WxH` 形式的文本。
    public var canvasString: String { "\(width)x\(height)" }

    private static func positiveInt(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
              let value = Int(text), value > 0 else { return nil }
        return value
    }
}

/// 帧的排列方式。目前只有从左到右水平排列、帧间无间隔一种（Requirement 2.2）。
public enum FrameLayout: String, CaseIterable, Hashable, Sendable {
    case horizontalNoGap = "horizontal_no_gap"
}

/// 一条 Prompt_Entry。
public struct PromptEntry: Hashable, Sendable {
    public var key: String
    public var description: String
    public var frames: Int
    public var layout: FrameLayout
    public var canvas: PixelSize
    /// 相对仓库根目录的参考图路径。
    public var references: [String]

    public init(
        key: String,
        description: String,
        frames: Int,
        layout: FrameLayout = .horizontalNoGap,
        canvas: PixelSize,
        references: [String] = []
    ) {
        self.key = key
        self.description = description
        self.frames = frames
        self.layout = layout
        self.canvas = canvas
        self.references = references
    }
}

/// 结构化的 Prompt_Manifest。
public struct PromptManifest: Hashable, Sendable {
    /// 公共提示词前缀；文件中按 `\n` 切成字符串数组存放。
    public var prefix: String
    public var palettes: [PaletteGroup: [PaletteColorName: RGB]]
    /// 按 Asset_Catalog 顺序排列。
    public var entries: [PromptEntry]

    public init(
        prefix: String,
        palettes: [PaletteGroup: [PaletteColorName: RGB]],
        entries: [PromptEntry]
    ) {
        self.prefix = prefix
        self.palettes = palettes
        self.entries = entries
    }

    /// 按 Asset_Key 查条目。
    public func entry(for key: String) -> PromptEntry? {
        entries.first { $0.key == key }
    }
}

/// 解析清单时发现的一个问题。
public struct ManifestIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Location: Hashable, Sendable {
        /// JSON 语法错误所在行（从 1 开始）。
        case line(Int)
        /// 条目问题：Asset_Key 与出错字段名。
        case entry(key: String, field: String)
        /// Palette 问题：组名与颜色名（缺整组时颜色名为 nil）。
        case palette(group: String, color: String?)
        /// 文档级字段问题，如 `prefix`、`entries`。
        case document(field: String)
    }

    public var location: Location
    public var message: String

    public init(location: Location, message: String) {
        self.location = location
        self.message = message
    }

    public var description: String {
        let place: String
        switch location {
        case .line(let line):
            place = "第 \(line) 行"
        case .entry(let key, let field):
            place = "\(key).\(field)"
        case .palette(let group, let color):
            place = color.map { "Palette \(group).\($0)" } ?? "Palette \(group)"
        case .document(let field):
            place = field
        }
        return "\(place)：\(message)"
    }
}
