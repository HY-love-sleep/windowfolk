import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// Thought 气泡布局的属性测试（design.md Property 38，任务 12.12）。
//
// Core 坐标 y 向下：「在上方」即 maxY 不大于对方的 minY。参考判定只用常量和 Rect 字段，不调用被测函数互相印证。

// MARK: - 生成器

fileprivate struct LayoutCase: Sendable, CustomStringConvertible {
    var textWidth: Double
    var otherWidth: Double
    var head: Point
    var hasWish: Bool
    var description: String {
        "textWidth \(textWidth) otherWidth \(otherWidth) head (\(head.x), \(head.y)) hasWish \(hasWish)"
    }
}

/// 文字宽度：一半落在 [0, 图标气泡宽附近]，使下限经常生效；另一半覆盖较长的单行文字。
fileprivate var textWidthGen: Generator<Double, some SendableSequenceType> {
    zip(Gen<Bool>.bool, Gen<Double>.double(in: 0...16), Gen<Double>.double(in: 0...800))
        .map { small, a, b in small ? a : b }
}

fileprivate var layoutCase: Generator<LayoutCase, some SendableSequenceType> {
    zip(textWidthGen, textWidthGen, Gen<Double>.double(in: -200...3000), Gen<Double>.double(in: -200...2000),
        Gen<Bool>.bool)
        .map { LayoutCase(textWidth: $0, otherWidth: $1, head: Point(x: $2, y: $3), hasWish: $4) }
}

/// 同一字符类别的两条 Thought：每个字素宽 `glyph`，字素数 n、m 都不超过 Thought_Max_Length。
fileprivate struct GlyphCase: Sendable, CustomStringConvertible {
    var glyph: Double
    var n: Int
    var m: Int
    var description: String { "glyph \(glyph) n \(n) m \(m)" }
}

fileprivate var glyphCase: Generator<GlyphCase, some SendableSequenceType> {
    let maxLength = Tunables().thoughtMaxLength
    return zip(Gen<Double>.double(in: 1...32), Gen<Int>.int(in: 0...maxLength), Gen<Int>.int(in: 0...maxLength))
        .map { GlyphCase(glyph: $0, n: $1, m: $2) }
}

// MARK: - 参考判定

fileprivate func intersects(_ a: Rect, _ b: Rect) -> Bool {
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
}

// MARK: - 属性测试

@Suite struct ThoughtLayoutPropertyTests {
    // Feature: V2, Property 38: Thought 气泡布局
    // **Validates: Requirements 14.4, 16.7**
    @Test func thoughtBubbleWidthAndPlacement() async {
        let pad = ThoughtLayout.horizontalPadding
        let gap = ThoughtLayout.gap
        let icon = ThoughtLayout.iconBubble
        await propertyCheck(count: 300, input: layoutCase) { c in
            // 宽度公式、下限与可容纳文字。
            let width = ThoughtLayout.width(textWidth: c.textWidth)
            #expect(width == max(c.textWidth + 2 * pad, icon.width), "\(c)")
            #expect(width >= icon.width, "不窄于图标气泡：\(c)")
            #expect(width >= c.textWidth + 2 * pad, "文字放得下一行：\(c)")

            // 单调不减。
            let (lo, hi) = (min(c.textWidth, c.otherWidth), max(c.textWidth, c.otherWidth))
            #expect(ThoughtLayout.width(textWidth: lo) <= ThoughtLayout.width(textWidth: hi), "\(c)")

            // 位置：水平居中、高度同图标气泡、底边留 gap。
            let iconRect = ThoughtLayout.iconBubbleRect(headTop: c.head)
            let rect = ThoughtLayout.thoughtRect(textWidth: c.textWidth, headTop: c.head, hasWishBubble: c.hasWish)
            #expect(rect.width == width, "\(c)")
            #expect(rect.height == icon.height, "\(c)")
            #expect(abs(rect.midX - c.head.x) < 1e-9, "水平居中：\(c)")
            #expect(abs(iconRect.midX - c.head.x) < 1e-9, "\(c)")
            #expect(abs(iconRect.maxY - (c.head.y - gap)) < 1e-9, "图标气泡在头顶上方 gap：\(c)")

            if c.hasWish {
                #expect(!intersects(rect, iconRect), "与 Wish_Bubble 不相交：\(c)")
                #expect(rect.maxY <= iconRect.minY, "Thought 在 Wish_Bubble 上方：\(c)")
                #expect(abs(rect.maxY - (iconRect.minY - gap)) < 1e-9, "\(c)")
            } else {
                #expect(abs(rect.maxY - (c.head.y - gap)) < 1e-9, "无 Wish_Bubble 时贴着头顶：\(c)")
            }
            #expect(rect.maxY < c.head.y, "不压住头顶：\(c)")
        }
    }

    // Feature: V2, Property 38: Thought 气泡布局（字素数与 Thought_Max_Length）
    // **Validates: Requirements 14.4, 16.7**
    @Test func moreGraphemesNeverNarrowerAndMaxLengthFits() async {
        let pad = ThoughtLayout.horizontalPadding
        let maxLength = Tunables().thoughtMaxLength
        await propertyCheck(count: 200, input: glyphCase) { c in
            let (few, many) = (min(c.n, c.m), max(c.n, c.m))
            let wFew = ThoughtLayout.width(textWidth: Double(few) * c.glyph)
            let wMany = ThoughtLayout.width(textWidth: Double(many) * c.glyph)
            #expect(wFew <= wMany, "字素多的不更窄：\(c)")

            let fullText = Double(maxLength) * c.glyph
            // 按「文字宽 + 两侧内边距」比较，避免 (x + p) - p 的浮点舍入误差。
            #expect(ThoughtLayout.width(textWidth: fullText) >= fullText + 2 * pad, "Thought_Max_Length 个字素放得下：\(c)")
        }
    }

    // 边界：负数和 NaN 文字宽度按 0 计。
    @Test func invalidTextWidthTreatedAsZero() {
        let zero = ThoughtLayout.width(textWidth: 0)
        #expect(zero == max(2 * ThoughtLayout.horizontalPadding, ThoughtLayout.iconBubble.width))
        #expect(ThoughtLayout.width(textWidth: -50) == zero)
        #expect(ThoughtLayout.width(textWidth: .nan) == zero)
    }
}
