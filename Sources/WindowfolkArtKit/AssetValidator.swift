import Foundation
import WindowfolkCore

// 素材校验（design.md「Asset_Validator 规则」，Requirement 6.2–6.7、6.10）。
//
// 本层是纯逻辑：PNG 解码在 WindowfolkArtIO，这里只接收已解码的 RGBAImage
// 和「PNG 颜色类型是否含 alpha」。目录报告见 ValidationReport.swift。

/// 校验规则。名称取自 R6.1 的固定集合；`allCases` 的顺序就是结果中列出规则的顺序。
public enum ValidationRule: String, CaseIterable, Hashable, Sendable {
    case fileFormat = "文件格式"
    case pixelSize = "像素尺寸"
    case alphaChannel = "alpha 通道"
    case cornersTransparent = "四角透明"
    case grounded = "贴底"
    case centered = "水平居中"
    case emptyFrame = "空帧"
    case identicalFrames = "帧内容相同"
    case tileEdge = "平铺边缘"
}

/// IO 层解码出的 PNG。
public struct DecodedPNG: Hashable, Sendable {
    /// 非预乘 RGBA 像素。颜色类型不含 alpha 时，由解码方按不透明填充 alpha。
    public var image: RGBAImage
    /// PNG 颜色类型是否包含 alpha 通道（规则「alpha 通道」，R6.2）。
    public var hasAlpha: Bool

    public init(image: RGBAImage, hasAlpha: Bool) {
        self.image = image
        self.hasAlpha = hasAlpha
    }
}

/// 一个 Asset_Key 的校验结论。
public enum AssetVerdict: Hashable, Sendable {
    case pass
    /// 目录中没有 `<Asset_Key>.png`（由目录报告层给出，`validate` 不返回此值）。
    case missing
    /// 按 `ValidationRule.allCases` 顺序列出全部未通过规则；
    /// `emptyFrames` 为空帧序号（从 1 开始，升序），只有含 `.emptyFrame` 时非空。
    case fail([ValidationRule], emptyFrames: [Int])
}

public enum AssetValidator {
    /// 贴底：每帧最下方不透明像素行距底边的最大距离（R6.4）。
    public static let groundedTolerance = 2
    /// 水平居中：不透明边界框水平中心与帧中心的最大偏差（R6.4）。
    public static let centeredTolerance = 6
    /// 四角透明：每个角检查的正方形边长（R6.3）。
    public static let cornerSize = 2
    /// 平铺边缘阈值（R6.7，同 R4.10、R4.11）。
    public static let tileAlphaTolerance = 16
    public static let tileColorTolerance = 24

