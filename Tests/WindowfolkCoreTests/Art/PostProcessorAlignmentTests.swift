import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 后处理的锚点对齐与 Framed_Asset 四角透明（R4.5、R4.8、R4.9、R4.14，任务 6.8）。
@Suite struct PostProcessorAlignmentTests {

    // Feature: 美术, Property 12: 锚点对齐与四角透明
    // **Validates: Requirements 4.5, 4.8, 4.9, 4.14**
    @Test func anchorsAlignedAndFramedCornersTransparent() async {
        await propertyCheck(count: 150, input: Gen<RawImageSample>.rawImage(among: alignmentPropertyKeys)) { sample in
            guard let rules = AssetRules.rules(for: sample.key) else {
                Issue.record("\(sample.key) 没有 AssetRules")
                return
            }
            switch PostProcessor.process(sample.image, key: sample.key, resampler: NearestResampler()) {
            case .success(let outcome):
                checkAlignment(outcome.image, rules: rules, context: "\(sample)")
            case .failure(let error):
                Issue.record("\(sample)：处理失败 \(error)")
            }
        }
    }

    // MARK: - 示例

    /// 花朵偏向右侧、花盆在下方：锚点取最下 4 行（花盆），花盆居中贴底，整体边界框不居中。
    @Test func flowerPotIsCenteredWhenBloomLeansAside() throws {
        let key = AssetCatalog.flowerKey(FlowerAssetStage.allCases[0])
        let rules = try #require(AssetRules.rules(for: key))
        let pot = RGBA(r: 180, g: 110, b: 60, a: 255)
        let bloom = RGBA(r: 60, g: 170, b: 70, a: 255)
        var raw = RGBAImage(width: 50, height: 70)
        fill(&raw, PixelRect(x: 8, y: 56, width: 20, height: 12), pot)
        fill(&raw, PixelRect(x: 22, y: 6, width: 26, height: 50), bloom)

        let outcome = try PostProcessor.process(raw, key: key, resampler: NearestResampler()).get()
        let frame = outcome.image
        checkAlignment(frame, rules: rules, context: key)
        let bounds = try #require(frame.opaqueBounds())
        #expect(abs(bounds.minX + bounds.maxX - frame.width) > 2 * PostProcessor.centerTolerance,
                "整体边界框不应居中：\(bounds)，帧宽 \(frame.width)")
    }

    // MARK: - 辅助

    /// 有对齐约束（`groundedPerFrame`、`centeredBottom`、`anchoredBase`）或属于 Framed_Asset 的键。
    private var alignmentPropertyKeys: [String] {
        AssetRules.all.filter { hasAnchorRule($0.alignment) || $0.isFramed }.map(\.spec.key)
    }

    /// 每帧贴底 ≤ 2、锚点水平中心偏差 ≤ 1（仅前述三种对齐方式）；Framed_Asset 每帧四角 2×2 alpha 为 0。
    private func checkAlignment(_ image: RGBAImage, rules: AssetRules, context: String,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let spec = rules.spec
        guard image.width == spec.expectedPixelWidth, image.height == spec.expectedPixelHeight else {
            Issue.record("\(context) → 输出 \(image.width)×\(image.height) 不是规格尺寸", sourceLocation: sourceLocation)
            return
        }
        let fw = spec.expectedPixelWidth / spec.frames, fh = spec.expectedPixelHeight
        for i in 0..<spec.frames {
            let frame = image.crop(PixelRect(x: i * fw, y: 0, width: fw, height: fh))

            if hasAnchorRule(rules.alignment) {
                guard let bounds = frame.opaqueBounds() else {
                    Issue.record("\(context) → 第 \(i + 1) 帧为空", sourceLocation: sourceLocation)
                    continue
                }
                let gap = fh - bounds.maxY
                #expect(gap >= 0 && gap <= PostProcessor.bottomTolerance,
                        "\(context) → 第 \(i + 1) 帧距底边 \(gap) 像素，边界框 \(bounds)",
                        sourceLocation: sourceLocation)
                let anchor = anchorRect(frame, bounds: bounds, alignment: rules.alignment)
                // 两倍坐标：|锚点中心 − fw/2| ≤ 1 ⇔ |minX + maxX − fw| ≤ 2。
                let offset2 = anchor.minX + anchor.maxX - fw
                #expect(abs(offset2) <= 2 * PostProcessor.centerTolerance,
                        "\(context) → 第 \(i + 1) 帧锚点 \(anchor) 中心偏离帧中心 \(Double(offset2) / 2) 像素",
                        sourceLocation: sourceLocation)
            }

            if rules.isFramed {
                let c = PostProcessor.cornerSize
                let corners = [(0, 0), (fw - c, 0), (0, fh - c), (fw - c, fh - c)]
                for (ox, oy) in corners {
                    for y in oy..<(oy + c) {
                        for x in ox..<(ox + c) where frame[x, y].a != 0 {
                            Issue.record("\(context) → 第 \(i + 1) 帧角像素 (\(x),\(y)) alpha = \(frame[x, y].a)",
                                         sourceLocation: sourceLocation)
                        }
                    }
                }
            }
        }
    }

    private func hasAnchorRule(_ alignment: AlignmentMode) -> Bool {
        switch alignment {
        case .groundedPerFrame, .centeredBottom, .anchoredBase: return true
        case .nonGroundedUniform, .tile: return false
        }
    }

    /// 锚点：`anchoredBase` 为最下方 4 行不透明像素的边界框，其余为整体边界框。
    private func anchorRect(_ frame: RGBAImage, bounds: PixelRect, alignment: AlignmentMode) -> PixelRect {
        guard case .anchoredBase = alignment else { return bounds }
        let top = max(bounds.minY, bounds.maxY - PostProcessor.anchorRows)
        let base = PixelRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
        return frame.opaqueBounds(in: base) ?? bounds
    }

    private func fill(_ image: inout RGBAImage, _ rect: PixelRect, _ color: RGBA) {
        for y in rect.minY..<rect.maxY {
            for x in rect.minX..<rect.maxX {
                image[x, y] = color
            }
        }
    }
}
