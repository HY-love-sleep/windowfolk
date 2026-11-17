import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 后处理所有帧共用最大适配比例（R4.4、R4.6，任务 6.7）。
///
/// 比例按轴检查：每个轴上存在同一个 `s`，使每帧输出边界框边长与原始边长 × `s` 相差不超过 1 像素，
/// 等价于任意两帧边长之比与原始图对应两帧之比在每边 ±1 像素的取整误差内。
/// 最大适配：一般情况至少一帧的宽或高与帧尺寸相差 ≤ 1；`nonGroundedUniform` 看帧并集；
/// `anchoredBase` 按锚点两侧较宽一侧的两倍宽度适配，宽度方向看内容是否触到帧的左右边（±1）。
@Suite struct PostProcessorScaleTests {

    // Feature: 美术, Property 11: 所有帧共用最大适配比例
    // **Validates: Requirements 4.4, 4.6**
    @Test func multiFrameAssetsShareMaximalFitScale() async {
        await propertyCheck(count: 120, input: Gen<RawImageSample>.rectangularRawImage(among: multiFrameKeys)) { sample in
            checkScale(sample)
        }
    }

    // Feature: 美术, Property 11: 所有帧共用最大适配比例
    // **Validates: Requirements 4.4, 4.6**
    @Test func everyAssetUsesMaximalFitScale() async {
        let keys = AssetCatalog.all.map(\.key)
        await propertyCheck(count: 100, input: Gen<RawImageSample>.rectangularRawImage(among: keys)) { sample in
            checkScale(sample)
        }
    }

    // MARK: - 示例

