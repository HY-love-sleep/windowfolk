import Foundation
import WindowfolkCore

/// 从任意文本中移除 API Key 的完整值、部分片段和 `sk-…` 形式的令牌（R3.10）。
///
/// OpenAI 在鉴权失败时会回显部分 Key（如 `sk-abc***wxyz`），所以只替换完整 Key 不够：
/// Key 的任一长度 ≥ 6 的连续片段都会被替换。所有命中的区域（含相互重叠或相邻的区域）
/// 合并后统一换成一个 `[REDACTED]`。
public enum Redactor {
    /// 统一的替换标记。
    public static let placeholder = "[REDACTED]"

    /// 被视为泄露的 Key 片段最小长度。
    public static let minimumFragmentLength = 6

    /// 替换完整 Key、Key 的任一长度 ≥ 6 的连续片段，以及形如 sk-… 的令牌，统一为 "[REDACTED]"。
    ///
    /// Key 短于 6 个字符时按完整 Key 匹配。替换后会对结果重新检查，
    /// 直到不再出现任何片段（防止替换标记与相邻字符拼出新的片段）。
    public static func redact(_ text: String, secret: String) -> String {
        let secretChars = Array(secret)
        let windowLength = min(minimumFragmentLength, secretChars.count)
        let windows = fragmentWindows(of: secretChars, length: windowLength)

        // 替换标记本身若含有 Key 片段，就换成短于片段长度的标记，保证循环能结束。
        let token = containsWindow(Array(placeholder), windows: windows, length: windowLength)
            ? "[--]"
            : placeholder
        let tokenChars = Array(token)

        var current = Array(text)
        // 每轮替换都会让「原字符数 + 标记数」严格减少，循环必然结束；上限只作保险。
        for _ in 0...(current.count + 1) {
            var ranges = fragmentRanges(in: current, windows: windows, length: windowLength)
            ranges.append(contentsOf: skTokenRanges(in: current))
            if ranges.isEmpty { break }
            current = replace(current, ranges: merge(ranges), with: tokenChars)
        }
        return String(current)
    }

    // MARK: - Key 片段

    private static func fragmentWindows(of secret: [Character], length: Int) -> Set<String> {
        guard length > 0, secret.count >= length else { return [] }
        var result = Set<String>()
        for start in 0...(secret.count - length) {
            result.insert(String(secret[start..<(start + length)]))
        }
        return result
    }

    private static func containsWindow(_ chars: [Character], windows: Set<String>, length: Int) -> Bool {
        !fragmentRanges(in: chars, windows: windows, length: length).isEmpty
    }

    /// 文本中所有与 Key 片段相同的长度为 `length` 的区间。任何更长的片段都由这些区间覆盖。
    private static func fragmentRanges(
        in chars: [Character], windows: Set<String>, length: Int
    ) -> [Range<Int>] {
        guard length > 0, !windows.isEmpty, chars.count >= length else { return [] }
        var result: [Range<Int>] = []
        for start in 0...(chars.count - length) {
            if windows.contains(String(chars[start..<(start + length)])) {
                result.append(start..<(start + length))
            }
        }
        return result
    }

    // MARK: - sk-… 令牌

    /// 形如 `sk-abc***wxyz`、`sk-proj-…` 的令牌：`sk-` 前不能紧跟字母数字（避免误伤 `task-`），
    /// 后面至少有一个令牌字符。
    private static func skTokenRanges(in chars: [Character]) -> [Range<Int>] {
        guard chars.count >= 4 else { return [] }
        var result: [Range<Int>] = []
        var index = 0
        while index + 3 < chars.count {
            let isStart = chars[index] == "s" && chars[index + 1] == "k" && chars[index + 2] == "-"
                && (index == 0 || !isWordCharacter(chars[index - 1]))
            guard isStart else {
                index += 1
                continue
            }
            var end = index + 3
            while end < chars.count, isTokenCharacter(chars[end]) {
                end += 1
            }
            if end > index + 3 {
                result.append(index..<end)
                index = end
            } else {
                index += 1
            }
        }
        return result
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let ascii = c.asciiValue else { return false }
        return (ascii >= 0x30 && ascii <= 0x39) || (ascii >= 0x41 && ascii <= 0x5A)
            || (ascii >= 0x61 && ascii <= 0x7A) || c == "_" || c == "-"
    }

    private static func isTokenCharacter(_ c: Character) -> Bool {
        isWordCharacter(c) || c == "*" || c == "•" || c == "…"
    }

    // MARK: - 合并与替换

    /// 合并重叠或相邻的区间，结果按起点升序。
    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<Int>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func replace(
        _ chars: [Character], ranges: [Range<Int>], with token: [Character]
    ) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(chars.count)
        var cursor = 0
        for range in ranges {
            result.append(contentsOf: chars[cursor..<range.lowerBound])
            result.append(contentsOf: token)
            cursor = range.upperBound
        }
        result.append(contentsOf: chars[cursor..<chars.count])
        return result
    }
}
