import Foundation
import Testing
@testable import WindowfolkCore

/// PromptBuilder 与 PromptPayload 的单元测试（任务 11.3，Requirement 12.1、12.2、13.6、14.1）。
/// 隐私不变量的属性测试（Property 33）在 PromptPayloadTests.swift（任务 11.4）。
@Suite struct PromptBuilderUnitTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let t0 = Date(timeIntervalSince1970: 1_792_500_000)
    private let day = LocalDate(year: 2026, month: 10, day: 20)

    private func allText(_ p: PromptPayload) -> String {
        p.messages().map { "\($0.role)\n\($0.content)" }.joined(separator: "\n")
    }

    @Test func residentRefsMapOnlyResidentIDs() {
        #expect(ResidentName(ref: "resident_a") == .dudu)
        #expect(ResidentName(ref: "resident_b") == .doodoo)
        for other in ["player", "app:Safari", "plank:3", "decor:5", "resident_c", "都都", nil] {
            #expect(ResidentName(ref: other) == nil)
        }
    }

    @Test func eventKeepsWhitelistedDetailOnly() {
        let r = EventRecord(
            time: t0, type: .wishFulfilled, actor: "resident_a", target: "resident_b",
            detail: ["wish_type": "chase", "chase_outcome": "caught", "wish_state": "fulfilled",
                     "decor_type": "lamp", "stage": "bloom", "surface": "ledge:42", "from": "Safari"])
        let e = PromptBuilder.event(r)
        #expect(e == PromptEvent(
            type: .wishFulfilled, time: t0, actor: .dudu, target: .doodoo, decorType: .lamp,
            wishType: .chase, wishState: .fulfilled, chaseOutcome: .caught, growthStage: .bloom))
    }

    @Test func invalidWhitelistValuesBecomeNil() {
        let r = EventRecord(
            time: t0, type: .decorPlaced, actor: "player", target: "decor:5",
            detail: ["decor_type": "sofa", "wish_type": "Safari", "wish_state": "x",
                     "chase_outcome": "won", "stage": "2"])
        #expect(PromptBuilder.event(r) == PromptEvent(type: .decorPlaced, time: t0))
    }

    @Test func thoughtShownNeverEntersPayload() {
        let secret = "秘密的小心思文本"
        let r = EventRecord(time: t0, type: .thoughtShown, actor: "resident_a", detail: ["text": secret])
        #expect(PromptBuilder.event(r) == nil)
        let p = PromptBuilder.thought(actor: .a, recent: [r], date: day, timeZone: utc)
        #expect(p.events.isEmpty)
        #expect(!allText(p).contains(secret))
    }

    @Test func diaryPayloadExcludesAppNamesAndWindowData() {
        let events = [
            EventRecord(time: t0, type: .visited, actor: "resident_a", target: "app:SecretEditorApp",
                        detail: ["source": "visit_wish", "window": "98765"]),
            EventRecord(time: t0.addingTimeInterval(60), type: .crossedBridge, actor: "resident_a",
                        target: "plank:3", detail: ["from": "app:SecretEditorApp", "x": "1234.5"]),
        ]
        let p = PromptBuilder.diary(resident: .a, date: day, events: events, timeZone: shanghai)
        #expect(p.purpose == .diary(.dudu))
        #expect(p.localDate == day)
        #expect(p.events.map(\.type) == [.visited, .crossedBridge])
        #expect(p.events.allSatisfy { $0.target == nil })
        let text = allText(p)
        #expect(!text.contains("SecretEditorApp"))
        #expect(!text.contains("98765"))
        #expect(!text.contains("1234"))
        #expect(!text.contains("plank"))
    }

    @Test func messagesRenderSystemAndUser() {
        let r = EventRecord(
            time: t0, type: .wishFulfilled, actor: "resident_b", target: "resident_a",
            detail: ["wish_type": "chase", "chase_outcome": "escaped"])
        let p = PromptBuilder.thought(actor: .b, recent: [r], date: day, timeZone: utc)
        let m = p.messages()
        #expect(m.map(\.role) == ["system", "user"])
        #expect(m[0].content == p.systemText)
        #expect(p.systemText.contains("嘟嘟"))
        #expect(m[1].content.contains("日期：2026-10-20"))
        #expect(m[1].content.contains(
            "- \(EventCodec.formatTime(t0, timeZone: utc)) wish_fulfilled actor=嘟嘟 target=都都 wish_type=chase chase_outcome=escaped"))
    }

    @Test func systemTextDiffersByPurpose() {
        let d = PromptBuilder.diary(resident: .a, date: day, events: [], timeZone: utc)
        let t = PromptBuilder.thought(actor: .a, recent: [], date: day, timeZone: utc)
        #expect(d.systemText != t.systemText)
        #expect(d.systemText.contains("日记"))
    }
}
