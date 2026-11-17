import Foundation
import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 素材校验的缺陷注入测试（任务 7.2，design.md Property 18）。
///
/// 先按每个 Asset_Key 的规则直接合成一张满足全部校验规则的图（不经过 Post_Processor，
/// 避免把后处理的缺陷混进校验器的结论），再从适用缺陷中随机选取子集注入，
/// 断言 `AssetValidator.validate` 报告的规则集合恰好等于所注入缺陷对应的规则集合。
@Suite struct AssetValidatorDefectTests {

    // Feature: 美术, Property 18: 校验器恰好报告注入的缺陷
    // **Validates: Requirements 6.2, 6.3, 6.4, 6.5, 6.6, 6.7**
    @Test func reportsExactlyInjectedFrameDefects() async {
        await propertyCheck(count: 300, input: Gen<DefectSample>.defectSample()) { sample in
            let verdict = AssetValidator.validate(key: sample.key, decoded: sample.decoded)
            #expect(verdict == sample.expected, "\(sample)")
        }
    }

    // Feature: 美术, Property 18: 校验器恰好报告注入的缺陷（文件不能解码时只报「文件格式」）
    // **Validates: Requirements 6.2**
    @Test func undecodableFileReportsOnlyFileFormat() async {
        await propertyCheck(count: 100, input: Gen<Int>.int(in: 0...(AssetCatalog.all.count - 1))) { index in
            let key = AssetCatalog.all[index].key
            #expect(AssetValidator.validate(key: key, decoded: nil) == .fail([.fileFormat], emptyFrames: []),
                    "\(key)")
        }
    }

    // Feature: 美术, Property 18: 校验器恰好报告注入的缺陷（尺寸不符时只报「像素尺寸」和可能的「alpha 通道」）
    // **Validates: Requirements 6.2**
    @Test func wrongSizeReportsNoFrameLevelRules() async {
        await propertyCheck(count: 200, input: Gen<WrongSizeSample>.wrongSizeSample()) { sample in
            let verdict = AssetValidator.validate(key: sample.key, decoded: sample.decoded)
            let expected: [ValidationRule] = sample.decoded.hasAlpha ? [.pixelSize] : [.pixelSize, .alphaChannel]
            #expect(verdict == .fail(expected, emptyFrames: []), "\(sample)")
        }
    }

    // MARK: - 示例

    /// 不注入任何缺陷时，45 个键的合成图都通过校验（生成器的前提）。
    @Test func compliantBaseImagesPassForEveryKey() {
        var seed = 0x2545_F491
        for spec in AssetCatalog.all {
            for _ in 0..<5 {
                let entropy = (0..<DefectSample.entropyCount).map { _ -> Int in
                    seed = (seed &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
                    return seed & 0xFF_FFFF
                }
                let sample = DefectSample.build(key: spec.key, entropy: entropy, allowDefects: false)
                #expect(AssetValidator.validate(key: spec.key, decoded: sample.decoded) == .pass, "\(sample)")
            }
        }
    }

    @Test func emptyFrameIndexIsOneBased() {
        let spec = AssetCatalog.residentSpec(.a, .walking)
        let fw = spec.expectedPixelWidth / spec.frames, fh = spec.expectedPixelHeight
        var image = RGBAImage(width: spec.expectedPixelWidth, height: fh)
        for i in [0, 1, 3, 4] {  // 第 3、6 帧为空
            for y in (fh - 10)..<fh {
                for x in (i * fw + 28)..<(i * fw + 36 + i) { image[x, y] = RGBA(r: 200, g: UInt8(i * 40), b: 9, a: 255) }
            }
        }
        let verdict = AssetValidator.validate(key: spec.key, decoded: DecodedPNG(image: image, hasAlpha: true))
        #expect(verdict == .fail([.emptyFrame], emptyFrames: [3, 6]))
    }
}

// MARK: - 随机数游标

/// 依次取用一组随机整数；用完后从头循环。
fileprivate struct EntropyCursor {
    var values: [Int]
    var index = 0

    init(_ values: [Int]) { self.values = values.isEmpty ? [0] : values }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let v = abs(values[index % values.count])
        index += 1
        return range.lowerBound + v % range.count
    }

    mutating func bool() -> Bool { int(0...1) == 1 }

    mutating func byte() -> UInt8 { UInt8(int(0...255)) }
}

