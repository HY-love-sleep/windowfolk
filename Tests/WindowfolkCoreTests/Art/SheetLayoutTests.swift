import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// Character_Sheet 布局（`SheetLayout.compose`，R1.1、R1.5）的属性测试（任务 8.4）。
@Suite struct SheetLayoutTests {

    // Feature: 美术, Property 23: 设定图色块与视图
    // **Validates: Requirements 1.1, 1.5**
    @Test func swatchesMatchPaletteAndViewsFillTheirCells() async {
        await propertyCheck(count: 100, input: Gen<SheetSample>.sheetSample) { sample in
            let sheet = SheetLayout.compose(views: sample.views.map(\.image), palette: sample.palette,
                                            resampler: FastNearest())
            #expect(sheet.width == 1536 && sheet.height == 720)

            // 色块：≥ 32×32，整块（含中心像素）RGB 等于 Palette 第 i 色、alpha 255。
            var swatchRects: [PixelRect] = []
            for (i, color) in sample.palette.enumerated() {
                let rect = SheetLayout.swatchRect(i)
                swatchRects.append(rect)
                #expect(rect.width >= 32 && rect.height >= 32, "色块 \(i) 小于 32×32：\(rect)")
                #expect(rect.minX >= 0 && rect.maxX <= sheet.width && rect.minY >= 0 && rect.maxY <= sheet.height)
                let center = sheet[rect.x + rect.width / 2, rect.y + rect.height / 2]
                #expect(center == RGBA(r: color.r, g: color.g, b: color.b, a: 255),
                        "色块 \(i) 中心像素 \(center) ≠ Palette \(color)")
                let expected = RGBA(r: color.r, g: color.g, b: color.b, a: 255)
                var allMatch = true
                for y in rect.minY..<rect.maxY {
                    for x in rect.minX..<rect.maxX where sheet[x, y] != expected { allMatch = false }
                }
                #expect(allMatch, "色块 \(i) 不是纯色 \(color)")
            }

            // 视图：每个不透明像素的 b 通道标记它来自哪个视图。视图行（y < 640）里的不透明像素
            // 必须带所在格的标记；色块行里的不透明像素必须落在某个色块内。直接读缓冲区以控制耗时。
            var viewBounds: [PixelRect?] = Array(repeating: nil, count: 3)
            var misplaced = 0
            var strayBelow = 0
            let cellWidth = SheetLayout.viewCell.width
            let rowSplit = SheetLayout.viewCell.height
            sheet.pixels.withUnsafeBytes { buf in
                var minX = [Int](repeating: .max, count: 3), maxX = [Int](repeating: .min, count: 3)
                var minY = [Int](repeating: .max, count: 3), maxY = [Int](repeating: .min, count: 3)
                for y in 0..<sheet.height {
                    let row = y * sheet.width * 4
                    for x in 0..<sheet.width where buf[row + x * 4 + 3] >= 128 {
                        if y >= rowSplit {
                            let inSwatch = swatchRects.contains {
                                x >= $0.minX && x < $0.maxX && y >= $0.minY && y < $0.maxY
                            }
                            if !inSwatch { strayBelow += 1 }
                            continue
                        }
                        let cell = x / cellWidth
                        guard Int(buf[row + x * 4 + 2]) == cell else { misplaced += 1; continue }
                        minX[cell] = min(minX[cell], x); maxX[cell] = max(maxX[cell], x)
                        minY[cell] = min(minY[cell], y); maxY[cell] = max(maxY[cell], y)
                    }
                }
                for i in 0..<3 where minX[i] <= maxX[i] {
                    viewBounds[i] = PixelRect(x: minX[i], y: minY[i],
                                              width: maxX[i] - minX[i] + 1, height: maxY[i] - minY[i] + 1)
                }
            }
            #expect(misplaced == 0, "\(misplaced) 个视图像素落在自己的格外")
            #expect(strayBelow == 0, "\(strayBelow) 个视图像素写进了色块行")

            for (i, view) in sample.views.enumerated() {
                let cell = SheetLayout.viewCellRect(i)
                if view.isEmpty {
                    #expect(viewBounds[i] == nil, "空视图 \(i) 的格内出现了不透明像素")
                    #expect(sheet.opaqueBounds(in: cell) == nil, "空视图 \(i) 的格应留空")
                    continue
                }
                guard let b = viewBounds[i] else {
                    Issue.record("视图 \(i) 没有出现在格内")
                    continue
                }
                #expect(b.minX >= cell.minX && b.maxX <= cell.maxX && b.minY >= cell.minY && b.maxY <= cell.maxY,
                        "视图 \(i) 边界框 \(b) 超出视图格 \(cell)")
                #expect(b.height >= SheetLayout.viewMinHeight, "视图 \(i) 高度 \(b.height) < 256")
            }
            // 从左到右：非空视图的边界框按序号依次右移且互不重叠。
            let placed = viewBounds.compactMap { $0 }
            for (a, c) in zip(placed, placed.dropFirst()) {
                #expect(a.maxX <= c.minX, "视图边界框没有从左到右排列：\(a) \(c)")
            }
        }
    }
}

// MARK: - 生成器

/// 一张合成视图：透明背景上一个实心矩形（含少量随机内部色点），不透明边界框宽高比 ≤ 2。
/// 所有不透明像素的 b 通道等于视图序号，用来在合成结果里识别像素来自哪个视图。
fileprivate struct SheetView: Hashable, Sendable {
    var image: RGBAImage
    /// 图形矩形；空视图为 nil。
    var shape: PixelRect?
    var isEmpty: Bool { shape == nil }
}