    /// Grounded 居民：三帧宽 10、20、30，高相同；宽度最大的帧铺满帧宽，其余按 1:2:3。
    @Test func groundedFramesScaleTogether() throws {
        let rules = try #require(AssetRules.all.first { $0.alignment == .groundedPerFrame && $0.spec.frames >= 3 })
        let n = rules.spec.frames
        let fw = rules.spec.expectedPixelWidth / n
        let cell = 40, height = 40
        var raw = RGBAImage(width: cell * n, height: height)
        let color = RGBA(r: 200, g: 40, b: 40, a: 255)
        for i in 0..<n {
            let w = i < 3 ? 10 * (i + 1) : 10
            raw = raw.pasting(RGBAImage(width: w, height: 6, fill: color), at: PixelPoint(x: i * cell + 2, y: 30))
        }
        let outcome = try PostProcessor.process(raw, key: rules.spec.key, resampler: NearestResampler()).get()
        let frames = FrameSlicer.slice(outcome.image, frames: n)
        let widths = try frames.prefix(3).map { try #require($0.opaqueBounds()).width }
        // s = fw / 30：第 3 帧铺满帧宽，前两帧为 1/3、2/3（取整 ±1）。
        #expect(abs(widths[2] - fw) <= 1, "宽度 \(widths)，帧宽 \(fw)")
        #expect(abs(Double(widths[0]) - Double(fw) / 3) <= 1, "宽度 \(widths)，帧宽 \(fw)")
        #expect(abs(Double(widths[1]) - Double(fw) * 2 / 3) <= 1, "宽度 \(widths)，帧宽 \(fw)")
    }

    // MARK: - 检查

    private var multiFrameKeys: [String] {
        AssetCatalog.all.filter { $0.frames > 1 }.map(\.key)
    }

    private func checkScale(_ sample: RawImageSample, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let rules = AssetRules.rules(for: sample.key) else {
            Issue.record("\(sample.key) 不在 Asset_Catalog 中", sourceLocation: sourceLocation)
            return
        }
        let n = rules.spec.frames
        let fw = rules.spec.expectedPixelWidth / n
        let fh = rules.spec.expectedPixelHeight

        let outcome: ProcessOutcome
        switch PostProcessor.process(sample.image, key: sample.key, resampler: NearestResampler()) {
        case .success(let o): outcome = o
        case .failure(let error):
            Issue.record("\(sample)：处理失败 \(error)", sourceLocation: sourceLocation)
            return
        }

        let outputFrames = FrameSlicer.slice(outcome.image, frames: n)
        var measured: [Measured] = []
        for (i, frame) in outputFrames.enumerated() {
            guard let box = frame.opaqueBounds() else {
                Issue.record("\(sample)：输出第 \(i + 1) 帧为空", sourceLocation: sourceLocation)
                return
            }
            measured.append(Measured(box: box, fw: fw, fh: fh, framed: rules.isFramed))
        }
        // 原始帧边界框（帧格坐标）即图形外接矩形。
        let rawBoxes = sample.shapes.enumerated().map { i, s in s.rect.offsetBy(dx: -sample.cellRect(i).minX, dy: 0) }
        let detail = "\(sample) → 输出边界框 " + measured.map { "[\($0.box.x),\($0.box.y) \($0.box.width)×\($0.box.height)]" }
            .joined(separator: " ")

        // 每个轴共用一个比例：所有区间 [(o − 1) / r, (o + 1 + slack) / r] 有交集。
        let widthOK = commonScaleExists(zip(rawBoxes, measured).map { ($0.width, $1.box.width, $1.slackW) })
        let heightOK = commonScaleExists(zip(rawBoxes, measured).map { ($0.height, $1.box.height, $1.slackH) })
        #expect(widthOK, "各帧宽度没有共用比例：\(detail)", sourceLocation: sourceLocation)
        #expect(heightOK, "各帧高度没有共用比例：\(detail)", sourceLocation: sourceLocation)

        // 最大适配。
        let fits: Bool
        switch rules.alignment {
        case .nonGroundedUniform:
            let union = measured.dropFirst().reduce(measured[0].box) { $0.union($1.box) }
            let u = Measured(box: union, fw: fw, fh: fh, framed: rules.isFramed)
            fits = u.box.width + u.slackW >= fw - 1 || u.box.height + u.slackH >= fh - 1
        case .anchoredBase:
            fits = measured.contains { m in
                m.box.minX - m.slackLeft <= 1 || m.box.maxX + m.slackRight >= fw - 1
                    || m.box.height + m.slackH >= fh - 1
            }
        default:
            fits = measured.contains { $0.box.width + $0.slackW >= fw - 1 || $0.box.height + $0.slackH >= fh - 1 }
        }
        #expect(fits, "没有帧达到帧尺寸（\(fw)×\(fh)，±1）：\(detail)", sourceLocation: sourceLocation)
    }

    /// `(原始边长, 输出边长, 额外上偏差)` 的列表是否存在共同比例 `s`，使 `o − 1 ≤ r·s ≤ o + 1 + slack`。
    private func commonScaleExists(_ sides: [(raw: Int, out: Int, slack: Int)]) -> Bool {
        var lo = 0.0, hi = Double.infinity
        for side in sides {
            let r = Double(side.raw)
            lo = max(lo, Double(side.out - 1) / r)
            hi = min(hi, Double(side.out + 1 + side.slack) / r)
        }
        return lo <= hi + 1e-9
    }
}

/// 输出帧的不透明边界框，以及 Framed_Asset 四角清理（R4.14）可能裁掉的边长。
///
/// 内容伸进 2×2 角区时，清理会让边界框在该侧缩进到恰好 `cornerSize`；
/// 此时原本的边可能在 0 到 `cornerSize` 之间，该侧记为最多少了 `cornerSize` 像素。
fileprivate struct Measured {
    var box: PixelRect
    var slackLeft = 0, slackRight = 0, slackTop = 0, slackBottom = 0
    var slackW: Int { slackLeft + slackRight }
    var slackH: Int { slackTop + slackBottom }

    init(box: PixelRect, fw: Int, fh: Int, framed: Bool) {
        self.box = box
        guard framed else { return }
        let c = PostProcessor.cornerSize
        let nearCornerRows = box.minY <= c || box.maxY >= fh - c
        let nearCornerColumns = box.minX <= c || box.maxX >= fw - c
        if nearCornerRows && box.minX == c { slackLeft = c }
        if nearCornerRows && box.maxX == fw - c { slackRight = c }
        if nearCornerColumns && box.minY == c { slackTop = c }
        if nearCornerColumns && box.maxY == fh - c { slackBottom = c }
    }
}

// MARK: - 生成器

extension Gen where Value == RawImageSample {
    /// `rawImage(among:)` 的图形改为直角矩形（半径 0）重新绘制。
    ///
    /// 圆角矩形最外一行只有中间一小段像素，最近邻缩小时可能整段被跳过，边界框因此少 1 至 2 行，
    /// 和缩放比例无关。直角矩形缩放后的边界框恰好等于缩放尺寸，只剩取整误差。
    fileprivate static func rectangularRawImage(among keys: [String])
        -> Generator<RawImageSample, some SendableSequenceType> {
        rawImage(among: keys).map { sample in
            var out = sample
            out.image = RGBAImage(width: sample.image.width, height: sample.image.height, fill: sample.background)
            for i in out.shapes.indices {
                out.shapes[i].cornerRadius = 0
                let r = out.shapes[i].rect
                out.image = out.image.pasting(RGBAImage(width: r.width, height: r.height, fill: out.shapes[i].color),
                                              at: PixelPoint(x: r.minX, y: r.minY))
            }
            return out
        }
    }
}
