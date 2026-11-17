import PropertyBased
import WindowfolkArtKit
import WindowfolkCore

// 合成原始图生成器（design.md「生成器约定」中的 `Gen.rawImage(key)`，任务 6.2）。
//
// 供后处理、去背景、校验等图像属性测试共用（任务 6.4、6.6 至 6.12、7.2、7.3、8.4）。
//
// 每张图的形状：
// - 横向 N 个等宽帧格（N = 该键的帧数），每格宽 `cellWidth`，整体宽 `cellWidth × N`、高 `height`，
//   每格 ≤ 96×96 像素；整体尺寸保证不等于该键的 Expected_Pixel_Size，处理时走去背景和缩放分支。
// - 背景为完全透明 `(0,0,0,0)` 或不透明纯色。
// - 每格画一个实心圆角矩形（alpha 255），与帧格四边至少留 1 像素背景，因此四角和帧格边缘都是背景，
//   图形彼此不相连。图形颜色与不透明背景色至少一个通道相差 > 24。
// - 多帧时各帧图形宽度两两相差至少 2 像素，缩放后各帧仍不相同（避免 Grounded 居民贴底居中后
//   各帧逐像素相同而触发「帧内容相同」）。高度、位置、圆角半径、颜色各帧独立随机。
//
// 用法：
// ```swift
// await propertyCheck(count: 100, input: Gen<RawImageSample>.rawImage("resident_a_walking")) { sample in
//     let result = PostProcessor.process(sample.image, key: sample.key, resampler: NearestResampler())
//     ...
// }
// // 在多个键中随机：
// await propertyCheck(count: 100, input: Gen<RawImageSample>.rawImage(among: AssetCatalog.all.map(\.key))) { ... }
// ```
// 需要「清空一帧」时用 `sample.clearingFrame(i)`；判断某像素是否属于图形用 `sample.isShapePixel(x:y:)`。

/// 合成图中一帧的实心圆角矩形。
struct RawShape: Hashable, Sendable {
    /// 所在帧序号，从 0 开始。
    var frame: Int
    /// 图形外接矩形，整幅图像坐标；也是该图形的不透明边界框。
    var rect: PixelRect
    /// 圆角半径，`0 ≤ cornerRadius ≤ (min(宽, 高) − 1) / 2`。
    var cornerRadius: Int
    /// 填充色，alpha 恒为 255。
    var color: RGBA

    /// 整幅图像坐标 `(x, y)` 是否落在圆角矩形内。
    func contains(x: Int, y: Int) -> Bool {
        guard x >= rect.minX, x < rect.maxX, y >= rect.minY, y < rect.maxY else { return false }
        let r = cornerRadius
        let cx = min(max(x, rect.minX + r), rect.maxX - 1 - r)
        let cy = min(max(y, rect.minY + r), rect.maxY - 1 - r)
        let dx = x - cx, dy = y - cy
        return dx * dx + dy * dy <= r * r
    }
}

/// `Gen.rawImage` 生成的一张合成原始图及其构成信息。
struct RawImageSample: Hashable, Sendable, CustomStringConvertible {
    /// Asset_Key。
    var key: String
    /// 合成的 RGBA 原始图。
    var image: RGBAImage
    /// 背景像素：透明背景为 `RGBA.clear`，否则为不透明纯色。
    var background: RGBA
    /// 每帧一个图形，按帧序排列，`shapes[i].frame == i`。
    var shapes: [RawShape]
    /// 每个帧格的像素宽度；整幅宽度 = `cellWidth × frames`。
    var cellWidth: Int

    var frames: Int { shapes.count }
    var isTransparentBackground: Bool { background.a == 0 }

    /// 第 `index` 帧（从 0 开始）帧格的矩形。
    func cellRect(_ index: Int) -> PixelRect {
        PixelRect(x: index * cellWidth, y: 0, width: cellWidth, height: image.height)
    }

    /// 整幅图像坐标 `(x, y)` 是否属于某个图形；否则是背景像素。
    func isShapePixel(x: Int, y: Int) -> Bool {
        let i = x / cellWidth
        return i >= 0 && i < shapes.count && shapes[i].contains(x: x, y: y)
    }

    /// 把第 `index` 帧（从 0 开始）整格涂成背景后的图像：去背景后该帧没有任何不透明像素。
    func clearingFrame(_ index: Int) -> RGBAImage {
        let cell = cellRect(index)
        return image.pasting(RGBAImage(width: cell.width, height: cell.height, fill: background),
                             at: PixelPoint(x: cell.minX, y: cell.minY))
    }

    var description: String {
        let bg = isTransparentBackground ? "透明" : "(\(background.r),\(background.g),\(background.b))"
        let parts = shapes.map { s in
            "#\(s.frame)[\(s.rect.x),\(s.rect.y) \(s.rect.width)×\(s.rect.height) r\(s.cornerRadius)]"
        }
        return "\(key) \(image.width)×\(image.height) cell=\(cellWidth) 背景=\(bg) " + parts.joined(separator: " ")
    }
}

// MARK: - 构造

