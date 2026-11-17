import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 非 Grounded 居民所有帧共用一个平移量，保留帧间相对位移（R4.15，任务 6.10）。
///
/// 检查：
/// - 任意两帧不透明边界框左上角的位移等于原始图（帧格坐标）中对应位移乘以 `s`，每轴 ±1 像素。
///   `s` 取每轴实际生效的比例：帧并集 `U` 按 `min(fw / U.w, fh / U.h)` 缩放后四舍五入到整数边长，
///   该轴比例为「缩放后边长 / U 的边长」，差别属于取整误差。
/// - 全部帧并集的最下方不透明行距底边不超过 2 像素，水平中心与帧中心相差不超过 1 像素。
///
/// 居民素材是 Framed_Asset，四角 2×2 清理（R4.14）可能削掉伸进角区的像素，
/// 边界框在该侧可能少最多 `cornerSize` 像素；判断时按区间放宽（与任务 6.7 相同的做法）。
/// 生成器用直角矩形：圆角矩形最外一行经最近邻缩小可能整段丢失，和平移无关。
@Suite struct PostProcessorNonGroundedTests {

    // Feature: 美术, Property 14: 非 Grounded 居民保留帧间位移
    // **Validates: Requirements 4.15**
    @Test func nonGroundedFramesShareOneTranslation() async {
        await propertyCheck(count: 120, input: Gen<RawImageSample>.rectangularRawImage(among: nonGroundedKeys)) { sample in
            checkUniformTranslation(sample)
        }
    }

    // MARK: - 示例

