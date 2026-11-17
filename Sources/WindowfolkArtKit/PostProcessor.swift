import Foundation
import WindowfolkCore

// 后处理（design.md「后处理算法」第 1 至 10 步，Requirement 4）。
//
// 纯函数：输入 Raw_Candidate 的 RGBA 缓冲区，输出符合 Expected_Pixel_Size 的拼接图。
// 高质量缩放通过注入的 `Resampler` 完成（IO 层用 CoreGraphics 实现），本文件不做插值。

/// 后处理的外部输入。
public struct ProcessContext: Hashable, Sendable {
    /// `Assets/` 中该居民 idle Final_Asset 第 1 帧不透明边界框的高度（R4.7）；没有时为 nil。
    /// 只对 Grounded_State 居民素材生效。
    public var idleReferenceHeight: Int?

    public init(idleReferenceHeight: Int? = nil) {
        self.idleReferenceHeight = idleReferenceHeight
    }
}

/// 处理成功的结果。
public struct ProcessOutcome: Hashable, Sendable {
    /// 尺寸等于 Expected_Pixel_Size 的拼接图。
    public var image: RGBAImage
    /// 不影响成功判定的提示，例如 R4.7 中缩放后仍与 idle 高度相差超过 10% 的帧。
    public var warnings: [String]

    public init(image: RGBAImage, warnings: [String] = []) {
        self.image = image
        self.warnings = warnings
    }
}

/// 处理失败的原因（R4.12）。Asset_Key 和文件路径由调用方一并输出。
public enum PostProcessError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Asset_Key 不在 Asset_Catalog 中。
    case unknownKey(String)
    /// 第 `index` 帧（从 1 开始）没有任何 Opaque_Pixel。
    case emptyFrame(index: Int)
    /// 平铺边缘不满足阈值；附带说明（素材键与出错的行或列）。
    case tileSeam(String)

    public var description: String {
        switch self {
        case .unknownKey(let key):
            return "未知的 Asset_Key：\(key)"
        case .emptyFrame(let index):
            return "第 \(index) 帧没有不透明像素"
        case .tileSeam(let detail):
            return "平铺边缘不满足阈值：\(detail)"
        }
    }
}

public enum PostProcessor {
    /// 贴底：最下方不透明行距帧底边的最大距离（R4.5、R4.8、R4.9、R4.15）。
    public static let bottomTolerance = 2
    /// 居中：锚点水平中心与帧中心的最大偏差（R4.5、R4.8、R4.9、R4.15）。
    public static let centerTolerance = 1
    /// 花盆、灯座锚点取最下方的不透明行数（R4.8、R4.9）。
    public static let anchorRows = 4
    /// Framed_Asset 每帧四角清理的正方形边长（R4.14）。
    public static let cornerSize = 2
    /// R4.7：缩放后各帧高度与 idle 参考高度的允许相对差。
    public static let idleHeightTolerance = 0.10

    /// 按 design.md「后处理算法」处理一张原始图。
    public static func process(_ raw: RGBAImage, key: String, context: ProcessContext = ProcessContext(),
                               resampler: any Resampler) -> Result<ProcessOutcome, PostProcessError> {
        // 第 1 步：查规则。
        guard let rules = AssetRules.rules(for: key) else { return .failure(.unknownKey(key)) }
        let spec = rules.spec
        let geometry = FrameGeometry(frames: spec.frames,
                                     width: spec.expectedPixelWidth / spec.frames,
                                     height: spec.expectedPixelHeight)

        // 宽度不足帧数或高度为 0 时，至少有一帧没有任何像素。
        guard raw.height > 0, raw.width >= geometry.frames else {
            return .failure(.emptyFrame(index: raw.height == 0 ? 1 : raw.width + 1))
        }

        // 第 2 至 7 步：得到 N 个 fw × fh 的帧。
        let placed: Result<(frames: [RGBAImage], warnings: [String]), PostProcessError>
        if raw.width == spec.expectedPixelWidth && raw.height == spec.expectedPixelHeight {
            placed = alignOnly(raw, rules: rules, geometry: geometry).map { ($0, []) }
        } else {
            placed = resampleAndPlace(raw, rules: rules, geometry: geometry,
                                      context: context, resampler: resampler)
        }
        var frames: [RGBAImage]
        var warnings: [String]
        switch placed {
        case .success(let result): (frames, warnings) = result
        case .failure(let error): return .failure(error)
        }

        // 第 8 步：Framed_Asset 四角清理（R4.14）。
        if rules.isFramed {
            frames = frames.map(clearCorners)
        }

        // 第 10 步：从左到右无间隔拼接（R4.2）。
        var output = RGBAImage(width: geometry.width * geometry.frames, height: geometry.height)
        for (i, frame) in frames.enumerated() {
            output.paste(frame, at: PixelPoint(x: i * geometry.width, y: 0))
        }

        // 第 9 步：平铺接缝（R4.10、R4.11）。拼接后整幅图只有 1 帧，等价于对帧处理。
        if case .tile(let tiling) = rules.alignment {
            averageSeam(&output, tiling: tiling)
            if let detail = seamViolation(output, tiling: tiling, key: key) {
                return .failure(.tileSeam(detail))
            }
        }

        warnings = warnings.map { "\(key)：\($0)" }
        return .success(ProcessOutcome(image: output, warnings: warnings))
    }

