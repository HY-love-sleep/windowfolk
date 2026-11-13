import Foundation
import Testing
@testable import WindowfolkCore

/// DiaryTemplates 与 DiaryWriter 的基本单元测试（任务 12.1，Requirement 13.1、13.5、13.7、13.8、22.8）。
@Suite struct DiaryWriterUnitTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let day = LocalDate(year: 2026, month: 10, day: 21)
    private let config = LLMRequestConfig(
        endpoint: URL(string: "https://example.invalid/v1/chat")!, model: "m", apiKey: "k")

    /// 上海时间 2026-10-21 的某一时刻（秒偏移）。
    private func at(_ seconds: TimeInterval) -> Date {
        day.range(timeZone: shanghai).lowerBound.addingTimeInterval(seconds)
    }

    private func chase(_ outcome: String, time: Date) -> EventRecord {
        EventRecord(time: time, type: .wishFulfilled, actor: "resident_b", target: "resident_a",
                    detail: ["wish_type": "chase", "wish_state": "fulfilled", "chase_outcome": outcome])
    }

    @Test func chaseSentencesByRoleAndOutcome() {
        let caught = chase("caught", time: at(10)), escaped = chase("escaped", time: at(10))
        let all = [
            DiaryTemplates.sentence(for: caught, writer: .a),
            DiaryTemplates.sentence(for: escaped, writer: .a),
            DiaryTemplates.sentence(for: caught, writer: .b),
            DiaryTemplates.sentence(for: escaped, writer: .b),
        ].compactMap { $0 }
        #expect(all == [
            "和嘟嘟玩追逐，我抓到嘟嘟啦。", "和嘟嘟玩追逐，我没抓到嘟嘟，它跑得真快。",
            "和都都玩追逐，我被都都抓到了。", "和都都玩追逐，我没被都都抓到。",
        ])
        for s in all { #expect(!s.contains("输") && !s.contains("赢") && !s.contains("失败")) }
    }

    @Test func thoughtShownAndUnrelatedRecordsGiveNoSentence() {
        let thought = EventRecord(time: at(1), type: .thoughtShown, actor: "resident_a", detail: ["text": "秘密"])
        let other = EventRecord(time: at(2), type: .sat, actor: "resident_b", target: "decor:1")
        #expect(DiaryTemplates.sentence(for: thought, writer: .a) == nil)
        #expect(DiaryTemplates.sentence(for: other, writer: .a) == nil)
    }

    @Test func noTemplateSentenceContainsForbiddenWords() {
        for type in EventType.allCases {
            for wish in WishType.allCases {
                for outcome in ["caught", "escaped", "x"] {
                    for (actor, target) in [("resident_a", "resident_b"), ("resident_b", "resident_a"),
                                            ("resident_a", "app:Safari")] {
                        let r = EventRecord(time: at(0), type: type, actor: actor, target: target,
                                            detail: ["wish_type": wish.rawValue, "chase_outcome": outcome,
                                                     "decor_type": "lamp"])
                        for w in ResidentID.allCases {
                            let s = DiaryTemplates.sentence(for: r, writer: w) ?? ""
                            #expect(!s.contains("输") && !s.contains("赢") && !s.contains("失败"))
                            #expect(!s.contains("Safari"))
                        }
                    }
                }
            }
        }
    }

    @Test func relevantFiltersByDateAndResidentKeepingOrder() {
        let e1 = EventRecord(time: at(5), type: .landed, actor: "resident_a")
        let e2 = EventRecord(time: at(-1), type: .landed, actor: "resident_a")        // 前一天
        let e3 = EventRecord(time: at(86_400), type: .landed, actor: "resident_a")    // 次日 00:00
        let e4 = EventRecord(time: at(7), type: .visited, actor: "resident_b", target: "resident_a")
        let e5 = EventRecord(time: at(8), type: .sat, actor: "resident_b", target: "decor:1")
        let r = DiaryWriter.relevant([e1, e2, e3, e4, e5], resident: .a, date: day, timeZone: shanghai)
        #expect(r == [e1, e4])
    }

    @Test func pendingSkipsTodayAndExisting() {
        let yesterday = LocalDate(year: 2026, month: 10, day: 20)
        let events = [
            EventRecord(time: at(-100), type: .visited, actor: "resident_a", target: "resident_b"),
            EventRecord(time: at(100), type: .landed, actor: "resident_a"),
        ]
        let keys = DiaryWriter.pending(
            events: events, existing: [DiaryKey(date: yesterday, resident: .b)], before: day, timeZone: shanghai)
        #expect(keys == [DiaryKey(date: yesterday, resident: .a)])
    }

    @Test func writeUsesTemplateWithoutConfigAndTruncates() async {
        let events = [EventRecord(time: at(1), type: .landed, actor: "resident_a"),
                      EventRecord(time: at(2), type: .woke, actor: "resident_a")]
        let fake = FakeLLMClient([.text("不该用到")])
        let writer = DiaryWriter(client: fake, maxLength: 5)
        let e = await writer.write(DiaryKey(date: day, resident: .a), events: events, config: nil, timeZone: shanghai)
        #expect(e.method == .template)
        #expect(e.text == String(DiaryTemplates.text(writer: .a, events: events).prefix(5)))
        #expect(await fake.requestCount == 0)
    }

    @Test func writeFallsBackToTemplateOnFailureAndUsesLLMOnSuccess() async {
        let events = [EventRecord(time: at(1), type: .landed, actor: "resident_b")]
        let key = DiaryKey(date: day, resident: .b)
        let failing = DiaryWriter(client: FakeLLMClient([.timeout]), maxLength: 300)
        let f = await failing.write(key, events: events, config: config, timeZone: shanghai)
        #expect(f.method == .template && f.text == "我稳稳地落了地。")

        let ok = DiaryWriter(client: FakeLLMClient([.text("今天落地了。")]), maxLength: 300)
        let s = await ok.write(key, events: events, config: config, timeZone: shanghai)
        #expect(s.method == .llm && s.text == "今天落地了。")
    }
}
