import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 平铺边缘无缝（R4.10、R4.11、R4.12，任务 6.11）。
@Suite struct PostProcessorTileTests {

    // Feature: 美术, Property 15: 平铺边缘无缝
    // **Validates: Requirements 4.10, 4.11**
    /// 合成原始图（尺寸不等于规格，走去背景与缩放分支）。
    @Test func tileEdgesAreSeamlessForRawImages() async {
        await propertyCheck(count: 120, input: Gen<RawImageSample>.rawImage(among: tileKeys)) { sample in
            let result = PostProcessor.process(sample.image, key: sample.key, resampler: NearestResampler())
            checkSeam(result, key: sample.key, context: "\(sample)")
        }
    }

    // Feature: 美术, Property 15: 平铺边缘无缝
    // **Validates: Requirements 4.10, 4.11**
    /// 规格尺寸的随机像素图（只平移、不缩放），两侧边缘像素任意不同，必须靠接缝平均消除。
    @Test func tileEdgesAreSeamlessForSpecSizedNoise() async {
        await propertyCheck(count: 120, input: Gen<NoiseTile>.noiseTile) { tile in
            let result = PostProcessor.process(tile.image, key: tile.key, resampler: NearestResampler())
            checkSeam(result, key: tile.key, context: "\(tile)")
        }
    }

    // MARK: - 示例

    /// 规格尺寸、全不透明的 plank：内容已居中不平移，左右列都变为两者的逐通道平均（±1 取整）。
    @Test func plankEdgeColumnsAreAveraged() throws {
        let spec = try #require(AssetCatalog.spec(AssetCatalog.plankKey))
        let w = spec.expectedPixelWidth, h = spec.expectedPixelHeight
        var image = RGBAImage(width: w, height: h, fill: RGBA(r: 120, g: 120, b: 120, a: 255))
        let left = RGBA(r: 250, g: 10, b: 0, a: 255), right = RGBA(r: 0, g: 21, b: 200, a: 200)
        for y in 0..<h {
            image[0, y] = left
            image[w - 1, y] = right
        }
        let outcome = try PostProcessor.process(image, key: spec.key, resampler: NearestResampler()).get()
        for y in 0..<h {
            let l = outcome.image[0, y], r = outcome.image[w - 1, y]
            #expect(l == r, "第 \(y) 行：\(l) ≠ \(r)")
            expectAverage(l, of: left, right, context: "第 \(y) 行")
        }
        // 内部像素不受影响。
        #expect(outcome.image[1, 0] == RGBA(r: 120, g: 120, b: 120, a: 255))
    }

    /// 规格尺寸、全不透明的 ladder：上下行都变为两者的逐通道平均（±1 取整）。
    @Test func ladderEdgeRowsAreAveraged() throws {
        let spec = try #require(AssetCatalog.spec(AssetCatalog.ladderKey))
        let w = spec.expectedPixelWidth, h = spec.expectedPixelHeight
        var image = RGBAImage(width: w, height: h, fill: RGBA(r: 60, g: 90, b: 30, a: 255))
        let top = RGBA(r: 255, g: 255, b: 255, a: 255), bottom = RGBA(r: 0, g: 0, b: 0, a: 255)
        for x in 0..<w {
            image[x, 0] = top
            image[x, h - 1] = bottom
        }
        let outcome = try PostProcessor.process(image, key: spec.key, resampler: NearestResampler()).get()
        for x in 0..<w {
            let t = outcome.image[x, 0], b = outcome.image[x, h - 1]
            #expect(t == b, "第 \(x) 列：\(t) ≠ \(b)")
            expectAverage(t, of: top, bottom, context: "第 \(x) 列")
        }
        #expect(outcome.image[0, 1] == RGBA(r: 60, g: 90, b: 30, a: 255))
    }

    // MARK: - 辅助

    private let tileKeys = [AssetCatalog.plankKey, AssetCatalog.ladderKey]