extension RawImageSample {
    /// 每个帧格的最大边长（design.md「属性测试」：每帧 ≤ 96×96）。
    static let maxCellSide = 96
    /// 帧格最小边长。
    static let minCellSide = 8
    /// 图形最小边长。
    static let minShapeSide = 3
    /// 多帧时相邻图形宽度的步长；缩放比例 ≥ 0.5 时缩放后宽度仍两两不同。
    static let widthStep = 2
    /// 每帧消耗的随机数个数：排序键、高、x、y、半径、颜色。
    static let entropyPerFrame = 6
    static let entropyHeader = 6
    /// Asset_Catalog 中最大的帧数。
    static let maxFrames = AssetCatalog.all.map(\.frames).max() ?? 1
    static let entropyCount = entropyHeader + entropyPerFrame * maxFrames
    static let entropyRange = 0...0xFF_FFFF

    /// 用一组随机整数确定地构造合成图。`keys` 非空且都在 Asset_Catalog 中。
    static func build(keys: [String], entropy: [Int]) -> RawImageSample {
        var e = entropy
        if e.count < entropyCount { e += Array(repeating: 0, count: entropyCount - e.count) }
        func pick(_ v: Int, _ range: ClosedRange<Int>) -> Int {
            range.lowerBound + abs(v) % (range.upperBound - range.lowerBound + 1)
        }

        let key = keys[pick(e[0], 0...(keys.count - 1))]
        guard let spec = AssetCatalog.spec(key) else { preconditionFailure("未知 Asset_Key：\(key)") }
        let n = spec.frames

        let transparent = pick(e[1], 0...2) == 0
        let bgRGB = e[2]
        let background = transparent ? RGBA.clear
            : RGBA(r: UInt8(truncatingIfNeeded: bgRGB >> 16), g: UInt8(truncatingIfNeeded: bgRGB >> 8),
                   b: UInt8(truncatingIfNeeded: bgRGB), a: 255)

        // 宽度需容纳 n 个两两相差 widthStep 的图形，两侧各留 1 像素。
        let minCell = max(minCellSide, minShapeSide + widthStep * (n - 1) + 2)
        let cellWidth = pick(e[3], minCell...maxCellSide)
        var height = pick(e[4], minCellSide...maxCellSide)
        if cellWidth * n == spec.expectedPixelWidth && height == spec.expectedPixelHeight {
            height -= 1  // Expected 高度 ≥ 12，减 1 后仍 ≥ minCellSide。
        }
        let wMin = pick(e[5], minShapeSide...(cellWidth - 2 - widthStep * (n - 1)))

        // 由排序键得到 0..<n 的排列，决定各帧宽度的名次。
        let frameEntropy = (0..<n).map { i in Array(e[(entropyHeader + i * entropyPerFrame)...].prefix(entropyPerFrame)) }
        let order = (0..<n).sorted { (frameEntropy[$0][0], $0) < (frameEntropy[$1][0], $1) }
        var rank = [Int](repeating: 0, count: n)
        for (r, i) in order.enumerated() { rank[i] = r }

        var image = RGBAImage(width: cellWidth * n, height: height, fill: background)
        var shapes: [RawShape] = []
        for i in 0..<n {
            let fe = frameEntropy[i]
            let w = wMin + widthStep * rank[i]
            let h = pick(fe[1], minShapeSide...(height - 2))
            let x = i * cellWidth + pick(fe[2], 1...(cellWidth - 1 - w))
            let y = pick(fe[3], 1...(height - 1 - h))
            let radius = pick(fe[4], 0...((min(w, h) - 1) / 2))
            var color = RGBA(r: UInt8(truncatingIfNeeded: fe[5] >> 16), g: UInt8(truncatingIfNeeded: fe[5] >> 8),
                             b: UInt8(truncatingIfNeeded: fe[5]), a: 255)
            if !transparent && !differsEnough(color, background) {
                color.r &+= 128  // 与背景的 R 通道差变为 ≥ 104。
            }
            let shape = RawShape(frame: i, rect: PixelRect(x: x, y: y, width: w, height: h),
                                 cornerRadius: radius, color: color)
            for py in y..<(y + h) {
                for px in x..<(x + w) where shape.contains(x: px, y: py) {
                    image[px, py] = color
                }
            }
            shapes.append(shape)
        }
        return RawImageSample(key: key, image: image, background: background, shapes: shapes, cellWidth: cellWidth)
    }

    /// 至少一个 RGB 通道相差 > 24。
    static func differsEnough(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(Int(a.r) - Int(b.r)) > 24 || abs(Int(a.g) - Int(b.g)) > 24 || abs(Int(a.b) - Int(b.b)) > 24
    }
}

// MARK: - 生成器

extension Gen where Value == RawImageSample {
    /// 指定 Asset_Key 的合成原始图。键必须在 Asset_Catalog 中。
    static func rawImage(_ key: String) -> Generator<RawImageSample, some SendableSequenceType> {
        rawImage(among: [key])
    }

    /// 在 `keys` 中随机选一个键并生成它的合成原始图。`keys` 非空且都在 Asset_Catalog 中。
    static func rawImage(among keys: [String]) -> Generator<RawImageSample, some SendableSequenceType> {
        precondition(!keys.isEmpty, "keys 不能为空")
        return Gen<Int>.int(in: RawImageSample.entropyRange)
            .array(of: RawImageSample.entropyCount)
            .map { RawImageSample.build(keys: keys, entropy: $0) }
    }
}
