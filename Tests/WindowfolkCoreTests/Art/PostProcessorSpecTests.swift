import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 后处理输出符合素材规格（R4.1、R6.12，任务 6.6）。
@Suite struct PostProcessorSpecTests {

    // Feature: 美术, Property 10: 输出符合素材规格
    // **Validates: Requirements 4.1, 6.12**
    @Test func processedOutputMatchesAssetSpec() async {
        let keys = AssetCatalog.all.map(\.key)
        await propertyCheck(count: 150, input: Gen<RawImageSample>.rawImage(among: keys)) { sample in
            let result = PostProcessor.process(sample.image, key: sample.key, resampler: NearestResampler())
            guard case .success(let outcome) = result else { return }
            checkSpec(outcome.image, key: sample.key, context: "\(sample)")
        }
    }

    // MARK: - 示例

    /// 45 个键各取一张固定熵的合成图：都处理成功，且输出符合 Property 10。
    @Test func everyKeyProcessesToSpecSizedOutput() {
        let entropy = (0..<RawImageSample.entropyCount).map { ($0 &* 2_654_435_761) & 0xFF_FFFF }
        for spec in AssetCatalog.all {
            let sample = RawImageSample.build(keys: [spec.key], entropy: entropy)
            #expect(sample.image.width != spec.expectedPixelWidth || sample.image.height != spec.expectedPixelHeight,
                    "\(sample)：合成图尺寸不应等于 Expected_Pixel_Size")
            switch PostProcessor.process(sample.image, key: spec.key, resampler: NearestResampler()) {
            case .success(let outcome):
                checkSpec(outcome.image, key: spec.key, context: "\(sample)")
            case .failure(let error):
                Issue.record("\(sample)：处理失败 \(error)")
            }
        }
    }

    @Test func unknownKeyIsRejected() {
        let image = RGBAImage(width: 16, height: 16, fill: RGBA(r: 200, g: 10, b: 10, a: 255))
        #expect(PostProcessor.process(image, key: "not_a_key", resampler: NearestResampler())
            == .failure(.unknownKey("not_a_key")))
    }

    // MARK: - 辅助

    /// 输出尺寸等于 Expected_Pixel_Size；AssetCatalog 判合规；Asset_Validator 不报「像素尺寸」「空帧」。
    private func checkSpec(_ image: RGBAImage, key: String, context: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        guard let spec = AssetCatalog.spec(key) else {
            Issue.record("\(key) 不在 Asset_Catalog 中", sourceLocation: sourceLocation)
            return
        }
        #expect(image.width == spec.expectedPixelWidth && image.height == spec.expectedPixelHeight,
                "\(context) → \(image.width)×\(image.height)，期望 \(spec.expectedPixelWidth)×\(spec.expectedPixelHeight)",
                sourceLocation: sourceLocation)

        let validation = AssetCatalog.validation(fileName: key + ".png",
                                                 pixelWidth: image.width, pixelHeight: image.height)
        #expect(validation == .valid(spec), "\(context) → AssetCatalog.validation = \(validation)",
                sourceLocation: sourceLocation)

        let verdict = AssetValidator.validate(key: key, decoded: DecodedPNG(image: image, hasAlpha: true))
        if case .fail(let rules, let emptyFrames) = verdict {
            #expect(!rules.contains(.pixelSize) && !rules.contains(.emptyFrame) && emptyFrames.isEmpty,
                    "\(context) → 校验结论 \(verdict)", sourceLocation: sourceLocation)
        }
        #expect(verdict != .missing, "\(context) → 校验结论 missing", sourceLocation: sourceLocation)
    }
}