    // MARK: - 几何

    private struct FrameGeometry {
        var frames: Int
        /// 每帧目标像素宽 `fw`。
        var width: Int
        /// 每帧目标像素高 `fh`。
        var height: Int
    }

    /// 竖直方向的放置规则。
    private enum VerticalPlacement {
        /// 最下方不透明行放在 `fh − 1`。
        case bottom
        /// 竖直居中（平铺素材）。
        case center
    }

    private static func verticalPlacement(_ alignment: AlignmentMode) -> VerticalPlacement {
        if case .tile = alignment { return .center }
        return .bottom
    }

    /// 帧内（或缩放后小图内）内容 `bounds` 的水平锚点：`anchoredBase` 用最下方 4 行，其余用整体边界框。
    private static func anchor(of image: RGBAImage, bounds: PixelRect, alignment: AlignmentMode) -> PixelRect {
        guard case .anchoredBase = alignment else { return bounds }
        let top = max(bounds.minY, bounds.maxY - anchorRows)
        let base = PixelRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
        return image.opaqueBounds(in: base) ?? bounds
    }

    /// 让锚点水平中心对齐 `fw / 2`、内容按竖直规则放置所需的平移量（取整误差 ≤ 0.5 像素）。
    private static func targetShift(content: PixelRect, anchor: PixelRect, geometry: FrameGeometry,
                                    vertical: VerticalPlacement) -> (dx: Int, dy: Int) {
        let dx = halfRounded(geometry.width - (anchor.minX + anchor.maxX))
        let dy: Int
        switch vertical {
        case .bottom: dy = geometry.height - content.maxY
        case .center: dy = halfRounded(geometry.height - (content.minY + content.maxY))
        }
        return (dx, dy)
    }

    /// 只修正不满足容差的方向；已贴底、已居中的方向平移量为 0（第 2 步）。
    private static func correctiveShift(content: PixelRect, anchor: PixelRect, geometry: FrameGeometry,
                                        vertical: VerticalPlacement) -> (dx: Int, dy: Int) {
        let target = targetShift(content: content, anchor: anchor, geometry: geometry, vertical: vertical)
        // 两倍坐标比较，避免半像素。
        let centeredX = abs(geometry.width - (anchor.minX + anchor.maxX)) <= 2 * centerTolerance
        let alignedY: Bool
        switch vertical {
        case .bottom:
            let gap = geometry.height - content.maxY
            alignedY = gap >= 0 && gap <= bottomTolerance
        case .center:
            alignedY = abs(geometry.height - (content.minY + content.maxY)) <= 2 * centerTolerance
        }
        return (centeredX ? 0 : target.dx, alignedY ? 0 : target.dy)
    }

    /// `v / 2` 四舍五入（远离 0）。
    private static func halfRounded(_ v: Int) -> Int {
        Int((Double(v) / 2).rounded(.toNearestOrAwayFromZero))
    }

    /// 缩放后的边长：四舍五入，限制在 `1...limit`。
    private static func scaledLength(_ length: Int, _ scale: Double, limit: Int) -> Int {
        min(limit, max(1, Int((Double(length) * scale).rounded())))
    }

    // MARK: - 第 2 步：已是规格尺寸的输入，只平移

