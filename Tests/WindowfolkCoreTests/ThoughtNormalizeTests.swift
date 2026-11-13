import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// Thought 文本规整的属性测试（design.md Property 37，任务 12.8）。
//
// 参考判定不调用被测实现：按 Unicode 标量逐个处理，连续的 `\r`/`\n` 标量合成一个空格，
// 再用 Unicode `White_Space` 属性去掉首尾空白标量；之后按字素取前 maxLength 个，再去尾部空白字素。

// MARK: - 生成器

/// 换行段：单个或连续的 `\r`、`\n`、`\r\n`（`\r\n` 在 Swift 中是一个 Character）。
fileprivate let thoughtNewlines: [String] = ["\n", "\r", "\r\n", "\n\n", "\r\n\r\n", "\n\r", "\r\r\n\n"]

/// 不含 `\r`/`\n` 的空白：ASCII 空格、制表符、不换行空格、全角空格、em 空格、行/段分隔符。
fileprivate let thoughtSpaces: [String] = [" ", "  ", "\t", "\u{00A0}", "\u{3000}", "\u{2003}", "\u{2028}", "\u{2029}"]

/// 可见字素：ASCII、CJK、日文、组合字符（预组合与「字母 + 组合符」两种写法）、emoji（含 ZWJ 序列、肤色、国旗）。
fileprivate let thoughtVisible: [String] = [
    "a", "Z", "7", ".", "!", "嘟", "都", "窗", "家", "。", "あ", "カ",
    "é", "e\u{0301}", "n\u{0303}", "a\u{0308}\u{0323}",
    "🐹", "🌙", "👨‍👩‍👧", "👍🏽", "🇨🇳", "❤️",
]

/// 一段 LLM 返回文本：由可见字素、空白和换行段拼接而成。可见字素权重更高，使截断经常发生。
fileprivate var thoughtRaw: Generator<String, some SendableSequenceType> {
    let pool = thoughtVisible + thoughtVisible + thoughtVisible + thoughtSpaces + thoughtNewlines
    return Gen<String?>.element(of: pool).map { $0! }.array(of: 0...40).map { $0.joined() }
}

fileprivate struct ThoughtInput: Sendable, CustomStringConvertible {
    var raw: String
    var maxLength: Int
    var description: String { "raw \(raw.debugDescription) maxLength \(maxLength)" }
}

fileprivate var thoughtInput: Generator<ThoughtInput, some SendableSequenceType> {
    zip(thoughtRaw, Gen<Int>.int(in: 0...30)).map { ThoughtInput(raw: $0, maxLength: $1) }
}

// MARK: - 参考判定

/// 每段连续 `\r`/`\n` 标量换成一个空格，再去掉首尾 `White_Space` 标量。
fileprivate func referenceCollapsed(_ raw: String) -> String {
    var out = String.UnicodeScalarView()
    var inBreak = false
    for s in raw.unicodeScalars {
        if s == "\r" || s == "\n" {
            if !inBreak { out.append(" ") }
            inBreak = true
        } else {
            out.append(s)
            inBreak = false
        }
    }
    var scalars = Array(out)
    while let f = scalars.first, f.properties.isWhitespace { scalars.removeFirst() }
    while let l = scalars.last, l.properties.isWhitespace { scalars.removeLast() }
    var v = String.UnicodeScalarView()
    v.append(contentsOf: scalars)
    return String(v)
}

fileprivate func isBlank(_ c: Character) -> Bool {
    c.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
}

fileprivate func referenceNormalize(_ raw: String, maxLength: Int) -> String? {
    var chars = Array(referenceCollapsed(raw)).prefix(max(0, maxLength))
    while let l = chars.last, isBlank(l) { chars.removeLast() }
    return chars.isEmpty ? nil : String(chars)
}

// MARK: - 属性测试

@Suite struct ThoughtNormalizePropertyTests {
    // Feature: V2, Property 37: Thought 文本规整
    // **Validates: Requirements 14.2, 14.7**
    @Test func normalizeProducesSingleLineTrimmedBoundedPrefix() async {
        await propertyCheck(count: 300, input: thoughtInput) { t in
            let result = ThoughtEngine.normalize(t.raw, maxLength: t.maxLength)
            let collapsed = referenceCollapsed(t.raw)
            #expect(result == referenceNormalize(t.raw, maxLength: t.maxLength), "\(t)")

            guard let text = result else {
                // 只有规整后为空或 maxLength 为 0 时才为 nil。
                #expect(collapsed.isEmpty || t.maxLength == 0, "\(t)")
                return
            }
            #expect(!text.isEmpty, "\(t)")
            #expect(!text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }, "不含换行：\(t)")
            #expect(text.count <= t.maxLength, "字素数不超过上限：\(t)")
            #expect(!isBlank(text.first!) && !isBlank(text.last!), "首尾无空白：\(t)")
            #expect(collapsed.hasPrefix(text), "是规整串的前缀：\(t)")
            if collapsed.count <= t.maxLength {
                #expect(text == collapsed, "未超长时不截断：\(t)")
            }
        }
    }

    // Feature: V2, Property 37: Thought 文本规整（默认 Thought_Max_Length）
    // **Validates: Requirements 14.2, 14.7**
    @Test func normalizeRespectsDefaultMaxLength() async {
        let maxLength = Tunables().thoughtMaxLength
        await propertyCheck(count: 100, input: thoughtRaw) { raw in
            let result = ThoughtEngine.normalize(raw, maxLength: maxLength)
            #expect(result == referenceNormalize(raw, maxLength: maxLength), "raw \(raw.debugDescription)")
            if let text = result {
                #expect(text.count <= maxLength, "raw \(raw.debugDescription)")
                #expect(!text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }, "raw \(raw.debugDescription)")
            } else {
                #expect(referenceCollapsed(raw).isEmpty, "raw \(raw.debugDescription)")
            }
        }
    }
}