fileprivate struct SheetSample: Hashable, Sendable, CustomStringConvertible {
    var views: [SheetView]
    var palette: [RGB]

    var description: String {
        let v = views.map { view in
            "\(view.image.width)×\(view.image.height) shape=\(view.shape.map { "\($0)" } ?? "空")"
        }
        let p = palette.map { "(\($0.r),\($0.g),\($0.b))" }
        return "SheetSample(views: \(v), palette: \(p))"
    }
}

/// SplitMix64：从一个种子确定地派生出一组参数。
fileprivate struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

fileprivate extension SheetView {
    static func build(index: Int, rng: inout SplitMix) -> SheetView {
        let marker = UInt8(index)
        // 约 1/10 为空视图：全透明，或只有 alpha < 128 的像素。
        if Int.random(in: 0..<10, using: &rng) == 0 {
            let w = Int.random(in: 1...96, using: &rng), h = Int.random(in: 1...96, using: &rng)
            let faint = RGBA(r: 10, g: 10, b: marker, a: UInt8.random(in: 0...127, using: &rng))
            return SheetView(image: RGBAImage(width: w, height: h, fill: faint), shape: nil)
        }
        // 图形：高 1…90，宽 1…min(2·高, 90)，即宽高比 ≤ 2。
        let sh = Int.random(in: 1...90, using: &rng)
        let sw = Int.random(in: 1...min(2 * sh, 90), using: &rng)
        let left = Int.random(in: 0...(96 - sw), using: &rng)
        let top = Int.random(in: 0...(96 - sh), using: &rng)
        let right = Int.random(in: 0...(96 - sw - left), using: &rng)
        let bottom = Int.random(in: 0...(96 - sh - top), using: &rng)
        let width = left + sw + right, height = top + sh + bottom
        var image = RGBAImage(width: width, height: height)
        let fill = RGBA(r: UInt8.random(in: 0...255, using: &rng), g: UInt8.random(in: 0...255, using: &rng),
                        b: marker, a: 255)
        for y in top..<(top + sh) {
            for x in left..<(left + sw) { image[x, y] = fill }
        }
        // 内部随机色点（仍不透明、带同一标记）。
        for _ in 0..<Int.random(in: 0...20, using: &rng) {
            let x = Int.random(in: left..<(left + sw), using: &rng)
            let y = Int.random(in: top..<(top + sh), using: &rng)
            image[x, y] = RGBA(r: UInt8.random(in: 0...255, using: &rng), g: UInt8.random(in: 0...255, using: &rng),
                               b: marker, a: UInt8.random(in: 128...255, using: &rng))
        }
        // 图形外的半透明像素（alpha < 128），不计入边界框。
        if width * height > sw * sh {
            for _ in 0..<Int.random(in: 0...10, using: &rng) {
                let x = Int.random(in: 0..<width, using: &rng), y = Int.random(in: 0..<height, using: &rng)
                if x >= left, x < left + sw, y >= top, y < top + sh { continue }
                image[x, y] = RGBA(r: 50, g: 50, b: marker, a: UInt8.random(in: 1...127, using: &rng))
            }
        }
        return SheetView(image: image, shape: PixelRect(x: left, y: top, width: sw, height: sh))
    }
}

fileprivate extension Gen where Value == SheetSample {
    static var sheetSample: Generator<SheetSample, some SendableSequenceType> {
        Gen<UInt64>.uint64().map { seed in
            var rng = SplitMix(state: seed)
            let views = (0..<3).map { SheetView.build(index: $0, rng: &rng) }
            let palette = (0..<5).map { _ in
                RGB(r: UInt8.random(in: 0...255, using: &rng), g: UInt8.random(in: 0...255, using: &rng),
                    b: UInt8.random(in: 0...255, using: &rng))
            }
            return SheetSample(views: views, palette: palette)
        }
    }
}

// MARK: - 缩放

/// 与 `NearestResampler` 取样规则相同的最近邻缩放，按 32 位整像素拷贝。
/// debug 构建下 `NearestResampler` 逐像素走带边界检查的下标，100 次迭代太慢。
fileprivate struct FastNearest: Resampler {
    func resize(_ image: RGBAImage, to size: PixelSize) -> RGBAImage {
        let dw = max(0, size.width), dh = max(0, size.height)
        guard image.width > 0, image.height > 0, dw > 0, dh > 0 else { return RGBAImage(width: dw, height: dh) }
        let sw = image.width, shh = image.height
        let sx = (0..<dw).map { x in min(sw - 1, (2 * x + 1) * sw / (2 * dw)) }
        var out = [UInt8](repeating: 0, count: dw * dh * 4)
        image.pixels.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for y in 0..<dh {
                    let srcRow = min(shh - 1, (2 * y + 1) * shh / (2 * dh)) * sw
                    let dstRow = y * dw
                    for x in 0..<dw {
                        let px = src.loadUnaligned(fromByteOffset: (srcRow + sx[x]) * 4, as: UInt32.self)
                        dst.storeBytes(of: px, toByteOffset: (dstRow + x) * 4, as: UInt32.self)
                    }
                }
            }
        }
        return RGBAImage(width: dw, height: dh, pixels: out)
    }
}
