import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 后处理幂等（R4.3、R4.13，任务 6.12）。
///
/// 第一次处理的输出 `p` 已是 Expected_Pixel_Size，再处理时应跳过去背景和缩放、只做平移：
/// 尺寸不变，每帧不透明边界框四边移动不超过 1 像素，透明像素不增加。
@Suite struct PostProcessorIdempotenceTests {

    // Feature: 美术, Property 16: 后处理幂等
    // **Validates: Requirements 4.3, 4.13**
    @Test func reprocessingProcessedOutputIsIdempotent() async {
        let keys = AssetCatalog.all.map(\.key)
        await propertyCheck(count: 150, input: Gen<RawImageSample>.rawImage(among: keys)) { sample in
            checkIdempotence(sample)
        }
    }

    // Feature: 美术, Property 16: 后处理幂等
    // **Validates: Requirements 4.3, 4.13**
    // 四角可能不透明的平铺件与工具箱单独加密采样：再处理不得抹掉 `p` 中的不透明像素。
    @Test func reprocessingKeepsOpaqueCornersOfTilesAndToolbox() async {
        await propertyCheck(count: 100, input: Gen<RawImageSample>.rawImage(among: opaqueCornerKeys)) { sample in
            checkIdempotence(sample)
        }
    }

    // MARK: - 示例

    /// 四角不透明的规格尺寸成品图（整帧填满）直接作为输入：不被当成背景抹掉。
    @Test func fullyOpaqueSpecSizedInputIsNotErased() {
        for key in opaqueCornerKeys {
            guard let spec = AssetCatalog.spec(key) else {
                Issue.record("\(key) 不在 Asset_Catalog 中")
                continue
            }
            let fill = RGBA(r: 140, g: 90, b: 50, a: 255)
            let input = RGBAImage(width: spec.expectedPixelWidth, height: spec.expectedPixelHeight, fill: fill)
            switch PostProcessor.process(input, key: key, resampler: NearestResampler()) {
            case .success(let outcome):
                #expect(outcome.image.width == input.width && outcome.image.height == input.height, "\(key)")
                #expect(transparentCount(outcome.image) <= transparentCount(input),
                        "\(key)：透明像素 \(transparentCount(input)) → \(transparentCount(outcome.image))")
            case .failure(let error):
                Issue.record("\(key)：处理失败 \(error)")
            }
        }
    }
}

// MARK: - 辅助

/// 成品四角可以不透明的键：plank、ladder、toolbox（R4.3 例外条款点名）。
fileprivate let opaqueCornerKeys = AssetRules.unframedKeys.sorted()

/// 检查 `process(process(raw))` 相对 `process(raw)` 的幂等性。第一次处理失败的样本不在属性范围内。
fileprivate func checkIdempotence(_ sample: RawImageSample, sourceLocation: SourceLocation = #_sourceLocation) {
    let resampler = NearestResampler()
    guard case .success(let first) = PostProcessor.process(sample.image, key: sample.key, resampler: resampler),
          let spec = AssetCatalog.spec(sample.key) else { return }
    let p = first.image

    let second: RGBAImage
    switch PostProcessor.process(p, key: sample.key, resampler: resampler) {
    case .success(let outcome): second = outcome.image
    case .failure(let error):
        Issue.record("\(sample)：再处理失败 \(error)", sourceLocation: sourceLocation)
        return
    }

    #expect(second.width == p.width && second.height == p.height,
            "\(sample)：尺寸 \(p.width)×\(p.height) → \(second.width)×\(second.height)",
            sourceLocation: sourceLocation)
    guard second.width == p.width, second.height == p.height else { return }

    for (i, cell) in FrameSlicer.frameRects(width: p.width, height: p.height, frames: spec.frames).enumerated() {
        let before = p.opaqueBounds(in: cell)
        let after = second.opaqueBounds(in: cell)
        guard let b = before, let a = after else {
            #expect(before == nil && after == nil,
                    "\(sample)：第 \(i + 1) 帧边界框 \(String(describing: before)) → \(String(describing: after))",
                    sourceLocation: sourceLocation)
            continue
        }
        let maxDelta = max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY))
        #expect(maxDelta <= 1, "\(sample)：第 \(i + 1) 帧边界框 \(b) → \(a)", sourceLocation: sourceLocation)
    }

    let t0 = transparentCount(p), t1 = transparentCount(second)
    #expect(t1 <= t0, "\(sample)：alpha 为 0 的像素 \(t0) → \(t1)", sourceLocation: sourceLocation)
}

/// alpha 为 0 的像素个数。
fileprivate func transparentCount(_ image: RGBAImage) -> Int {
    var count = 0
    for y in 0..<image.height {
        for x in 0..<image.width where image.alpha(x: x, y: y) == 0 {
            count += 1
        }
    }
    return count
}