// MARK: - 缺陷

/// 可注入的缺陷（design.md Property 18 列出的集合）。
fileprivate enum Defect: String, CaseIterable, Hashable, Sendable {
    case cornerPixel = "四角放 alpha=1 像素"
    case raised = "全部帧上移 ≥ 3"
    case offCenter = "全部帧横移 ≥ 7"
    case emptyFrame = "清空一帧"
    case duplicateFirst = "所有帧复制为第 1 帧"
    case seam = "改动接缝边"
    case noAlpha = "去掉 alpha 通道"

    var rule: ValidationRule {
        switch self {
        case .cornerPixel: return .cornersTransparent
        case .raised: return .grounded
        case .offCenter: return .centered
        case .emptyFrame: return .emptyFrame
        case .duplicateFirst: return .identicalFrames
        case .seam: return .tileEdge
        case .noAlpha: return .alphaChannel
        }
    }

    /// 适用于该键的缺陷。
    static func applicable(_ rules: AssetRules) -> [Defect] {
        allCases.filter { d in
            switch d {
            case .cornerPixel: return rules.isFramed
            case .raised, .offCenter: return rules.isGrounded
            case .emptyFrame, .noAlpha: return true
            case .duplicateFirst: return rules.spec.frames > 1
            case .seam: if case .tile = rules.alignment { return true } else { return false }
            }
        }
    }
}

// MARK: - 缺陷样本

