import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 后处理按 idle 参考高度调整 Grounded 居民的缩放比例（R4.7，任务 6.9）。
@Suite struct PostProcessorIdleHeightTests {

    // Feature: 美术, Property 13: 与 idle 高度一致
    // **Validates: Requirements 4.7**
    @Test func groundedFramesMatchIdleReferenceHeight() async {
        await propertyCheck(count: 120, input: Gen<IdleHeightSample>.idleHeightSample()) { sample in
            let context = ProcessContext(idleReferenceHeight: sample.referenceHeight)
            let result = PostProcessor.process(sample.raw.image, key: sample.raw.key, context: context,
                                               resampler: NearestResampler())
            guard case .success(let outcome) = result else {
                Issue.record("\(sample)：处理失败 \(result)")
                return
            }
            checkFrames(outcome, sample: sample)
            // 各帧都在 10% 以内，因此不应有 R4.7 警告。
            #expect(outcome.warnings.isEmpty, "\(sample)：意外警告 \(outcome.warnings)")
        }
    }

    // MARK: - 示例

    /// 原始各帧高度差得太多（20 与 40）时，缩放后仍有帧超出 10%：写入警告，处理照常成功。
    @Test func largeHeightSpreadWarnsButSucceeds() {
        let key = AssetCatalog.residentKey(.a, .idle)
        let heights = [20, 40, 20, 40]
        let raw = Self.image(heights: heights, width: 10, cellWidth: 30, cellHeight: 50)
        let result = PostProcessor.process(raw, key: key, context: ProcessContext(idleReferenceHeight: 30),
                                           resampler: NearestResampler())
        guard case .success(let outcome) = result else {
            Issue.record("处理失败 \(result)")
            return
        }
        #expect(outcome.warnings.count == 4, "\(outcome.warnings)")
        for (i, warning) in outcome.warnings.enumerated() {
            #expect(warning.contains(key) && warning.contains("第 \(i + 1) 帧"), "\(warning)")
        }
        // s_t = 2·30 / (20 + 40) = 1，内容 20 与 40 像素高，都在 64 像素帧内。
        let frameHeights = Self.frameBounds(outcome.image, frames: 4).map { $0?.height }
        #expect(frameHeights == [20, 40, 20, 40])
    }

    /// 参考高度只能把比例调小：s_t 大于一般比例时取一般比例，内容不超出帧。
    @Test func referenceLargerThanFrameIsCappedByFrame() {
        let key = AssetCatalog.residentKey(.b, .walking)
        let raw = Self.image(heights: Array(repeating: 40, count: 6), width: 20, cellWidth: 30, cellHeight: 50)
        let result = PostProcessor.process(raw, key: key, context: ProcessContext(idleReferenceHeight: 200),
                                           resampler: NearestResampler())
        guard case .success(let outcome) = result else {
            Issue.record("处理失败 \(result)")
            return
        }
        let bounds = Self.frameBounds(outcome.image, frames: 6)
        #expect(bounds.allSatisfy { $0?.height == 64 && $0?.width == 32 }, "\(bounds)")
    }

    // MARK: - 辅助

    /// 每帧不透明边界框高度与 H 相差 ≤ 10%；内容不超出帧（缩放后宽高比与原图一致，没有被压扁或裁掉）。
    private func checkFrames(_ outcome: ProcessOutcome, sample: IdleHeightSample,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let n = sample.raw.frames
        let fh = outcome.image.height
        let fw = outcome.image.width / n
        let h = Double(sample.referenceHeight)
        for (i, box) in Self.frameBounds(outcome.image, frames: n).enumerated() {
            guard let box else {
                Issue.record("\(sample)：输出第 \(i + 1) 帧为空", sourceLocation: sourceLocation)
                continue
            }
            #expect(abs(Double(box.height) - h) <= PostProcessor.idleHeightTolerance * h,
                    "\(sample)：第 \(i + 1) 帧高度 \(box.height)，参考 \(sample.referenceHeight)",
                    sourceLocation: sourceLocation)
            #expect(box.minX >= 0 && box.minY >= 0 && box.maxX <= fw && box.maxY <= fh,
                    "\(sample)：第 \(i + 1) 帧边界框 \(box) 超出 \(fw)×\(fh)", sourceLocation: sourceLocation)
            // 内容完整：宽度按同一比例缩放（各轴取整误差各 0.5 像素，宽 ≤ 高时合计 ≤ 1）。
            let shape = sample.raw.shapes[i].rect
            let expectedWidth = Double(shape.width) * Double(box.height) / Double(shape.height)
            #expect(abs(Double(box.width) - expectedWidth) <= 1.5,
                    "\(sample)：第 \(i + 1) 帧 \(box.width)×\(box.height)，原图 \(shape.width)×\(shape.height)",
                    sourceLocation: sourceLocation)
        }
    }

    /// 输出拼接图中每帧（等宽切分）的不透明边界框，帧内坐标。
    fileprivate static func frameBounds(_ image: RGBAImage, frames: Int) -> [PixelRect?] {
        let fw = image.width / frames
        return (0..<frames).map { i in
            image.opaqueBounds(in: PixelRect(x: i * fw, y: 0, width: fw, height: image.height))?
                .offsetBy(dx: -i * fw, dy: 0)
        }
    }

    /// 透明背景上每格一个宽 `width`、高 `heights[i]` 的实心矩形，水平居中、距底 3 像素。
    fileprivate static func image(heights: [Int], width: Int, cellWidth: Int, cellHeight: Int) -> RGBAImage {
        var image = RGBAImage(width: cellWidth * heights.count, height: cellHeight)
        let color = RGBA(r: 180, g: 90, b: 40, a: 255)
        for (i, h) in heights.enumerated() {
            let x0 = i * cellWidth + (cellWidth - width) / 2
            for y in (cellHeight - 3 - h)..<(cellHeight - 3) {
                for x in x0..<(x0 + width) { image[x, y] = color }
            }
        }
        return image
    }
}