    private static func alignOnly(_ raw: RGBAImage, rules: AssetRules,
                                  geometry: FrameGeometry) -> Result<[RGBAImage], PostProcessError> {
        var frames = FrameSlicer.slice(raw, frames: geometry.frames)
        var boxes: [PixelRect] = []
        for (i, frame) in frames.enumerated() {
            guard let box = frame.opaqueBounds() else { return .failure(.emptyFrame(index: i + 1)) }
            boxes.append(box)
        }

        let vertical = verticalPlacement(rules.alignment)
        if case .nonGroundedUniform = rules.alignment {
            // R4.15：所有帧共用一个平移量，按帧并集判断。
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            let shift = correctiveShift(content: union, anchor: union, geometry: geometry, vertical: vertical)
            frames = frames.map { $0.translated(dx: shift.dx, dy: shift.dy) }
        } else {
            for i in frames.indices {
                let a = anchor(of: frames[i], bounds: boxes[i], alignment: rules.alignment)
                let shift = correctiveShift(content: boxes[i], anchor: a, geometry: geometry, vertical: vertical)
                frames[i] = frames[i].translated(dx: shift.dx, dy: shift.dy)
            }
        }
        return .success(frames)
    }

    // MARK: - 第 3 至 7 步：去背景、切帧、缩放、放置

    private static func resampleAndPlace(_ raw: RGBAImage, rules: AssetRules, geometry: FrameGeometry,
                                         context: ProcessContext, resampler: any Resampler)
        -> Result<(frames: [RGBAImage], warnings: [String]), PostProcessError> {
        // 第 3 步：去背景（R4.3）。
        let cleaned = BackgroundRemover.remove(raw)

        // 第 4、5 步：切帧并求每帧边界框（整幅图坐标）。
        let rects = FrameSlicer.frameRects(width: cleaned.width, height: cleaned.height,
                                           frames: geometry.frames)
        var boxes: [PixelRect] = []
        for (i, rect) in rects.enumerated() {
            guard let box = cleaned.opaqueBounds(in: rect) else { return .failure(.emptyFrame(index: i + 1)) }
            boxes.append(box)
        }

        let fw = Double(geometry.width), fh = Double(geometry.height)
        let vertical = verticalPlacement(rules.alignment)

        if case .nonGroundedUniform = rules.alignment {
            // 第 6 步：帧格坐标中的并集 U 放进一帧（R4.15）。
            let local = zip(boxes, rects).map { $0.offsetBy(dx: -$1.minX, dy: 0) }
            let union = local.dropFirst().reduce(local[0]) { $0.union($1) }
            let scale = min(fw / Double(union.width), fh / Double(union.height))
            let size = PixelSize(width: scaledLength(union.width, scale, limit: geometry.width),
                                 height: scaledLength(union.height, scale, limit: geometry.height))

            // 第 7 步：每帧裁同一矩形 U，缩放到同一尺寸，放在同一偏移处。
            var smalls: [RGBAImage] = []
            var smallUnion: PixelRect?
            for (i, rect) in rects.enumerated() {
                let small = resampler.resize(cleaned.crop(union.offsetBy(dx: rect.minX, dy: 0)), to: size)
                guard let box = small.opaqueBounds() else { return .failure(.emptyFrame(index: i + 1)) }
                smallUnion = smallUnion.map { $0.union(box) } ?? box
                smalls.append(small)
            }
            let content = smallUnion!
            let shift = targetShift(content: content, anchor: content, geometry: geometry, vertical: vertical)
            let frames = smalls.map {
                RGBAImage(width: geometry.width, height: geometry.height)
                    .pasting($0, at: PixelPoint(x: shift.dx, y: shift.dy))
            }
            return .success((frames, []))
        }

        // 第 6 步：所有帧共用的最大适配比例（R4.4、R4.6）。
        var scale = Double.infinity
        for box in boxes {
            var neededWidth = box.width
            if case .anchoredBase = rules.alignment {
                // 锚点居中后内容向两侧伸出的宽度不同；按较宽一侧的两倍适配，避免内容被裁出帧。
                let a = anchor(of: cleaned, bounds: box, alignment: rules.alignment)
                let center2 = a.minX + a.maxX
                neededWidth = max(box.width, center2 - 2 * box.minX, 2 * box.maxX - center2)
            }
            scale = min(scale, fw / Double(neededWidth), fh / Double(box.height))
        }

        // R4.7：Grounded 居民按 idle 参考高度调整，且不超过一般比例。
        var referenceHeight: Int?
        if rules.isGrounded, let h = context.idleReferenceHeight, h > 0 {
            referenceHeight = h
            let heights = boxes.map(\.height)
            let target = 2 * Double(h) / Double(heights.min()! + heights.max()!)
            scale = min(scale, target)
        }

        // 第 7 步：每帧裁出边界框、缩放、按小图自身的不透明边界框放置。
        var frames: [RGBAImage] = []
        var warnings: [String] = []
        for (i, box) in boxes.enumerated() {
            let size = PixelSize(width: scaledLength(box.width, scale, limit: geometry.width),
                                 height: scaledLength(box.height, scale, limit: geometry.height))
            let small = resampler.resize(cleaned.crop(box), to: size)
            guard let content = small.opaqueBounds() else { return .failure(.emptyFrame(index: i + 1)) }
            let a = anchor(of: small, bounds: content, alignment: rules.alignment)
            let shift = targetShift(content: content, anchor: a, geometry: geometry, vertical: vertical)
            frames.append(RGBAImage(width: geometry.width, height: geometry.height)
                .pasting(small, at: PixelPoint(x: shift.dx, y: shift.dy)))

            if let h = referenceHeight,
               Double(abs(content.height - h)) > idleHeightTolerance * Double(h) {
                warnings.append("第 \(i + 1) 帧不透明高度 \(content.height) 与 idle 参考高度 \(h) 相差超过 10%")
            }
        }
        return .success((frames, warnings))
    }