    /// `planting` 跳起：同尺寸方块，一帧比其余帧高 10 像素；输出中该帧仍高出 10·s 像素，并集贴底居中。
    @Test func jumpFrameKeepsItsHeightAboveGround() throws {
        let key = AssetCatalog.residentKey(.a, .planting)
        let rules = try #require(AssetRules.rules(for: key))
        #expect(rules.alignment == .nonGroundedUniform)
        let n = rules.spec.frames
        let fw = rules.spec.expectedPixelWidth / n, fh = rules.spec.expectedPixelHeight
        let cell = 40, height = 40
        let color = RGBA(r: 60, g: 140, b: 60, a: 255)
        var raw = RGBAImage(width: cell * n, height: height)
        for i in 0..<n {
            let y = i == 1 ? 10 : 20  // 第 2 帧跳起 10 像素。
            raw = raw.pasting(RGBAImage(width: 16, height: 10, fill: color), at: PixelPoint(x: i * cell + 12, y: y))
        }
        let outcome = try PostProcessor.process(raw, key: key, resampler: NearestResampler()).get()
        let boxes = try FrameSlicer.slice(outcome.image, frames: n).map { try #require($0.opaqueBounds()) }

        // 并集 16×20：s = min(fw / 16, fh / 20)。
        let s = min(Double(fw) / 16, Double(fh) / 20)
        let lift = Double(boxes[0].minY - boxes[1].minY)
        #expect(abs(lift - 10 * s) <= 1, "跳起高度 \(lift)，期望 \(10 * s)，边界框 \(boxes)")
        for i in boxes.indices where i != 1 {
            #expect(boxes[i].minY == boxes[0].minY && boxes[i].minX == boxes[0].minX, "\(boxes)")
        }
        let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        #expect(fh - union.maxY <= PostProcessor.bottomTolerance, "并集 \(union)")
        #expect(abs(union.minX + union.maxX - fw) <= 2 * PostProcessor.centerTolerance, "并集 \(union)")
    }

    // MARK: - 检查

    private var nonGroundedKeys: [String] {
        AssetRules.all.filter { $0.alignment == .nonGroundedUniform }.map(\.spec.key)
    }

    private func checkUniformTranslation(_ sample: RawImageSample, sourceLocation: SourceLocation = #_sourceLocation) {
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

        var measured: [CornerSlackBox] = []
        for (i, frame) in FrameSlicer.slice(outcome.image, frames: n).enumerated() {
            guard let box = frame.opaqueBounds() else {
                Issue.record("\(sample)：输出第 \(i + 1) 帧为空", sourceLocation: sourceLocation)
                return
            }
            measured.append(CornerSlackBox(box: box, fw: fw, fh: fh, framed: rules.isFramed))
        }
        let detail = "\(sample) → 输出边界框 "
            + measured.map { "[\($0.box.x),\($0.box.y) \($0.box.width)×\($0.box.height)]" }.joined(separator: " ")

        // 原始帧边界框（帧格坐标）即图形外接矩形；并集 U 与每轴实际比例。
        let rawBoxes = sample.shapes.enumerated().map { i, s in s.rect.offsetBy(dx: -sample.cellRect(i).minX, dy: 0) }
        let rawUnion = rawBoxes.dropFirst().reduce(rawBoxes[0]) { $0.union($1) }
        let s = min(Double(fw) / Double(rawUnion.width), Double(fh) / Double(rawUnion.height))
        let sx = Double(min(fw, max(1, Int((Double(rawUnion.width) * s).rounded())))) / Double(rawUnion.width)
        let sy = Double(min(fh, max(1, Int((Double(rawUnion.height) * s).rounded())))) / Double(rawUnion.height)

        // 任意两帧左上角位移 = 原始位移 × s（每轴 ±1）。真实左边在 [minX − slackLeft, minX]，上边同理。
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                let a = measured[i], b = measured[j]
                let expectedDX = Double(rawBoxes[i].minX - rawBoxes[j].minX) * sx
                let expectedDY = Double(rawBoxes[i].minY - rawBoxes[j].minY) * sy
                let dxOK = overlaps(lo: a.box.minX - a.slackLeft - b.box.minX, hi: a.box.minX - b.box.minX + b.slackLeft,
                                    expected: expectedDX)
                let dyOK = overlaps(lo: a.box.minY - a.slackTop - b.box.minY, hi: a.box.minY - b.box.minY + b.slackTop,
                                    expected: expectedDY)
                #expect(dxOK, "第 \(i + 1)、\(j + 1) 帧水平位移应为 \(expectedDX)（±1）：\(detail)",
                        sourceLocation: sourceLocation)
                #expect(dyOK, "第 \(i + 1)、\(j + 1) 帧竖直位移应为 \(expectedDY)（±1）：\(detail)",
                        sourceLocation: sourceLocation)
            }
        }

        // 并集贴底、水平居中。
        let unionBox = measured.dropFirst().reduce(measured[0].box) { $0.union($1.box) }
        let union = CornerSlackBox(box: unionBox, fw: fw, fh: fh, framed: rules.isFramed)
        let gap = fh - union.box.maxY
        #expect(union.box.maxY <= fh && gap - union.slackBottom <= PostProcessor.bottomTolerance,
                "并集 \(union.box) 未贴底（帧高 \(fh)）：\(detail)", sourceLocation: sourceLocation)
        // 两倍坐标：真实 minX + maxX 落在 [和 − slackLeft, 和 + slackRight]，与 fw 相差 ≤ 2。
        let sum = union.box.minX + union.box.maxX
        let centered = overlaps(lo: sum - union.slackLeft, hi: sum + union.slackRight, expected: Double(fw),
                                tolerance: Double(2 * PostProcessor.centerTolerance))
        #expect(centered, "并集 \(union.box) 未水平居中（帧宽 \(fw)）：\(detail)", sourceLocation: sourceLocation)
    }

    /// 整数区间 `[lo, hi]` 与 `[expected − tolerance, expected + tolerance]` 是否相交。
    private func overlaps(lo: Int, hi: Int, expected: Double, tolerance: Double = 1) -> Bool {
        Double(lo) <= expected + tolerance + 1e-9 && Double(hi) >= expected - tolerance - 1e-9
    }
}

/// 输出帧的不透明边界框，以及 Framed_Asset 四角清理（R4.14）可能裁掉的边长。
///
/// 内容伸进 2×2 角区时，清理会让边界框在该侧缩进到恰好 `cornerSize`；
/// 此时原本的边可能在 0 到 `cornerSize` 之间，该侧记为最多少了 `cornerSize` 像素。
fileprivate struct CornerSlackBox {
    var box: PixelRect
    var slackLeft = 0, slackRight = 0, slackTop = 0, slackBottom = 0

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
    /// 和平移无关。直角矩形缩放后的边界框只剩取整误差。
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
