import Foundation
import PropertyBased
import Testing
@testable import WindowfolkArtKit
import WindowfolkCore

/// 预览总览图布局的属性测试（任务 8.2）。
/// _Requirements: 7.3, 7.4, 7.5_

/// 一个 Asset_Key 在 verdicts 字典中的情形。
fileprivate enum KeyState: Sendable, CustomStringConvertible {
    case pass
    /// 字典中显式为 `.missing`。
    case missing
    /// 字典中没有这个键，应按「缺失」处理。
    case absent
    /// 未通过的规则（非空，顺序可能被打乱，用来检查标记文字按 allCases 排序）。
    case fail([ValidationRule])

    var description: String {
        switch self {
        case .pass: return "pass"
        case .missing: return "missing"
        case .absent: return "absent"
        case .fail(let rules): return "fail(\(rules.map(\.rawValue)))"
        }
    }
}

fileprivate struct LayoutCase: Sendable, CustomStringConvertible {
    var states: [KeyState]            // 与 AssetCatalog.all 一一对应
    var verdicts: [String: AssetVerdict]

    var description: String {
        zip(AssetCatalog.all, states).map { "\($0.key)=\($1)" }.joined(separator: ", ")
    }
}

/// 居民素材键：两位居民 × 全部状态，独立于 PreviewLayout.scales 构造。
fileprivate let residentKeys: Set<String> = Set(ResidentID.allCases.flatMap { id in
    ResidentState.allCases.map { AssetCatalog.residentKey(id, $0) }
})

fileprivate let failGen = zip(
    Gen<Int>.int(in: 1...((1 << ValidationRule.allCases.count) - 1)),
    Gen<Int>.int(in: 0...Int.max)
).map { mask, seed -> KeyState in
    var rules = ValidationRule.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
    var rng = SplitMix(seed: UInt64(seed))
    rules.shuffle(using: &rng)
    return .fail(rules)
}

fileprivate let keyStateGen = zip(Gen<Int>.int(in: 0...3), failGen).map { kind, fail -> KeyState in
    switch kind {
    case 0: return .pass
    case 1: return .missing
    case 2: return .absent
    default: return fail
    }
}

fileprivate let layoutCaseGen = zip(
    keyStateGen.array(of: AssetCatalog.all.count),
    Gen<Int>.int(in: 0...3),               // 0：全部正常；1：全部缺失（字典为空）；其余：随机
    Gen<Bool>.bool                          // 是否加入不属于 Asset_Catalog 的键
).map { raw, mode, stray -> LayoutCase in
    let states: [KeyState]
    switch mode {
    case 0: states = Array(repeating: .pass, count: raw.count)
    case 1: states = Array(repeating: .absent, count: raw.count)
    default: states = raw
    }
    var verdicts: [String: AssetVerdict] = [:]
    for (spec, s) in zip(AssetCatalog.all, states) {
        switch s {
        case .pass: verdicts[spec.key] = .pass
        case .missing: verdicts[spec.key] = .missing
        case .absent: break
        case .fail(let rules): verdicts[spec.key] = .fail(rules, emptyFrames: rules.contains(.emptyFrame) ? [1] : [])
        }
    }
    if stray { verdicts["zz~not_a_key"] = .missing }
    return LayoutCase(states: states, verdicts: verdicts)
}

/// 确定性的打乱用随机数。
fileprivate struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

fileprivate func inside(_ r: PixelRect, _ canvas: PixelSize) -> Bool {
    r.minX >= 0 && r.minY >= 0 && r.maxX <= canvas.width && r.maxY <= canvas.height && !r.isEmpty
}

@Suite struct PreviewLayoutTests {