    /// 处理成功（不应出现 `tileSeam`），且输出两侧边缘逐对满足阈值；Asset_Validator 不报「平铺边缘」。
    private func checkSeam(_ result: Result<ProcessOutcome, PostProcessError>, key: String, context: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        let image: RGBAImage
        switch result {
        case .success(let outcome):
            image = outcome.image
        case .failure(let error):
            Issue.record("\(context)：处理失败 \(error)", sourceLocation: sourceLocation)
            return
        }
        guard let spec = AssetCatalog.spec(key), image.width > 0, image.height > 0 else {
            Issue.record("\(context)：输出为空或键未知", sourceLocation: sourceLocation)
            return
        }

        var pairs: [(String, RGBA, RGBA)] = []
        switch spec.tiling {
        case .horizontal:
            pairs = (0..<image.height).map { y in ("第 \(y) 行左右列", image[0, y], image[image.width - 1, y]) }
        case .vertical:
            pairs = (0..<image.width).map { x in ("第 \(x) 列上下行", image[x, 0], image[x, image.height - 1]) }
        case .none:
            Issue.record("\(key) 不是平铺素材", sourceLocation: sourceLocation)
        }
        for (place, p, q) in pairs where !withinSeamTolerance(p, q) {
            Issue.record("\(context) → \(place) \(p) 与 \(q) 超出阈值", sourceLocation: sourceLocation)
            break
        }

        let verdict = AssetValidator.validate(key: key, decoded: DecodedPNG(image: image, hasAlpha: true))
        if case .fail(let rules, _) = verdict {
            #expect(!rules.contains(.tileEdge), "\(context) → 校验结论 \(verdict)", sourceLocation: sourceLocation)
        }
    }

    /// R4.10、R4.11：alpha 差 ≤ 16，R、G、B 每通道差 ≤ 24（与 Asset_Validator 共用阈值）。
    private func withinSeamTolerance(_ p: RGBA, _ q: RGBA) -> Bool {
        func diff(_ a: UInt8, _ b: UInt8) -> Int { abs(Int(a) - Int(b)) }
        return diff(p.a, q.a) <= 16 && diff(p.r, q.r) <= 24 && diff(p.g, q.g) <= 24 && diff(p.b, q.b) <= 24
    }

    private func expectAverage(_ m: RGBA, of p: RGBA, _ q: RGBA, context: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        func close(_ v: UInt8, _ a: UInt8, _ b: UInt8) -> Bool { abs(2 * Int(v) - Int(a) - Int(b)) <= 1 }
        #expect(close(m.r, p.r, q.r) && close(m.g, p.g, q.g) && close(m.b, p.b, q.b) && close(m.a, p.a, q.a),
                "\(context)：\(m) 不是 \(p) 与 \(q) 的平均", sourceLocation: sourceLocation)
    }
}

// MARK: - 生成器

/// 规格尺寸的 plank 或 ladder 随机像素图：每个像素 RGB 任意，alpha 为 0 或任意值；保证至少有一个不透明像素。
fileprivate struct NoiseTile: Sendable, CustomStringConvertible {
    var key: String
    var image: RGBAImage

    /// ladder 规格尺寸的像素数（plank 更小），生成器按此数量取随机数。
    static let maxPixels = [AssetCatalog.plankKey, AssetCatalog.ladderKey]
        .compactMap { AssetCatalog.spec($0) }.map { $0.expectedPixelWidth * $0.expectedPixelHeight }.max() ?? 0

    static func build(_ entropy: [Int]) -> NoiseTile {
        let key = entropy[0] % 2 == 0 ? AssetCatalog.plankKey : AssetCatalog.ladderKey
        let spec = AssetCatalog.spec(key)!
        let w = spec.expectedPixelWidth, h = spec.expectedPixelHeight
        // 透明像素比例 0%、25%、50%、75% 之一。
        let transparentQuarters = (entropy[0] >> 1) % 4
        var image = RGBAImage(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let v = entropy[1 + y * w + x]
                let transparent = (v >> 32) % 4 < transparentQuarters
                image[x, y] = RGBA(r: UInt8(truncatingIfNeeded: v), g: UInt8(truncatingIfNeeded: v >> 8),
                                   b: UInt8(truncatingIfNeeded: v >> 16),
                                   a: transparent ? 0 : UInt8(truncatingIfNeeded: v >> 24) | 1)
            }
        }
        if image.opaqueBounds() == nil { image[w / 2, h / 2] = RGBA(r: 1, g: 2, b: 3, a: 255) }
        return NoiseTile(key: key, image: image)
    }

    var description: String {
        let edge: [RGBA]
        if key == AssetCatalog.plankKey {
            edge = [image[0, 0], image[image.width - 1, 0]]
        } else {
            edge = [image[0, 0], image[0, image.height - 1]]
        }
        return "\(key) \(image.width)×\(image.height) 首对边缘像素 \(edge)"
    }
}

fileprivate extension Gen where Value == NoiseTile {
    static var noiseTile: Generator<NoiseTile, some SendableSequenceType> {
        Gen<Int>.int(in: 0...0x3_FFFF_FFFF)
            .array(of: 1 + NoiseTile.maxPixels)
            .map { NoiseTile.build($0) }
    }
}
