import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// MARK: - 生成器

/// `actor`、`target` 的取值池：两位居民、玩家、窗口、Decor、未知标识和 nil。
fileprivate let diaryTemplateRefs: [String?] = [
    "resident_a", "resident_b", "resident_a", "resident_b",
    "player", "app:Safari", "app:日记本", "decor:1", "resident_c", nil,
]

/// `wish_type`、`decor_type`、`chase_outcome` 的取值：合法值、非法值，或不出现（nil）。
fileprivate let diaryTemplateWishValues: [String?] = WishType.allCases.map(\.rawValue) + ["robot", nil]
fileprivate let diaryTemplateDecorValues: [String?] = DecorType.allCases.map(\.rawValue) + ["sofa", nil]
fileprivate let diaryTemplateOutcomeValues: [String?] = ["caught", "escaped", "tie", nil]

/// 自由文本（会放进 `detail.text` 和 `detail.app`），模板不应读取。
fileprivate var diaryTemplateFreeText: Generator<String, some SendableSequenceType> {
    zip(Gen<Bool>.bool, Gen.letterOrNumber.string(of: 0...8))
        .map { chinese, s in chinese ? "秘密" + s : s }
}

fileprivate func diaryTemplatePick<T: Sendable>(_ pool: [T]) -> Generator<T, some SendableSequenceType> {
    Gen<Int>.int(in: 0...(pool.count - 1)).map { pool[$0] }
}

fileprivate let diaryTemplateBase = Date(timeIntervalSince1970: 1_792_000_000)

fileprivate var diaryTemplateEvent: Generator<EventRecord, some SendableSequenceType> {
    zip(
        Gen<EventType>.case,
        diaryTemplatePick(diaryTemplateRefs),
        diaryTemplatePick(diaryTemplateRefs),
        diaryTemplatePick(diaryTemplateWishValues),
        diaryTemplatePick(diaryTemplateDecorValues),
        diaryTemplatePick(diaryTemplateOutcomeValues),
        diaryTemplateFreeText,
        Gen<Int>.int(in: 0...86_399)
    ).map { type, actor, target, wish, decor, outcome, text, offset in
        var detail: [String: String] = ["text": text, "app": text]
        detail["wish_type"] = wish
        detail["decor_type"] = decor
        detail["chase_outcome"] = outcome
        return EventRecord(
            time: diaryTemplateBase.addingTimeInterval(TimeInterval(offset)),
            type: type, actor: actor, target: target, detail: detail)
    }
}

fileprivate struct DiaryTemplateCase: Sendable {
    var writer: ResidentID
    var events: [EventRecord]
    var maxLength: Int
    /// 用于检验保序的切分点（按 `events.count` 取模）。
    var split: Int
}

fileprivate var diaryTemplateCase: Generator<DiaryTemplateCase, some SendableSequenceType> {
    zip(
        Gen<ResidentID>.case,
        diaryTemplateEvent.array(of: 0...16),
        Gen<Int>.int(in: 0...240),
        Gen<Int>.int(in: 0...1_000)
    ).map { writer, events, maxLength, split in
        DiaryTemplateCase(writer: writer, events: events, maxLength: maxLength, split: split)
    }
}

// MARK: - 属性测试

