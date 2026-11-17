import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// Asset_Validator 的「像素尺寸」结论与 `AssetCatalog.validation` 一致（R6.10，任务 7.3）。
@Suite struct AssetValidatorSizeTests {

    // Feature: 美术, Property 19: 尺寸结论与 AssetCatalog 一致
    // **Validates: Requirements 6.10**
    @Test func pixelSizeVerdictMatchesAssetCatalog() async {
        await propertyCheck(count: 300, input: Gen<SizeSample>.sizeSample) { sample in
            let verdict = AssetValidator.validate(key: sample.key, decoded: sample.decoded)
            let catalogValid = AssetCatalog.validate(fileName: sample.key + ".png",
                                                     pixelWidth: sample.width, pixelHeight: sample.height)
            #expect(reportsPixelSize(verdict) == !catalogValid,
                    "\(sample)：AssetCatalog.validate = \(catalogValid)，校验结论 \(verdict)")
        }
    }

    // Feature: 美术, Property 19: 尺寸结论与 AssetCatalog 一致
    // **Validates: Requirements 6.10**
    // 输入换成 PostProcessor 的输出：校验器不报「像素尺寸」当且仅当 AssetCatalog 判合规。
    @Test func pixelSizeVerdictMatchesAssetCatalogOnProcessedImages() async {
        let keys = AssetCatalog.all.map(\.key)
        await propertyCheck(count: 100, input: Gen<RawImageSample>.rawImage(among: keys)) { sample in
            guard case .success(let outcome) = PostProcessor.process(sample.image, key: sample.key,
                                                                     resampler: NearestResampler())
            else { return }
            let image = outcome.image
            let verdict = AssetValidator.validate(key: sample.key,
                                                  decoded: DecodedPNG(image: image, hasAlpha: true))
            let catalogValid = AssetCatalog.validate(fileName: sample.key + ".png",
                                                     pixelWidth: image.width, pixelHeight: image.height)
            #expect(reportsPixelSize(verdict) == !catalogValid,
                    "\(sample) → \(image.width)×\(image.height)：AssetCatalog.validate = \(catalogValid)，校验结论 \(verdict)")
        }
    }

    // MARK: - 示例

    @Test func exactExpectedSizeIsNotReportedAsPixelSize() {
        for spec in AssetCatalog.all {
            let image = RGBAImage(width: spec.expectedPixelWidth, height: spec.expectedPixelHeight)
            let verdict = AssetValidator.validate(key: spec.key, decoded: DecodedPNG(image: image, hasAlpha: true))
            #expect(!reportsPixelSize(verdict), "\(spec.key)")
        }
    }

    @Test func wrongFrameCountIsReportedAsPixelSize() {
        // 高度和每帧宽度都对、帧数多一帧：AssetCatalog 返回 wrongFrameCount，校验器报「像素尺寸」。
        for spec in AssetCatalog.all {
            let frameWidth = spec.expectedPixelWidth / spec.frames
            let image = RGBAImage(width: frameWidth * (spec.frames + 1), height: spec.expectedPixelHeight)
            let verdict = AssetValidator.validate(key: spec.key, decoded: DecodedPNG(image: image, hasAlpha: true))
            #expect(verdict == .fail([.pixelSize], emptyFrames: []), "\(spec.key)")
        }
    }

    private func reportsPixelSize(_ verdict: AssetVerdict) -> Bool {
        if case .fail(let rules, _) = verdict { return rules.contains(.pixelSize) }
        return false
    }
}

// MARK: - 生成器

/// 一个 Asset_Key 和一张给定像素宽高的图。
fileprivate struct SizeSample: Sendable, CustomStringConvertible {
    var key: String
    var width: Int
    var height: Int
    var hasAlpha: Bool
    var fill: RGBA

    var decoded: DecodedPNG {
        DecodedPNG(image: RGBAImage(width: width, height: height, fill: fill), hasAlpha: hasAlpha)
    }

    var description: String {
        "\(key) \(width)×\(height) hasAlpha=\(hasAlpha) fill=(\(fill.r),\(fill.g),\(fill.b),\(fill.a))"
    }

    static let sideRange = 1...1024

    /// 尺寸取法（mode）：
    /// - 0：宽高在 1…1024 中均匀随机（几乎总是不合规）；
    /// - 1：恰好等于 Expected_Pixel_Size；
    /// - 2：Expected_Pixel_Size 的宽或高（或两者）偏移 −3…3；
    /// - 3：高度正确、宽度为每帧宽度的 1 至 帧数+3 倍（帧数可能不对）。
    static func build(key: String, mode: Int, w: Int, h: Int, dw: Int, dh: Int, k: Int,
                      hasAlpha: Bool, opaque: Bool, rgb: Int) -> SizeSample {
        guard let spec = AssetCatalog.spec(key) else { preconditionFailure("未知 Asset_Key：\(key)") }
        let ew = spec.expectedPixelWidth, eh = spec.expectedPixelHeight
        func clamp(_ v: Int) -> Int { min(max(v, sideRange.lowerBound), sideRange.upperBound) }
        let width: Int, height: Int
        switch mode {
        case 0: (width, height) = (w, h)
        case 1: (width, height) = (ew, eh)
        case 2: (width, height) = (clamp(ew + dw), clamp(eh + dh))
        default:
            let frameWidth = ew / spec.frames
            (width, height) = (clamp(frameWidth * (1 + k % (spec.frames + 3))), eh)
        }
        let fill = opaque
            ? RGBA(r: UInt8(truncatingIfNeeded: rgb >> 16), g: UInt8(truncatingIfNeeded: rgb >> 8),
                   b: UInt8(truncatingIfNeeded: rgb), a: 255)
            : RGBA.clear
        return SizeSample(key: key, width: width, height: height, hasAlpha: hasAlpha, fill: fill)
    }
}

extension Gen where Value == SizeSample {
    fileprivate static var sizeSample: Generator<SizeSample, some SendableSequenceType> {
        let keys = AssetCatalog.all.map(\.key)
        let sizes = zip(Gen<Int>.int(in: 0...3),
                        Gen<Int>.int(in: SizeSample.sideRange), Gen<Int>.int(in: SizeSample.sideRange),
                        Gen<Int>.int(in: -3...3), Gen<Int>.int(in: -3...3), Gen<Int>.int(in: 0...64))
        let style = zip(Gen<Bool>.bool(), Gen<Bool>.bool(), Gen<Int>.int(in: 0...0xFF_FFFF))
        return zip(Gen<String?>.element(of: keys), sizes, style).map { key, size, style in
            SizeSample.build(key: key!, mode: size.0, w: size.1, h: size.2, dw: size.3, dh: size.4, k: size.5,
                             hasAlpha: style.0, opaque: style.1, rgb: style.2)
        }
    }
}
