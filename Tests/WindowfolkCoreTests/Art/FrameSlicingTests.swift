import Foundation
import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 切帧（R4.2）与图像测试支撑（`Gen.rawImage`、`NearestResampler`）的测试（任务 6.2）。
@Suite struct FrameSlicingTests {

    // Feature: 美术, Property 8: 切帧覆盖全宽且不重叠
    // **Validates: Requirements 4.2**
    @Test func slicesCoverFullWidthWithoutOverlap() async {
        let input = zip(Gen<Int>.int(in: 1...12), Gen<Int>.int(in: 0...4096))
        await propertyCheck(count: 200, input: input) { frames, extra in
            let width = frames + extra  // W ≥ N
            let ranges = FrameSlicer.columnRanges(width: width, frames: frames)
            let q = width / frames

            #expect(ranges.count == frames)
            #expect(ranges.first?.lowerBound == 0)
            #expect(ranges.last?.upperBound == width)
            for (a, b) in zip(ranges, ranges.dropFirst()) {
                #expect(a.upperBound == b.lowerBound, "相邻区间应首尾相接：\(a) \(b)")
            }
            for r in ranges.dropLast() {
                #expect(r.count == q, "前 N−1 段宽度应为 W / N")
            }
            #expect(ranges.last?.count == q + width % frames, "最后一段宽度应为 W / N + W % N")

            let rects = FrameSlicer.frameRects(width: width, height: 3, frames: frames)
            #expect(rects == ranges.map { PixelRect(x: $0.lowerBound, y: 0, width: $0.count, height: 3) })
        }
    }

    // MARK: - 切帧示例

    @Test func sliceSplitsImageAndLastFrameAbsorbsRemainder() {
        var image = RGBAImage(width: 11, height: 2)
        for x in 0..<11 {
            for y in 0..<2 { image[x, y] = RGBA(r: UInt8(x), g: UInt8(y), b: 0, a: 255) }
        }
        let frames = FrameSlicer.slice(image, frames: 3)
        #expect(frames.map(\.width) == [3, 3, 5])
        #expect(frames.allSatisfy { $0.height == 2 })
        #expect(frames[1][0, 1] == image[3, 1])
        #expect(frames[2][4, 0] == image[10, 0])

        #expect(FrameSlicer.columnRanges(width: 5, frames: 5) == [0..<1, 1..<2, 2..<3, 3..<4, 4..<5])
        #expect(FrameSlicer.columnRanges(width: 7, frames: 1) == [0..<7])
    }

    // MARK: - NearestResampler

    @Test func nearestResamplerPicksCenterSourcePixel() {
        var image = RGBAImage(width: 2, height: 2)
        let colors = [RGBA(r: 255, g: 0, b: 0, a: 255), RGBA(r: 0, g: 255, b: 0, a: 255),
                      RGBA(r: 0, g: 0, b: 255, a: 255), RGBA(r: 9, g: 9, b: 9, a: 100)]
        image[0, 0] = colors[0]; image[1, 0] = colors[1]
        image[0, 1] = colors[2]; image[1, 1] = colors[3]

        let up = NearestResampler().resize(image, to: PixelSize(width: 4, height: 4))
        #expect(up.width == 4 && up.height == 4)
        for y in 0..<4 {
            for x in 0..<4 { #expect(up[x, y] == image[x / 2, y / 2]) }
        }

        let down = NearestResampler().resize(up, to: PixelSize(width: 2, height: 2))
        #expect(down == image)

        let same = NearestResampler().resize(image, to: PixelSize(width: 2, height: 2))
        #expect(same == image)

        let one = NearestResampler().resize(image, to: PixelSize(width: 1, height: 1))
        #expect(one[0, 0] == colors[3])  // 中心 (0.5·2, 0.5·2) 落在 (1, 1)

        let empty = NearestResampler().resize(RGBAImage(width: 0, height: 0), to: PixelSize(width: 3, height: 2))
        #expect(empty == RGBAImage(width: 3, height: 2))
    }

    // MARK: - Gen.rawImage 约定

    /// 对全部 45 个键、若干组确定的随机数检查 `RawImageSample.build` 的约定。
    @Test func rawImageSamplesMeetGeneratorContract() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33) & 0xFF_FFFF
        }
        for spec in AssetCatalog.all {
            for _ in 0..<20 {
                let entropy = (0..<RawImageSample.entropyCount).map { _ in next() }
                let s = RawImageSample.build(keys: [spec.key], entropy: entropy)
                checkContract(s, spec: spec)
            }
        }
    }

    private func checkContract(_ s: RawImageSample, spec: AssetSpec) {
        let image = s.image
        #expect(s.key == spec.key)
        #expect(s.frames == spec.frames)
        #expect(image.width == s.cellWidth * spec.frames)
        #expect(s.cellWidth <= 96 && image.height <= 96, "每帧应 ≤ 96×96：\(s)")
        #expect(!(image.width == spec.expectedPixelWidth && image.height == spec.expectedPixelHeight),
                "尺寸不应等于 Expected_Pixel_Size：\(s)")
        #expect(FrameSlicer.frameRects(width: image.width, height: image.height, frames: s.frames)
                == (0..<s.frames).map(s.cellRect))

        // 每帧图形落在帧格内且四边留出背景，边界框等于图形矩形。
        for shape in s.shapes {
            let cell = s.cellRect(shape.frame)
            let r = shape.rect
            #expect(r.minX > cell.minX && r.maxX < cell.maxX && r.minY > 0 && r.maxY < image.height, "\(s)")
            #expect(image.opaqueBounds(in: cell) == (s.isTransparentBackground ? r : cell), "\(s)")
            #expect(shape.color.a == 255)
            if !s.isTransparentBackground {
                #expect(RawImageSample.differsEnough(shape.color, s.background), "\(s)")
            }
        }

        // 像素要么是图形色，要么是背景。
        for y in 0..<image.height {
            for x in 0..<image.width {
                let expected = s.isShapePixel(x: x, y: y) ? s.shapes[x / s.cellWidth].color : s.background
                if image[x, y] != expected {
                    Issue.record("像素 (\(x), \(y)) 与构成信息不符：\(s)")
                    return
                }
            }
        }

        // 多帧时各帧图形宽度两两相差 ≥ 2。
        let widths = s.shapes.map(\.rect.width).sorted()
        for (a, b) in zip(widths, widths.dropFirst()) {
            #expect(b - a >= 2, "各帧图形宽度应两两不同：\(s)")
        }

        // 清空一帧后该帧只剩背景。
        if let last = s.shapes.indices.last {
            let cleared = s.clearingFrame(last)
            let cell = s.cellRect(last)
            #expect(cleared.crop(cell) == RGBAImage(width: cell.width, height: cell.height, fill: s.background))
            #expect(cleared.crop(PixelRect(x: 0, y: 0, width: cell.minX, height: image.height))
                    == image.crop(PixelRect(x: 0, y: 0, width: cell.minX, height: image.height)))
        }
    }
}
