import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 12.7：Thought 文本规整与 ThoughtEngine 状态机的具体例子。
struct ThoughtUnitTests {
    let constants = Tunables()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let utc = TimeZone(identifier: "UTC")!

    func residents() -> [ResidentID: Resident] {
        [.a: Resident(id: .a, attachment: .ground(x: 10)), .b: Resident(id: .b, attachment: .ground(x: 50))]
    }

    func landed(_ id: ResidentID, at t: Date) -> EventRecord {
        EventRecord(time: t, type: .landed, actor: EventRecord.residentRef(id))
    }

    // MARK: normalize

    @Test func normalizeReplacesNewlineRunsAndTrims() {
        #expect(ThoughtEngine.normalize("  你好\r\n\n世界\r啊 \n", maxLength: 24) == "你好 世界 啊")
    }

    @Test func normalizeTruncatesByGraphemeAndTrimsTail() {
        #expect(ThoughtEngine.normalize("👨‍👩‍👧é🙂", maxLength: 2) == "👨‍👩‍👧é")
        #expect(ThoughtEngine.normalize("ab cd", maxLength: 3) == "ab")
    }

    @Test func normalizeReturnsNilForBlank() {
        #expect(ThoughtEngine.normalize(" \r\n\t ", maxLength: 24) == nil)
        #expect(ThoughtEngine.normalize("abc", maxLength: 0) == nil)
    }

    @Test func residentThoughtDefaultsToNil() {
        #expect(Resident(id: .a, attachment: .ground(x: 0)).thought == nil)
    }

    // MARK: step

    @Test func triggerEventSendsOneRequestAndBlocksFurther() {
        var engine = ThoughtEngine()
        var rs = residents()
        let out = engine.step(
            events: [EventRecord(time: t0, type: .sat, actor: "resident_b"), landed(.a, at: t0), landed(.b, at: t0)],
            results: [], enabled: true, residents: &rs, suppressed: [], now: t0, timeZone: utc,
            constants: constants)
        #expect(out.requests.count == 1)
        #expect(out.requests.first?.resident == .a)
        #expect(out.requests.first?.payload.purpose == .thought(.dudu))
        #expect(out.requests.first?.payload.localDate == LocalDate.of(t0, timeZone: utc))
        #expect(out.requests.first?.payload.events.count == 3)
        #expect(engine.inFlight?.resident == .a)

        let again = engine.step(
            events: [landed(.b, at: t0)], results: [], enabled: true, residents: &rs, suppressed: [],
            now: t0.addingTimeInterval(1), timeZone: utc, constants: constants)
        #expect(again.requests.isEmpty)
    }

    @Test func matchingResultShowsThoughtAndWritesRecord() throws {
        var engine = ThoughtEngine()
        var rs = residents()
        let req = try #require(
            engine.step(
                events: [landed(.a, at: t0)], results: [], enabled: true, residents: &rs, suppressed: [],
                now: t0, timeZone: utc, constants: constants
            ).requests.first)
        let t1 = t0.addingTimeInterval(2)
        let out = engine.step(
            events: [], results: [(req.id &+ 100, .text("迟到")), (req.id, .text("好开心\n呀"))], enabled: true,
            residents: &rs, suppressed: [], now: t1, timeZone: utc, constants: constants)
        #expect(rs[.a]?.thought == ThoughtDisplay(text: "好开心 呀", until: t1.addingTimeInterval(6)))
        #expect(out.shown.count == 1)
        #expect(out.shown.first?.type == .thoughtShown)
        #expect(out.shown.first?.actor == "resident_a")
        #expect(out.shown.first?.detail["text"] == "好开心 呀")
        #expect(engine.lastShownAt == t1)
        #expect(engine.inFlight == nil)

        // 到时移除。
        _ = engine.step(
            events: [], results: [], enabled: true, residents: &rs, suppressed: [],
            now: t1.addingTimeInterval(6), timeZone: utc, constants: constants)
        #expect(rs[.a]?.thought == nil)

        // 未满 Thought_Min_Interval 不发请求。
        let early = engine.step(
            events: [landed(.a, at: t1)], results: [], enabled: true, residents: &rs, suppressed: [],
            now: t1.addingTimeInterval(599), timeZone: utc, constants: constants)
        #expect(early.requests.isEmpty)
        let late = engine.step(
            events: [landed(.a, at: t1)], results: [], enabled: true, residents: &rs, suppressed: [],
            now: t1.addingTimeInterval(600), timeZone: utc, constants: constants)
        #expect(late.requests.count == 1)
    }

    @Test func failureAndSuppressedDoNotCountTowardInterval() throws {
        var engine = ThoughtEngine()
        var rs = residents()
        let r1 = try #require(
            engine.step(
                events: [landed(.a, at: t0)], results: [], enabled: true, residents: &rs, suppressed: [],
                now: t0, timeZone: utc, constants: constants
            ).requests.first)
        let r2 = try #require(
            engine.step(
                events: [landed(.a, at: t0)], results: [(r1.id, .failure)], enabled: true, residents: &rs,
                suppressed: [], now: t0, timeZone: utc, constants: constants
            ).requests.first)
        let out = engine.step(
            events: [], results: [(r2.id, .text("嗨"))], enabled: true, residents: &rs, suppressed: [.a],
            now: t0, timeZone: utc, constants: constants)
        #expect(out.shown.isEmpty)
        #expect(rs[.a]?.thought == nil)
        #expect(engine.lastShownAt == nil)
        #expect(engine.inFlight == nil)
    }

    @Test func disablingDropsInFlightAndRemovesThought() throws {
        var engine = ThoughtEngine()
        var rs = residents()
        let req = try #require(
            engine.step(
                events: [landed(.b, at: t0)], results: [], enabled: true, residents: &rs, suppressed: [],
                now: t0, timeZone: utc, constants: constants
            ).requests.first)
        rs[.a]?.thought = ThoughtDisplay(text: "旧的", until: t0.addingTimeInterval(100))
        let out = engine.step(
            events: [landed(.b, at: t0)], results: [(req.id, .text("关闭后返回"))], enabled: false,
            residents: &rs, suppressed: [], now: t0, timeZone: utc, constants: constants)
        #expect(out.requests.isEmpty)
        #expect(out.shown.isEmpty)
        #expect(rs[.a]?.thought == nil)
        #expect(rs[.b]?.thought == nil)
        #expect(engine.inFlight == nil)
    }

    @Test func recentKeepsLastTwentyEvents() {
        var engine = ThoughtEngine()
        var rs = residents()
        let evs = (0..<25).map { EventRecord(time: t0.addingTimeInterval(Double($0)), type: .sat, actor: "resident_a") }
        _ = engine.step(
            events: evs, results: [], enabled: true, residents: &rs, suppressed: [], now: t0, timeZone: utc,
            constants: constants)
        #expect(engine.recent == Array(evs.suffix(20)))
    }
}