struct DiaryTemplateTests {
    private let day = LocalDate(year: 2026, month: 10, day: 21)
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    // Feature: V2, Property 41: 日记模板确定且保序
    // **Validates: Requirements 13.5, 22.8**
    @Test func templateDiaryIsDeterministicAndOrdered() async {
        await propertyCheck(count: 200, input: diaryTemplateCase) { c in
            let key = DiaryKey(date: day, resident: c.writer)
            let writer = DiaryWriter(client: nil, maxLength: c.maxLength)

            let first = await writer.write(key, events: c.events, config: nil, timeZone: shanghai)
            let second = await writer.write(key, events: c.events, config: nil, timeZone: shanghai)

            // 两次调用逐字符相同（String 的 == 按规范等价比较，这里再比 Unicode 标量）
            #expect(first == second)
            #expect(Array(first.text.unicodeScalars) == Array(second.text.unicodeScalars))

            // 等于逐条取非空句子后拼接、再截断到 Diary_Max_Length；生成方式为 template
            let joined = c.events.compactMap { DiaryTemplates.sentence(for: $0, writer: c.writer) }.joined()
            #expect(DiaryTemplates.text(writer: c.writer, events: c.events) == joined)
            #expect(first.text == String(joined.prefix(c.maxLength)))
            #expect(first.method == .template)
            #expect(first.date == day && first.resident == c.writer)

            // 保序：任意切分点处，整段的正文 = 前段正文 + 后段正文
            let cut = c.events.isEmpty ? 0 : c.split % (c.events.count + 1)
            let head = DiaryTemplates.text(writer: c.writer, events: Array(c.events[..<cut]))
            let tail = DiaryTemplates.text(writer: c.writer, events: Array(c.events[cut...]))
            #expect(head + tail == joined)

            for r in c.events {
                let s = DiaryTemplates.sentence(for: r, writer: c.writer)
                let me = EventRecord.residentRef(c.writer)
                // 只有写日记者是 actor 或 target 时才有句子；thought_shown 没有句子
                if r.actor != me && r.target != me { #expect(s == nil) }
                if r.type == .thoughtShown { #expect(s == nil) }

                // 句子不读取自由文本：替换 detail.text、detail.app 后不变
                var scrubbed = r
                scrubbed.detail["text"] = "另一段文字"
                scrubbed.detail["app"] = "Other"
                #expect(DiaryTemplates.sentence(for: scrubbed, writer: c.writer) == s)

                // Chase_Wish 的 wish_fulfilled：按写日记者与 Chase_Outcome 取 4 种固定句式之一
                if r.type == .wishFulfilled, r.detail["wish_type"] == WishType.chase.rawValue,
                   let outcome = r.detail["chase_outcome"].flatMap(ChaseOutcome.init(rawValue:)),
                   r.actor == me || r.target == me {
                    #expect(s == DiaryTemplates.chaseSentence(writer: c.writer, outcome: outcome))
                }
                if let s {
                    #expect(!s.contains("输") && !s.contains("赢") && !s.contains("失败"))
                }
            }
        }
    }
}

// MARK: - Property 42 生成器

/// 每个元素恰好是一个扩展字素簇，且与前后任意元素拼接时不会合并成一个字素：
/// ASCII、CJK、全角标点、带组合附加符的字母（NFD）、肤色修饰与 ZWJ 家庭 emoji、国旗、键帽、
/// 空格、制表符和 `\r\n`。不包含单独的组合符、修饰符、ZWJ、区域指示符或单独的 `\r`/`\n`，
/// 因此「前 n 个元素拼接」就是「前 n 个字素」，期望值可以不经 `String.prefix` 独立算出。
fileprivate let diaryTruncateGraphemes: [String] = [
    "a", "Z", "7", ".", "日", "记", "嘟", "，", "。",
    "e\u{301}", "n\u{303}\u{323}", "\u{1100}\u{1161}\u{11A8}",
    "😀", "👍🏽", "👨\u{200D}👩\u{200D}👧\u{200D}👦", "🇨🇳", "🇯🇵", "1\u{FE0F}\u{20E3}",
    " ", "\t", "\r\n",
]

fileprivate struct DiaryTruncateCase: Sendable {
    var units: [String]
    var maxLength: Int
}

fileprivate var diaryTruncateCase: Generator<DiaryTruncateCase, some SendableSequenceType> {
    zip(
        diaryTemplatePick(diaryTruncateGraphemes).array(of: 0...60),
        Gen<Int>.int(in: 0...48)
    ).map { units, maxLength in DiaryTruncateCase(units: units, maxLength: maxLength) }
}

extension DiaryTemplateTests {
    // Feature: V2, Property 42: 日记截断
    // **Validates: Requirements 13.8**
    @Test func diaryTextIsTruncatedPrefix() async {
        let config = LLMRequestConfig(
            endpoint: URL(string: "https://example.invalid/v1/chat")!, model: "m", apiKey: "k")
        let events = [EventRecord(
            time: day.range(timeZone: shanghai).lowerBound.addingTimeInterval(60),
            type: .landed, actor: EventRecord.residentRef(.a))]
        let key = DiaryKey(date: day, resident: .a)

        await propertyCheck(count: 200, input: diaryTruncateCase) { c in
            let original = c.units.joined()
            // 生成器自检：每个元素都是一个字素，拼接后不合并
            #expect(original.count == c.units.count)

            // 期望值：前 maxLength 个元素直接拼接（不去空白）
            let expected = c.units.prefix(c.maxLength).joined()
            let expectedCount = min(c.units.count, c.maxLength)

            let cut = DiaryWriter.truncate(original, maxLength: c.maxLength)
            #expect(Array(cut.unicodeScalars) == Array(expected.unicodeScalars))
            #expect(cut.count == expectedCount && cut.count <= c.maxLength)
            #expect(original.unicodeScalars.starts(with: cut.unicodeScalars))
            if c.units.count <= c.maxLength {
                #expect(Array(cut.unicodeScalars) == Array(original.unicodeScalars))
            }

            // write 的 LLM 成功路径：超长返回文本同样截断到 maxLength
            let writer = DiaryWriter(client: FakeLLMClient([.text(original)]), maxLength: c.maxLength)
            let entry = await writer.write(key, events: events, config: config, timeZone: shanghai)
            #expect(entry.text.count <= c.maxLength)
            if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 空白文本被判为失败，改用模板，模板正文同样截断
                let template = DiaryTemplates.text(writer: .a, events: events)
                #expect(entry.method == .template)
                #expect(entry.text == String(Array(template).prefix(c.maxLength)))
            } else {
                #expect(entry.method == .llm)
                #expect(Array(entry.text.unicodeScalars) == Array(expected.unicodeScalars))
                #expect(original.unicodeScalars.starts(with: entry.text.unicodeScalars))
            }

            // 模板路径：正文是模板全文的前缀且不超过 maxLength
            let plain = await DiaryWriter(client: nil, maxLength: c.maxLength)
                .write(key, events: events, config: nil, timeZone: shanghai)
            let full = DiaryTemplates.text(writer: .a, events: events)
            #expect(plain.text.count <= c.maxLength)
            #expect(full.unicodeScalars.starts(with: plain.text.unicodeScalars))
            if full.count <= c.maxLength { #expect(plain.text == full) }
        }
    }
}