/// 一张合规合成图注入缺陷后的结果与期望结论。
fileprivate struct DefectSample: Sendable, CustomStringConvertible {
    var key: String
    var decoded: DecodedPNG
    var defects: [Defect]
    /// 被清空的帧序号，从 0 开始。
    var clearedFrame: Int?
    var notes: [String]

    var expected: AssetVerdict {
        if defects.isEmpty { return .pass }
        let failed = Set(defects.map(\.rule))
        return .fail(ValidationRule.allCases.filter(failed.contains),
                     emptyFrames: clearedFrame.map { [$0 + 1] } ?? [])
    }

    var description: String {
        "\(key) \(decoded.image.width)×\(decoded.image.height) 缺陷=[\(defects.map(\.rawValue).joined(separator: "、"))] "
            + notes.joined(separator: " ")
    }

    /// 横移、上移的最大像素数；合规图预留这么多空间，平移后内容不出帧、不碰四角。
    static let maxShift = 10
    static let entropyCount = 256

    /// 用一组随机整数确定地构造样本。`allowDefects` 为 false 时不注入缺陷。
    static func build(key: String, entropy: [Int], allowDefects: Bool = true) -> DefectSample {
        var e = EntropyCursor(entropy)
        guard let spec = AssetCatalog.spec(key), let rules = AssetRules.rules(for: key) else {
            preconditionFailure("未知 Asset_Key：\(key)")
        }
        let n = spec.frames
        let fw = spec.expectedPixelWidth / n, fh = spec.expectedPixelHeight
        let frames = FrameSlicer.frameRects(width: spec.expectedPixelWidth, height: fh, frames: n)
        var image = RGBAImage(width: spec.expectedPixelWidth, height: fh)
        var notes: [String] = []

        func fill(_ r: PixelRect, _ c: RGBA) {
            for y in r.minY..<r.maxY {
                for x in r.minX..<r.maxX { image[x, y] = c }
            }
        }
        /// 第 i 帧的颜色：G 通道落在互不相交的区间 [40i, 40i + 29]，各帧内容因此两两不同。
        func frameColor(_ i: Int) -> RGBA {
            RGBA(r: e.byte(), g: UInt8(40 * i + e.int(0...29)), b: e.byte(), a: 255)
        }
        func randomColor() -> RGBA { RGBA(r: e.byte(), g: e.byte(), b: e.byte(), a: 255) }

        // 1. 合规底图。
        switch rules.alignment {
        case .tile(let tiling):
            // 平铺：接缝方向上每行（plank）或每列（ladder）颜色一致，再在内部画一个随机矩形。
            let horizontal = tiling == .horizontal
            let lines = horizontal ? fh : fw
            var opaqueLines = (0..<lines).filter { _ in e.bool() }
            if opaqueLines.isEmpty { opaqueLines = [e.int(0...(lines - 1))] }
            for l in opaqueLines {
                let c = randomColor()
                fill(horizontal ? PixelRect(x: 0, y: l, width: fw, height: 1)
                                : PixelRect(x: l, y: 0, width: 1, height: fh), c)
            }
            if horizontal {
                let w = e.int(1...(fw - 2)), h = e.int(1...fh)
                fill(PixelRect(x: e.int(1...(fw - 1 - w)), y: e.int(0...(fh - h)), width: w, height: h), randomColor())
            } else {
                let w = e.int(1...fw), h = e.int(1...(fh - 2))
                fill(PixelRect(x: e.int(0...(fw - w)), y: e.int(1...(fh - 1 - h)), width: w, height: h), randomColor())
            }
            notes.append("平铺行/列=\(opaqueLines.count)")
        default:
            for (i, frame) in frames.enumerated() {
                if rules.isGrounded {
                    // 贴底（底部空隙 0 到 2）且水平居中（2 倍偏差 ≤ 1），左右各留 2 + maxShift 像素。
                    let w = e.int(3...(fw - 4 - 2 * maxShift))
                    let h = e.int(3...(fh - 2 - maxShift))
                    let gap = e.int(0...2)
                    fill(PixelRect(x: frame.minX + (fw - w) / 2, y: fh - gap - h, width: w, height: h), frameColor(i))
                    notes.append("#\(i + 1)[\(w)×\(h) gap\(gap)]")
                } else if rules.isFramed {
                    // 四边留 2 像素，四角保持透明。
                    let w = e.int(1...(fw - 4)), h = e.int(1...(fh - 4))
                    let r = PixelRect(x: frame.minX + e.int(2...(fw - 2 - w)), y: e.int(2...(fh - 2 - h)),
                                      width: w, height: h)
                    fill(r, frameColor(i))
                    notes.append("#\(i + 1)[\(r.x),\(r.y) \(w)×\(h)]")
                } else {
                    // toolbox：不要求四角透明，可能整帧不透明。
                    if e.int(0...2) == 0 {
                        fill(frame, randomColor())
                        notes.append("不透明背景")
                    }
                    let w = e.int(1...fw), h = e.int(1...fh)
                    fill(PixelRect(x: frame.minX + e.int(0...(fw - w)), y: e.int(0...(fh - h)), width: w, height: h),
                         frameColor(i))
                }
            }
        }

        // 2. 选取缺陷：「清空一帧」与「复制为第 1 帧」不同时选。
        var chosen = allowDefects ? Defect.applicable(rules).filter { _ in e.bool() } : []
        if chosen.contains(.emptyFrame) && chosen.contains(.duplicateFirst) {
            let dropped: Defect = e.bool() ? .emptyFrame : .duplicateFirst
            chosen.removeAll { $0 == dropped }
        }

        // 3. 注入。顺序：平移 → 清空 / 复制 → 接缝 → 四角像素。
        if chosen.contains(.raised) || chosen.contains(.offCenter) {
            let dy = chosen.contains(.raised) ? -e.int(3...maxShift) : 0
            let dx = chosen.contains(.offCenter) ? (e.bool() ? 1 : -1) * e.int(7...maxShift) : 0
            for frame in frames { image.translate(region: frame, dx: dx, dy: dy) }
            notes.append("平移(\(dx),\(dy))")
        }
        var cleared: Int?
        if chosen.contains(.emptyFrame) {
            let k = e.int(0...(n - 1))
            image.paste(RGBAImage(width: frames[k].width, height: fh), at: PixelPoint(x: frames[k].minX, y: 0))
            cleared = k
        }
        if chosen.contains(.duplicateFirst) {
            let first = image.crop(frames[0])
            for frame in frames.dropFirst() { image.paste(first, at: PixelPoint(x: frame.minX, y: 0)) }
        }
        if chosen.contains(.seam), case .tile(let tiling) = rules.alignment {
            // 新 alpha 与对边相差 ≥ 40 且 < 128：不改变是否含 Opaque_Pixel 的结论。
            func broken(_ other: RGBA) -> RGBA {
                RGBA(r: e.byte(), g: e.byte(), b: e.byte(), a: other.a >= 80 ? 0 : other.a + 40)
            }
            if tiling == .horizontal {
                let y = e.int(0...(fh - 1))
                image[0, y] = broken(image[fw - 1, y])
                notes.append("接缝行 \(y)")
            } else {
                let x = e.int(0...(fw - 1))
                image[x, 0] = broken(image[x, fh - 1])
                notes.append("接缝列 \(x)")
            }
        }
        if chosen.contains(.cornerPixel) {
            let corner = e.int(0...3), ox = e.int(0...1), oy = e.int(0...1)
            // 复制为第 1 帧时每帧都放，避免破坏「帧内容相同」。
            let targets = chosen.contains(.duplicateFirst) ? Array(frames) : [frames[e.int(0...(n - 1))]]
            let color = RGBA(r: e.byte(), g: e.byte(), b: e.byte(), a: 1)
            for frame in targets {
                let px = corner % 2 == 0 ? frame.minX + ox : frame.maxX - 1 - ox
                let py = corner < 2 ? oy : fh - 1 - oy
                image[px, py] = color
                notes.append("角像素(\(px),\(py))")
            }
        }
        if let cleared { notes.append("清空第 \(cleared + 1) 帧") }

        return DefectSample(key: key, decoded: DecodedPNG(image: image, hasAlpha: !chosen.contains(.noAlpha)),
                            defects: chosen, clearedFrame: cleared, notes: notes)
    }
}

