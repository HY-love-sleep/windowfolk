import Foundation
import PropertyBased
import Testing
import WindowfolkArtKit

/// Redactor 纯函数部分的属性测试（任务 5.6）。端到端（FakeTransport 回显 Key）部分另见 IO 层测试。
/// _Requirements: 3.10_

/// Key 常用字符：OpenAI Key 由字母、数字、`-`、`_` 组成。
fileprivate let keyAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

/// 噪声文本字符：含空白、标点、中文、掩码字符，以及组成 `[REDACTED]` / `[--]` 的字符，
/// 使替换标记与相邻字符有机会拼出新的 Key 片段。
fileprivate let noiseAlphabet = Array(
    "abcdefgsk-_*•…[]REDACT0123456789 \n\t:.,\"'{}()/=你好错误密钥"
)

/// 文本中的一段：噪声、完整 Key、Key 的连续片段（≥ 6 字符），或 `sk-前缀***后缀` 形式的掩码。
fileprivate enum Piece: Sendable {
    case noise(String)
    case fullKey
    case fragment(start: Int, length: Int)
    case mask(prefix: Int, suffix: Int)
}

fileprivate struct RedactCase: Sendable, CustomStringConvertible {
    var key: String
    var text: String

    var description: String { "key=\(key.debugDescription) text=\(text.debugDescription)" }
}

fileprivate func string(from indices: [Int], alphabet: [Character]) -> String {
    String(indices.map { alphabet[$0 % alphabet.count] })
}

fileprivate let keyGen = zip(
    Gen<Int>.int(in: 0...(keyAlphabet.count - 1)).array(of: 8...40),
    // 约 1/4 的 Key 在随机位置嵌入 `[REDACTED]` 的一段（≥ 6 字符），覆盖 `[--]` 分支。
    Gen<Int>.int(in: 0...3),
    Gen<Int>.int(in: 0...40),
    Gen<Int>.int(in: 0...4),
    Gen<Int>.int(in: 6...10)
).map { indices, embed, position, start, length -> String in
    var chars = Array(string(from: indices, alphabet: keyAlphabet))
    if embed == 0 {
        let placeholder = Array(Redactor.placeholder)
        let s = min(start, placeholder.count - 6)
        let l = min(length, placeholder.count - s)
        chars.insert(contentsOf: placeholder[s..<(s + l)], at: position % (chars.count + 1))
    }
    return String(chars)
}

fileprivate let pieceGen = zip(
    Gen<Int>.int(in: 0...3),
    Gen<Int>.int(in: 0...(noiseAlphabet.count - 1)).array(of: 0...12),
    Gen<Int>.int(in: 0...200),
    Gen<Int>.int(in: 0...200)
).map { kind, noise, a, b -> Piece in
    switch kind {
    case 0: return .noise(string(from: noise, alphabet: noiseAlphabet))
    case 1: return .fullKey
    case 2: return .fragment(start: a, length: b)
    default: return .mask(prefix: a, suffix: b)
    }
}

fileprivate func render(_ piece: Piece, key: String) -> String {
    let chars = Array(key)
    switch piece {
    case .noise(let s):
        return s
    case .fullKey:
        return key
    case .fragment(let a, let b):
        let length = 6 + b % (chars.count - 5)          // 6...count
        let start = a % (chars.count - length + 1)
        return String(chars[start..<(start + length)])
    case .mask(let a, let b):
        // 形如 OpenAI 回显的 `sk-abc***wxyz`：Key 的头部和尾部，中间用星号。
        let prefix = String(chars.prefix(a % (chars.count + 1)))
        let suffix = String(chars.suffix(b % (chars.count + 1)))
        return "sk-" + prefix + "***" + suffix
    }
}

fileprivate let caseGen = zip(keyGen, pieceGen.array(of: 0...8)).map { key, pieces in
    RedactCase(key: key, text: pieces.map { render($0, key: key) }.joined())
}

/// Key 的全部长度为 6 的连续片段；任何更长的片段都包含其中之一。
fileprivate func windows(of key: String) -> Set<String> {
    let chars = Array(key)
    guard chars.count >= Redactor.minimumFragmentLength else { return [] }
    return Set((0...(chars.count - Redactor.minimumFragmentLength)).map {
        String(chars[$0..<($0 + Redactor.minimumFragmentLength)])
    })
}

/// 结果中第一个出现的 Key 片段（逐字符比较，与 Redactor 的匹配方式一致）。
fileprivate func leakedFragment(in result: String, key: String) -> String? {
    let all = windows(of: key)
    let chars = Array(result)
    let n = Redactor.minimumFragmentLength
    guard chars.count >= n else { return nil }
    for start in 0...(chars.count - n) {
        let window = String(chars[start..<(start + n)])
        if all.contains(window) { return window }
    }
    return nil
}

@Suite struct RedactorTests {

    // Feature: 美术, Property 7: Key 不泄露
    /// **Validates: Requirements 3.10**
    @Test func redactedTextContainsNoKeyFragment() async {
        await propertyCheck(count: 200, input: caseGen) { c in
            let result = Redactor.redact(c.text, secret: c.key)
            let leaked = leakedFragment(in: result, key: c.key)
            #expect(leaked == nil, "\(c) → \(result.debugDescription) 泄露 \(leaked ?? "")")
        }
    }
}
