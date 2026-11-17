import Foundation
import WindowfolkCore

// MARK: - 像素与几何

/// 单个非预乘 RGBA 像素，每通道 8 位。
public struct RGBA: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// 完全透明像素 `(0,0,0,0)`。
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
}

/// 像素坐标，原点在左上角，y 向下。
public struct PixelPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// 像素矩形，原点在左上角，覆盖列 `[x, x + width)`、行 `[y, y + height)`。
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Int { x }
    public var minY: Int { y }
    /// 右边界（不含）。
    public var maxX: Int { x + width }
    /// 下边界（不含）。
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// 包含两个矩形的最小矩形；空矩形不参与合并。
    public func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX), y1 = max(maxY, other.maxY)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 两个矩形的交集；不相交时返回 nil。
    public func intersection(_ other: PixelRect) -> PixelRect? {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 平移后的矩形。
    public func offsetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}

// MARK: - RGBA 缓冲区

/// 行优先、从上到下的非预乘 RGBA 缓冲区，每像素 4 字节（R、G、B、A）。
public struct RGBAImage: Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// 长度恒为 `width * height * 4`。
    public var pixels: [UInt8]

    /// 用同一像素填满的图像，默认全透明。
    public init(width: Int, height: Int, fill: RGBA = .clear) {
        precondition(width >= 0 && height >= 0, "图像尺寸不能为负")
        self.width = width
        self.height = height
        let count = width * height
        var buffer = [UInt8](repeating: 0, count: count * 4)
        if fill != .clear {
            for i in 0..<count {
                buffer[i * 4] = fill.r
                buffer[i * 4 + 1] = fill.g
                buffer[i * 4 + 2] = fill.b
                buffer[i * 4 + 3] = fill.a
            }
        }
        self.pixels = buffer
    }

    /// 用现成的字节缓冲区构造；长度必须等于 `width * height * 4`。
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0, "图像尺寸不能为负")
        precondition(pixels.count == width * height * 4, "像素缓冲区长度与尺寸不符")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// 整幅图像的矩形 `(0, 0, width, height)`。
    public var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    public subscript(x: Int, y: Int) -> RGBA {
        get {
            precondition(contains(x: x, y: y), "像素坐标越界")
            let i = (y * width + x) * 4
            return RGBA(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
        }
        set {
            precondition(contains(x: x, y: y), "像素坐标越界")
            let i = (y * width + x) * 4
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = newValue.a
        }
    }

    /// 坐标 `(x, y)` 处的 alpha。
    public func alpha(x: Int, y: Int) -> UInt8 {
        precondition(contains(x: x, y: y), "像素坐标越界")
        return pixels[(y * width + x) * 4 + 3]
    }

    /// 裁出矩形 `r` 与图像相交的部分；不相交时返回 0×0 图像。
    public func crop(_ r: PixelRect) -> RGBAImage {
        guard let clip = r.intersection(bounds) else { return RGBAImage(width: 0, height: 0) }
        var out = [UInt8]()
        out.reserveCapacity(clip.width * clip.height * 4)
        let rowBytes = clip.width * 4
        for y in clip.minY..<clip.maxY {
            let start = (y * width + clip.minX) * 4
            out.append(contentsOf: pixels[start..<(start + rowBytes)])
        }
        return RGBAImage(width: clip.width, height: clip.height, pixels: out)
    }

    /// alpha ≥ `threshold` 的像素的最小外接矩形；没有这样的像素时返回 nil。
    public func opaqueBounds(threshold: UInt8 = 128) -> PixelRect? {
        opaqueBounds(in: bounds, threshold: threshold)
    }

    /// 只在 `region`（与图像求交）内统计的不透明边界框，坐标仍是整幅图像坐标。
    public func opaqueBounds(in region: PixelRect, threshold: UInt8 = 128) -> PixelRect? {
        guard let clip = region.intersection(bounds) else { return nil }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in clip.minY..<clip.maxY {
            let rowStart = y * width
            for x in clip.minX..<clip.maxX where pixels[(rowStart + x) * 4 + 3] >= threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard minX <= maxX else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 把 `source` 的全部像素（含透明像素）覆盖写到本图 `origin` 处，超出边界的部分丢弃。
    public mutating func paste(_ source: RGBAImage, at origin: PixelPoint) {
        let target = PixelRect(x: origin.x, y: origin.y, width: source.width, height: source.height)
        guard let clip = target.intersection(bounds) else { return }
        let rowBytes = clip.width * 4
        for y in clip.minY..<clip.maxY {
            let srcStart = ((y - origin.y) * source.width + (clip.minX - origin.x)) * 4
            let dstStart = (y * width + clip.minX) * 4
            pixels.replaceSubrange(dstStart..<(dstStart + rowBytes),
                                   with: source.pixels[srcStart..<(srcStart + rowBytes)])
        }
    }

    /// 返回粘贴后的新图像，语义同 `paste(_:at:)`。
    public func pasting(_ source: RGBAImage, at origin: PixelPoint) -> RGBAImage {
        var copy = self
        copy.paste(source, at: origin)
        return copy
    }

    /// 整幅内容平移 `(dx, dy)` 像素，尺寸不变；移出的像素丢弃，空出的位置为透明。不做重采样。
    public func translated(dx: Int, dy: Int) -> RGBAImage {
        if dx == 0 && dy == 0 { return self }
        var out = RGBAImage(width: width, height: height)
        out.paste(self, at: PixelPoint(x: dx, y: dy))
        return out
    }

    /// 只平移矩形 `region` 内的内容 `(dx, dy)`：先把 `region` 清为透明，
    /// 再把原内容写到平移后位置，写入结果裁剪到 `region` 内。用于在拼接图中逐帧平移。
    public mutating func translate(region: PixelRect, dx: Int, dy: Int) {
        guard let clip = region.intersection(bounds), dx != 0 || dy != 0 else { return }
        let content = crop(clip)
        paste(RGBAImage(width: clip.width, height: clip.height), at: PixelPoint(x: clip.minX, y: clip.minY))
        let moved = content.translated(dx: dx, dy: dy)
        paste(moved, at: PixelPoint(x: clip.minX, y: clip.minY))
    }
}

// MARK: - 重采样

public protocol Resampler: Sendable {
    /// 高质量缩放；输入输出都是非预乘 RGBA。
    func resize(_ image: RGBAImage, to size: PixelSize) -> RGBAImage
}

// MARK: - 切帧

/// 横向等宽切帧（R4.2）：`q = W / N`（整除），第 i 帧占列 `[i·q, (i+1)·q)`，最后一帧到 `W` 为止。
public enum FrameSlicer {
    /// 各帧的列区间。要求 `frames ≥ 1` 且 `width ≥ frames`。
    public static func columnRanges(width: Int, frames: Int) -> [Range<Int>] {
        precondition(frames >= 1, "帧数至少为 1")
        precondition(width >= frames, "图像宽度不能小于帧数")
        let q = width / frames
        return (0..<frames).map { i in
            let start = i * q
            let end = i == frames - 1 ? width : start + q
            return start..<end
        }
    }

    /// 各帧在整幅图像中的矩形，高度为整幅高度。
    public static func frameRects(width: Int, height: Int, frames: Int) -> [PixelRect] {
        columnRanges(width: width, frames: frames).map {
            PixelRect(x: $0.lowerBound, y: 0, width: $0.count, height: height)
        }
    }

    /// 把图像切成 `frames` 帧。
    public static func slice(_ image: RGBAImage, frames: Int) -> [RGBAImage] {
        frameRects(width: image.width, height: image.height, frames: frames).map { image.crop($0) }
    }
}