// MARK: - 生成器

/// Property 13 的输入：Grounded 居民的合成原始图（各帧高度彼此相差 ≤ 5%）与 idle 参考高度 `H`。
fileprivate struct IdleHeightSample: Hashable, Sendable, CustomStringConvertible {
    var raw: RawImageSample
    /// `1...fh`。
    var referenceHeight: Int

    var description: String { "H=\(referenceHeight) \(raw)" }
}

fileprivate enum IdleHeightGen {
    static let groundedKeys = AssetRules.all.filter(\.isGrounded).map(\.spec.key)
    static let entropyHeader = 7
    static let entropyPerFrame = 5
    static let entropyCount = entropyHeader + entropyPerFrame * RawImageSample.maxFrames

    /// 用一组随机整数确定地构造样本。
    ///
    /// 图形宽度不超过最矮一帧的高度（居民站姿瘦高）。帧为正方形时这保证宽度不会先于高度限制比例，
    /// 否则「高度接近 H」与「内容不超出帧」无法同时满足，R4.7 的前提不成立。
    static func build(_ e: [Int]) -> IdleHeightSample {
        func pick(_ v: Int, _ range: ClosedRange<Int>) -> Int {
            range.lowerBound + abs(v) % (range.upperBound - range.lowerBound + 1)
        }
        let key = groundedKeys[pick(e[0], 0...(groundedKeys.count - 1))]
        let spec = AssetCatalog.spec(key)!
        let n = spec.frames
        let fw = spec.expectedPixelWidth / n
        let fh = spec.expectedPixelHeight

        let transparent = pick(e[1], 0...2) == 0
        let background = transparent ? RGBA.clear
            : RGBA(r: UInt8(truncatingIfNeeded: e[2] >> 16), g: UInt8(truncatingIfNeeded: e[2] >> 8),
                   b: UInt8(truncatingIfNeeded: e[2]), a: 255)

        let side = RawImageSample.minCellSide...RawImageSample.maxCellSide
        let cellWidth = pick(e[3], side)
        var cellHeight = pick(e[4], side)
        if cellWidth * n == spec.expectedPixelWidth && cellHeight == fh { cellHeight -= 1 }

        // 高度在 [hMin, hMax] 内，hMax ≤ ⌊1.05 · hMin⌋。
        let hMin = pick(e[5], RawImageSample.minShapeSide...(cellHeight - 2))
        let hMax = min(cellHeight - 2, hMin * 105 / 100)
        let heights = (0..<n).map { i in pick(e[entropyHeader + i * entropyPerFrame], hMin...hMax) }
        let wLimit = min(heights.min()!, cellWidth - 2, heights.min()! * fw / fh)

        var image = RGBAImage(width: cellWidth * n, height: cellHeight, fill: background)
        var shapes: [RawShape] = []
        for i in 0..<n {
            let fe = Array(e[(entropyHeader + i * entropyPerFrame)...].prefix(entropyPerFrame))
            let h = heights[i]
            let w = pick(fe[1], 1...max(1, wLimit))
            let x = i * cellWidth + pick(fe[2], 1...(cellWidth - 1 - w))
            let y = pick(fe[3], 1...(cellHeight - 1 - h))
            var color = RGBA(r: UInt8(truncatingIfNeeded: fe[4] >> 16), g: UInt8(truncatingIfNeeded: fe[4] >> 8),
                             b: UInt8(truncatingIfNeeded: fe[4]), a: 255)
            if !transparent && !RawImageSample.differsEnough(color, background) { color.r &+= 128 }
            // 直角矩形：最近邻缩放后每行每列都有不透明像素，边界框等于缩放尺寸。
            let shape = RawShape(frame: i, rect: PixelRect(x: x, y: y, width: w, height: h),
                                 cornerRadius: 0, color: color)
            for py in y..<(y + h) {
                for px in x..<(x + w) { image[px, py] = color }
            }
            shapes.append(shape)
        }
        let raw = RawImageSample(key: key, image: image, background: background, shapes: shapes,
                                 cellWidth: cellWidth)
        return IdleHeightSample(raw: raw, referenceHeight: pick(e[6], 1...fh))
    }
}

extension Gen where Value == IdleHeightSample {
    fileprivate static func idleHeightSample() -> Generator<IdleHeightSample, some SendableSequenceType> {
        Gen<Int>.int(in: RawImageSample.entropyRange)
            .array(of: IdleHeightGen.entropyCount)
            .map(IdleHeightGen.build)
    }
}