    // MARK: - 第 8 步：四角清理

    private static func clearCorners(_ frame: RGBAImage) -> RGBAImage {
        var out = frame
        let w = min(cornerSize, frame.width), h = min(cornerSize, frame.height)
        let origins = [
            (0, 0), (frame.width - w, 0),
            (0, frame.height - h), (frame.width - w, frame.height - h),
        ]
        for (ox, oy) in origins {
            for y in oy..<(oy + h) {
                for x in ox..<(ox + w) {
                    out[x, y] = .clear
                }
            }
        }
        return out
    }

    // MARK: - 第 9 步：平铺接缝

    /// `plank`：每行最左列与最右列都改为两者的逐通道平均；`ladder`：每列最上行与最下行。
    private static func averageSeam(_ image: inout RGBAImage, tiling: AssetTiling) {
        guard image.width > 0, image.height > 0 else { return }
        switch tiling {
        case .none:
            return
        case .horizontal:
            let right = image.width - 1
            for y in 0..<image.height {
                let m = average(image[0, y], image[right, y])
                image[0, y] = m
                image[right, y] = m
            }
        case .vertical:
            let bottom = image.height - 1
            for x in 0..<image.width {
                let m = average(image[x, 0], image[x, bottom])
                image[x, 0] = m
                image[x, bottom] = m
            }
        }
    }

    private static func average(_ p: RGBA, _ q: RGBA) -> RGBA {
        func avg(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Int(a) + Int(b) + 1) / 2) }
        return RGBA(r: avg(p.r, q.r), g: avg(p.g, q.g), b: avg(p.b, q.b), a: avg(p.a, q.a))
    }

    /// 复查接缝阈值（alpha ≤ 16，RGB ≤ 24）；全部满足时返回 nil，否则返回第一处违规的说明。
    private static func seamViolation(_ image: RGBAImage, tiling: AssetTiling, key: String) -> String? {
        guard image.width > 0, image.height > 0 else { return nil }
        func matches(_ p: RGBA, _ q: RGBA) -> Bool {
            func diff(_ a: UInt8, _ b: UInt8) -> Int { abs(Int(a) - Int(b)) }
            return diff(p.a, q.a) <= AssetValidator.tileAlphaTolerance
                && diff(p.r, q.r) <= AssetValidator.tileColorTolerance
                && diff(p.g, q.g) <= AssetValidator.tileColorTolerance
                && diff(p.b, q.b) <= AssetValidator.tileColorTolerance
        }
        switch tiling {
        case .none:
            return nil
        case .horizontal:
            let right = image.width - 1
            for y in 0..<image.height where !matches(image[0, y], image[right, y]) {
                return "\(key) 第 \(y + 1) 行最左列与最右列差值超出阈值"
            }
        case .vertical:
            let bottom = image.height - 1
            for x in 0..<image.width where !matches(image[x, 0], image[x, bottom]) {
                return "\(key) 第 \(x + 1) 列最上行与最下行差值超出阈值"
            }
        }
        return nil
    }
}