    // Feature: 美术, Property 22: 预览布局
    /// **Validates: Requirements 7.3, 7.4, 7.5**
    @Test func layoutFollowsCatalogAndMarksDefects() async {
        let baseline = PreviewLayout.make()
        await propertyCheck(count: 200, input: layoutCaseGen) { c in
            let layout = PreviewLayout.make(verdicts: c.verdicts)

            // R7.3：按 Asset_Catalog 顺序恰好 45 行，自上而下互不重叠；画布不随 verdicts 变化。
            #expect(layout.rows.map(\.key) == AssetCatalog.all.map(\.key), "\(c)")
            #expect(layout.canvas == baseline.canvas, "\(c)")
            for (upper, lower) in zip(layout.rows, layout.rows.dropFirst()) {
                #expect(upper.bounds.maxY <= lower.bounds.minY, "\(upper.key) / \(lower.key)")
            }

            // 全图所有帧矩形与标记矩形，用于检查标签不与任何一个相交。
            let contentRects = layout.rows.flatMap { row in
                row.strips.flatMap(\.frameRects) + (row.marker.map { [$0.rect] } ?? [])
            }

            for (row, (spec, state)) in zip(layout.rows, zip(AssetCatalog.all, c.states)) {
                // R7.3：标签高度 ≥ 10，在画布内，不与任何帧或标记相交。
                #expect(row.labelRect.height >= 10, "\(row.key)")
                #expect(row.labelOrigin == PixelPoint(x: row.labelRect.x, y: row.labelRect.y), "\(row.key)")
                #expect(inside(row.labelRect, layout.canvas), "\(row.key)")
                #expect(contentRects.allSatisfy { $0.intersection(row.labelRect) == nil }, "\(row.key) \(state)")

                let isResident = residentKeys.contains(spec.key)
                switch state {
                case .pass:
                    // R7.5：居民有比例 2 与比例 1 两条，其余只有比例 2。
                    #expect(row.marker == nil, "\(row.key)")
                    #expect(row.strips.map(\.scale) == (isResident ? [2, 1] : [2]), "\(row.key)")
                    for strip in row.strips {
                        let expected = strip.scale == 2
                            ? PixelSize(width: spec.expectedPixelWidth / spec.frames, height: spec.expectedPixelHeight)
                            : PixelSize(width: Int(spec.size.width.rounded()), height: Int(spec.size.height.rounded()))
                        #expect(strip.frameRects.count == spec.frames, "\(row.key) ×\(strip.scale)")
                        #expect(strip.frameRects.allSatisfy {
                            PixelSize(width: $0.width, height: $0.height) == expected && inside($0, layout.canvas)
                        }, "\(row.key) ×\(strip.scale)")
                    }
                    // R7.3：同一行相邻帧矩形（含两条之间）水平间隔 ≥ 4。
                    let frames = row.strips.flatMap(\.frameRects).sorted { $0.minX < $1.minX }
                    for (a, b) in zip(frames, frames.dropFirst()) {
                        #expect(b.minX - a.maxX >= 4, "\(row.key) \(a) \(b)")
                    }

                case .missing, .absent, .fail:
                    // R7.4：只画一个 Expected_Pixel_Size 大小的标记，不画帧条。
                    #expect(row.strips.isEmpty, "\(row.key) \(state)")
                    guard let marker = row.marker else {
                        Issue.record("\(row.key) \(state) 没有标记")
                        continue
                    }
                    #expect(marker.rect.width == spec.expectedPixelWidth, "\(row.key)")
                    #expect(marker.rect.height == spec.expectedPixelHeight, "\(row.key)")
                    #expect(inside(marker.rect, layout.canvas), "\(row.key)")
                    // 标记文字区可以超出标记框，但须在画布内、不压到标签。
                    #expect(inside(marker.textRect, layout.canvas), "\(row.key) \(marker.textRect)")
                    #expect(marker.textRect.intersection(row.labelRect) == nil, "\(row.key)")

                    if case .fail(let rules) = state {
                        let text = ValidationRule.allCases.filter { rules.contains($0) }.map(\.rawValue)
                            .joined(separator: "、")
                        #expect(marker.kind == .invalid(rules), "\(row.key)")
                        #expect(marker.text == text, "\(row.key) \(state)")
                    } else {
                        #expect(marker.kind == .missing, "\(row.key) \(state)")
                        #expect(marker.text == "缺失", "\(row.key) \(state)")
                    }
                }
            }
        }
    }

    @Test func allPassLayoutHasNoMarkers() {
        let layout = PreviewLayout.make()
        #expect(layout.rows.count == 45)
        #expect(layout.rows.allSatisfy { $0.marker == nil && !$0.strips.isEmpty })
        #expect(layout.rows.filter { $0.strips.count == 2 }.map(\.key).sorted() == residentKeys.sorted())
    }

    @Test func emptyVerdictsMarkEveryKeyMissing() {
        let layout = PreviewLayout.make(verdicts: [:])
        #expect(layout.rows.allSatisfy { $0.strips.isEmpty && $0.marker?.text == "缺失" })
    }

    @Test func markerTextOrdersRulesByCatalog() {
        #expect(PreviewLayout.markerText(.invalid([.tileEdge, .fileFormat, .grounded])) == "文件格式、贴底、平铺边缘")
        #expect(PreviewLayout.markerText(.missing) == "缺失")
    }

    @Test func themeBackgroundsAreSolidDarkAndLight() {
        #expect(PreviewTheme.dark.background == RGBA(r: 32, g: 32, b: 36, a: 255))
        #expect(PreviewTheme.light.background == RGBA(r: 232, g: 232, b: 228, a: 255))
        let dark = PreviewTheme.dark.background, light = PreviewTheme.light.background
        #expect(max(dark.r, dark.g, dark.b) <= 48)
        #expect(min(light.r, light.g, light.b) >= 208)
    }
}