// MARK: - 尺寸不符样本

/// 像素尺寸不等于 Expected_Pixel_Size 的图。内容为全透明或全不透明（若做帧级检查必然报
/// 「空帧」或「四角透明」），用于确认尺寸不符时不做帧级检查。
fileprivate struct WrongSizeSample: Sendable, CustomStringConvertible {
    var key: String
    var decoded: DecodedPNG
    var mode: String

    var description: String {
        "\(key) \(decoded.image.width)×\(decoded.image.height) \(mode) hasAlpha=\(decoded.hasAlpha)"
    }

    static func build(entropy: [Int]) -> WrongSizeSample {
        var e = EntropyCursor(entropy)
        let spec = AssetCatalog.all[e.int(0...(AssetCatalog.all.count - 1))]
        let n = spec.frames, fw = spec.expectedPixelWidth / n
        var width = spec.expectedPixelWidth, height = spec.expectedPixelHeight
        let mode: String
        switch e.int(0...3) {
        case 0:
            width = e.int(1...400); height = e.int(1...200)
            mode = "随机尺寸"
        case 1:
            height = max(1, height + (e.bool() ? 1 : -1) * e.int(1...8))
            mode = "高度不符"
        case 2:
            var delta = (e.bool() ? 1 : -1) * e.int(1...2)
            if n + delta < 1 { delta = 1 }
            width = fw * (n + delta)
            mode = "帧数不符"
        default:
            width += (e.bool() ? 1 : -1) * e.int(1...(fw - 1))
            mode = "宽度不是帧宽整数倍"
        }
        if AssetCatalog.validate(fileName: spec.fileName, pixelWidth: width, pixelHeight: height) {
            height += 1
        }
        let fill = e.bool() ? RGBA.clear : RGBA(r: e.byte(), g: e.byte(), b: e.byte(), a: 255)
        let image = RGBAImage(width: width, height: height, fill: fill)
        return WrongSizeSample(key: spec.key, decoded: DecodedPNG(image: image, hasAlpha: e.bool()),
                               mode: mode + (fill.a == 0 ? " 全透明" : " 全不透明"))
    }
}

// MARK: - 生成器

extension Gen where Value == DefectSample {
    fileprivate static func defectSample() -> Generator<DefectSample, some SendableSequenceType> {
        Gen<Int>.int(in: 0...0xFF_FFFF)
            .array(of: DefectSample.entropyCount + 1)
            .map { e in
                let key = AssetCatalog.all[e[0] % AssetCatalog.all.count].key
                return DefectSample.build(key: key, entropy: Array(e.dropFirst()))
            }
    }
}

extension Gen where Value == WrongSizeSample {
    fileprivate static func wrongSizeSample() -> Generator<WrongSizeSample, some SendableSequenceType> {
        Gen<Int>.int(in: 0...0xFF_FFFF).array(of: 16).map { WrongSizeSample.build(entropy: $0) }
    }
}