    /// 校验一个 Asset_Key 的 PNG。`decoded` 为 nil 表示文件不能解码为 PNG。
    ///
    /// 顺序：文件格式 → 像素尺寸（`AssetCatalog.validation`，R6.10）→ alpha 通道。
    /// 文件格式或像素尺寸未通过时不做帧级检查（R6.2）。帧级规则各自独立计算后合并。
    /// `key` 不在 Asset_Catalog 中时没有期望尺寸，按「像素尺寸」未通过处理。
    public static func validate(key: String, decoded: DecodedPNG?) -> AssetVerdict {
        guard let decoded else { return .fail([.fileFormat], emptyFrames: []) }

        var failed = Set<ValidationRule>()
        if !decoded.hasAlpha { failed.insert(.alphaChannel) }

        let image = decoded.image
        let validation = AssetCatalog.validation(fileName: key + ".png",
                                                 pixelWidth: image.width,
                                                 pixelHeight: image.height)
        guard case .valid(let spec) = validation, let rules = AssetRules.rules(for: key) else {
            failed.insert(.pixelSize)
            return verdict(failed, emptyFrames: [])
        }

        let frameRects = FrameSlicer.frameRects(width: image.width, height: image.height,
                                                frames: spec.frames)

        // 空帧（R6.5）：不含 Opaque_Pixel 的帧，序号从 1 开始。
        var emptyFrames: [Int] = []
        var frameBounds: [(frame: PixelRect, bbox: PixelRect)] = []
        for (index, rect) in frameRects.enumerated() {
            if let bbox = image.opaqueBounds(in: rect) {
                frameBounds.append((rect, bbox))
            } else {
                emptyFrames.append(index + 1)
            }
        }
        if !emptyFrames.isEmpty { failed.insert(.emptyFrame) }

        // 四角透明（R6.3）：只对 Framed_Asset。
        if rules.isFramed, !frameRects.allSatisfy({ cornersTransparent(image, in: $0) }) {
            failed.insert(.cornersTransparent)
        }

        // 贴底与水平居中（R6.4）：只对 Grounded_State 居民；空帧已由「空帧」报告，这里跳过。
        if rules.isGrounded {
            for (frame, bbox) in frameBounds {
                if frame.maxY - bbox.maxY > groundedTolerance { failed.insert(.grounded) }
                // 用两倍坐标避免半像素：|2·bbox中心 − 2·帧中心| ≤ 2·容差。
                let offset2 = (bbox.minX + bbox.maxX) - (frame.minX + frame.maxX)
                if abs(offset2) > 2 * centeredTolerance { failed.insert(.centered) }
            }
        }

        // 帧内容相同（R6.6）：帧数 > 1 且所有帧逐像素相同。
        if frameRects.count > 1 {
            let first = image.crop(frameRects[0])
            if frameRects.dropFirst().allSatisfy({ image.crop($0) == first }) {
                failed.insert(.identicalFrames)
            }
        }

        // 平铺边缘（R6.7）。
        if case .tile(let tiling) = rules.alignment, !tileEdgesMatch(image, tiling: tiling) {
            failed.insert(.tileEdge)
        }

        return verdict(failed, emptyFrames: emptyFrames)
    }

    // MARK: - 私有

    private static func verdict(_ failed: Set<ValidationRule>, emptyFrames: [Int]) -> AssetVerdict {
        if failed.isEmpty { return .pass }
        let ordered = ValidationRule.allCases.filter { failed.contains($0) }
        return .fail(ordered, emptyFrames: failed.contains(.emptyFrame) ? emptyFrames : [])
    }

    /// 帧四个角上各 `cornerSize`×`cornerSize` 的区域全部 alpha = 0（Transparent_Pixel）。
    private static func cornersTransparent(_ image: RGBAImage, in frame: PixelRect) -> Bool {
        let w = min(cornerSize, frame.width), h = min(cornerSize, frame.height)
        let corners = [
            PixelRect(x: frame.minX, y: frame.minY, width: w, height: h),
            PixelRect(x: frame.maxX - w, y: frame.minY, width: w, height: h),
            PixelRect(x: frame.minX, y: frame.maxY - h, width: w, height: h),
            PixelRect(x: frame.maxX - w, y: frame.maxY - h, width: w, height: h),
        ]
        for corner in corners {
            for y in corner.minY..<corner.maxY {
                for x in corner.minX..<corner.maxX where image.alpha(x: x, y: y) != 0 {
                    return false
                }
            }
        }
        return true
    }

    /// `plank`（水平平铺）比较最左列与最右列；`ladder`（竖直平铺）比较最上行与最下行。
    private static func tileEdgesMatch(_ image: RGBAImage, tiling: AssetTiling) -> Bool {
        switch tiling {
        case .none:
            return true
        case .horizontal:
            let right = image.width - 1
            return (0..<image.height).allSatisfy { y in
                seamPixelsMatch(image[0, y], image[right, y])
            }
        case .vertical:
            let bottom = image.height - 1
            return (0..<image.width).allSatisfy { x in
                seamPixelsMatch(image[x, 0], image[x, bottom])
            }
        }
    }

    private static func seamPixelsMatch(_ p: RGBA, _ q: RGBA) -> Bool {
        func diff(_ a: UInt8, _ b: UInt8) -> Int { abs(Int(a) - Int(b)) }
        return diff(p.a, q.a) <= tileAlphaTolerance
            && diff(p.r, q.r) <= tileColorTolerance
            && diff(p.g, q.g) <= tileColorTolerance
            && diff(p.b, q.b) <= tileColorTolerance
    }
}
