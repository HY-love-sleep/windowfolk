import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// Thought 状态机的属性测试（design.md Property 35，任务 12.10）。
//
// 生成随机的帧序列：每帧有时钟推进、本帧事件、LLM 结果（匹配进行中 id、过期 id、未来 id）、
// 「小心思」开关和被压制的居民集合。被测 `ThoughtEngine.step` 与本文件的独立参考状态机逐帧比对，
// 并额外检查 Property 35 列出的各项不变量。
//
// 参考状态机不调用 `ThoughtEngine.normalize`：结果文本取自固定表，表中写好规整后的期望值。

// MARK: - 生成器

/// 时钟推进（秒）。包含 0、显示时长 6 附近、Thought_Min_Interval 600 附近。
fileprivate let thoughtDeltas: [Double] = [0, 1, 2, 5, 6, 7, 60, 300, 599, 600, 601, 1200]

/// 事件类型：前四种会触发请求，其余不会（`thought_shown` 也在其中）。
fileprivate let thoughtEventTypes: [EventType] = [
    .landed, .woke, .visited, .wishFulfilled, .sat, .fell, .slept, .decorPlaced, .thoughtShown,
]

/// 事件发起方：两位居民、玩家、无发起方。
fileprivate let thoughtActors: [String?] = ["resident_a", "resident_b", "player", nil]

/// LLM 返回文本与规整后的期望值（Thought_Max_Length 为 24）。nil 表示规整后为空，按失败处理。
fileprivate let thoughtTexts: [(raw: String, expected: String?)] = [
    ("好开心", "好开心"),
    ("  嗨\r\n\n呀 ", "嗨 呀"),
    (" \r\n\t ", nil),
    ("", nil),
    (String(repeating: "嘟", count: 30), String(repeating: "嘟", count: 24)),
    ("想吃果子\n", "想吃果子"),
    (String(repeating: "a", count: 23) + " bc", String(repeating: "a", count: 23)),
    ("🐹\r窗边真暖", "🐹 窗边真暖"),
]

fileprivate struct EventSpec: Sendable, CustomStringConvertible {
    var type: Int
    var actor: Int
    var description: String { "\(thoughtEventTypes[type].rawValue)/\(thoughtActors[actor] ?? "nil")" }
}

/// 一条结果。`idKind` 0…2 用进行中 id（没有时退化为过期 id），3 用过期 id，4 用尚未发出的 id。
/// `text` 等于 `thoughtTexts.count` 时为 `.failure`。
fileprivate struct ResultSpec: Sendable, CustomStringConvertible {
    var idKind: Int
    var text: Int
    var description: String { "id\(idKind)/t\(text)" }
}

fileprivate struct FrameSpec: Sendable, CustomStringConvertible {
    var delta: Int
    var events: [EventSpec]
    var results: [ResultSpec]
    var enabled: Bool
    /// 0：都不压制；1：A；2：B；3：两位（世界隐藏）；4…7：都不压制。
    var suppressed: Int
    var description: String {
        "dt\(thoughtDeltas[delta]) e\(events) r\(results) on\(enabled) s\(suppressed)"
    }
}

fileprivate var eventSpecGen: Generator<EventSpec, some SendableSequenceType> {
    zip(Gen<Int>.int(in: 0...(thoughtEventTypes.count - 1)), Gen<Int>.int(in: 0...(thoughtActors.count - 1)))
        .map { EventSpec(type: $0, actor: $1) }
}

fileprivate var resultSpecGen: Generator<ResultSpec, some SendableSequenceType> {
    zip(Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...thoughtTexts.count))
        .map { ResultSpec(idKind: $0, text: $1) }
}

fileprivate var frameSpecGen: Generator<FrameSpec, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...(thoughtDeltas.count - 1)),
        eventSpecGen.array(of: 0...3),
        resultSpecGen.array(of: 0...2),
        Gen<Bool>.bool(0.85),
        Gen<Int>.int(in: 0...7)
    ).map { FrameSpec(delta: $0, events: $1, results: $2, enabled: $3, suppressed: $4) }
}

fileprivate var frameSequenceGen: Generator<[FrameSpec], some SendableSequenceType> {
    frameSpecGen.array(of: 1...40)
}

// MARK: - 参考状态机

fileprivate struct RefResult {
    var id: UInt64
    var result: ThoughtResult
    var expected: String?
}

fileprivate struct ThoughtReference {
    var inFlight: ThoughtInFlight?
    var lastShownAt: Date?
    var recent: [EventRecord] = []
    var nextID: UInt64 = 1
    var thoughts: [ResidentID: ThoughtDisplay] = [:]
    /// 已发出但不再进行中的请求 id。
    var retired: [UInt64] = []

    let constants: Tunables

    /// 按 spec 构造本帧结果（在 step 前用参考状态解析 id）。
    func resolve(_ specs: [ResultSpec]) -> [RefResult] {
        specs.map { s in
            let stale = retired.last ?? 0
            let id: UInt64
            switch s.idKind {
            case 0...2: id = inFlight?.id ?? stale
            case 3: id = stale
            default: id = nextID &+ 7
            }
            if s.text >= thoughtTexts.count {
                return RefResult(id: id, result: .failure, expected: nil)
            }
            let t = thoughtTexts[s.text]
            return RefResult(id: id, result: .text(t.raw), expected: t.expected)
        }
    }

    mutating func step(
        events: [EventRecord], results: [RefResult], enabled: Bool, suppressed: Set<ResidentID>, now: Date
    ) -> (request: ThoughtInFlight?, shown: [EventRecord]) {
        if !enabled {
            if let p = inFlight { retired.append(p.id) }
            inFlight = nil
            thoughts = [:]
        }
        var shown: [EventRecord] = []
        for r in results {
            guard let p = inFlight, p.id == r.id else { continue }
            inFlight = nil
            retired.append(p.id)
            guard let text = r.expected, !suppressed.contains(p.resident) else { continue }
            thoughts[p.resident] = ThoughtDisplay(text: text, until: now.addingTimeInterval(constants.thoughtDisplayDuration))
            lastShownAt = now
            shown.append(
                EventRecord(time: now, type: .thoughtShown, actor: p.resident.rawValue, detail: ["text": text]))
        }
        for id in Array(thoughts.keys) {
            if let t = thoughts[id], now >= t.until || suppressed.contains(id) { thoughts[id] = nil }
        }
        recent = Array((recent + events + shown).suffix(constants.recentEventCount))

        let intervalOK = lastShownAt.map { now.timeIntervalSince($0) >= constants.thoughtMinInterval } ?? true
        guard enabled, inFlight == nil, intervalOK else { return (nil, shown) }
        let triggers: Set<EventType> = [.wishFulfilled, .landed, .woke, .visited]
        for e in events where triggers.contains(e.type) {
            guard let ref = e.actor, let actor = ResidentID(rawValue: ref) else { continue }
            let req = ThoughtInFlight(id: nextID, resident: actor)
            nextID += 1
            inFlight = req
            return (req, shown)
        }
        return (nil, shown)
    }
}

// MARK: - 属性测试

@Suite struct ThoughtEnginePropertyTests {
    // Feature: V2, Property 35: Thought 状态机
    // **Validates: Requirements 12.4, 14.1, 14.3, 14.5, 14.6, 14.8, 14.9, 14.10**
    @Test func thoughtStateMachineMatchesReference() async {
        let constants = Tunables()
        let utc = TimeZone(identifier: "UTC")!
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        await propertyCheck(count: 200, input: frameSequenceGen) { frames in
            var engine = ThoughtEngine()
            var ref = ThoughtReference(constants: constants)
            var residents: [ResidentID: Resident] = [
                .a: Resident(id: .a, attachment: .ground(x: 10)),
                .b: Resident(id: .b, attachment: .ground(x: 50)),
            ]
            var now = t0
            var shownTimes: [Date] = []
            // 关闭后到下一次成功显示之前，不应有显示中的 Thought。
            var blankSinceDisabled = false

            for (i, f) in frames.enumerated() {
                now = now.addingTimeInterval(thoughtDeltas[f.delta])
                let ctx = "帧 \(i)：\(f)\n序列：\(frames)"
                let events = f.events.map {
                    EventRecord(time: now, type: thoughtEventTypes[$0.type], actor: thoughtActors[$0.actor])
                }
                let suppressed: Set<ResidentID> =
                    switch f.suppressed {
                    case 1: [.a]
                    case 2: [.b]
                    case 3: [.a, .b]
                    default: []
                    }
                let results = ref.resolve(f.results)
                let wasInFlight = ref.inFlight

                let out = engine.step(
                    events: events, results: results.map { ($0.id, $0.result) }, enabled: f.enabled,
                    residents: &residents, suppressed: suppressed, now: now, timeZone: utc, constants: constants)
                let expected = ref.step(
                    events: events, results: results, enabled: f.enabled, suppressed: suppressed, now: now)

                // 与参考状态机一致。
                #expect(engine.inFlight == ref.inFlight, "inFlight \(ctx)")
                #expect(engine.lastShownAt == ref.lastShownAt, "lastShownAt \(ctx)")
                #expect(engine.recent == ref.recent, "recent \(ctx)")
                #expect(engine.nextID == ref.nextID, "nextID \(ctx)")
                #expect(out.shown == expected.shown, "shown \(ctx)")
                for id in ResidentID.allCases {
                    #expect(residents[id]?.thought == ref.thoughts[id], "thought \(id) \(ctx)")
                }
                #expect(out.requests.count == (expected.request == nil ? 0 : 1), "requests \(ctx)")
                if let req = out.requests.first, let exp = expected.request {
                    #expect(req.id == exp.id && req.resident == exp.resident, "request \(ctx)")
                    let payload = PromptBuilder.thought(
                        actor: exp.resident, recent: ref.recent, date: LocalDate.of(now, timeZone: utc),
                        timeZone: utc)
                    #expect(req.payload == payload, "payload \(ctx)")
                }

                // 至多一个进行中请求：已有进行中请求且本帧未被结果结束时，不发新请求（14.9）。
                #expect(out.requests.count <= 1, "多个请求 \(ctx)")
                if let p = wasInFlight, f.enabled, !results.contains(where: { $0.id == p.id }) {
                    #expect(out.requests.isEmpty, "进行中仍发请求 \(ctx)")
                }

                // 只有匹配进行中 id 的结果可能被显示（12.4、14.10）。
                if !out.shown.isEmpty {
                    #expect(f.enabled, "关闭时显示 \(ctx)")
                    #expect(wasInFlight != nil && results.contains { $0.id == wasInFlight!.id }, "非匹配结果被显示 \(ctx)")
                }

                // 关闭的那次 step 起不显示 Thought，也不发请求（14.10）。
                if !f.enabled {
                    blankSinceDisabled = true
                    #expect(out.requests.isEmpty, "关闭时发请求 \(ctx)")
                }
                if !out.shown.isEmpty { blankSinceDisabled = false }
                if blankSinceDisabled {
                    #expect(residents.values.allSatisfy { $0.thought == nil }, "关闭后仍有 Thought \(ctx)")
                }

                // 被压制的居民没有显示中的 Thought（14.3）。
                for id in suppressed {
                    #expect(residents[id]?.thought == nil, "被压制仍显示 \(id) \(ctx)")
                }

                // 每次开始显示恰好一条 thought_shown，detail.text 等于显示文本（14.8）。
                #expect(out.shown.count <= 1, "一帧多条 shown \(ctx)")
                for rec in out.shown {
                    #expect(rec.type == .thoughtShown && rec.time == now, "记录 \(ctx)")
                    let who = rec.actor.flatMap(ResidentID.init(rawValue:))
                    #expect(who != nil && residents[who!]?.thought?.text == rec.detail["text"], "记录文本 \(ctx)")
                    shownTimes.append(now)
                }
                for (id, r) in residents {
                    if let t = r.thought {
                        #expect(t.text.count <= constants.thoughtMaxLength && !t.text.isEmpty, "文本 \(id) \(ctx)")
                        #expect(!t.text.contains("\n") && !t.text.contains("\r"), "换行 \(id) \(ctx)")
                    }
                }
            }

            // 相邻两次开始显示的间隔 ≥ Thought_Min_Interval（14.1）。
            for (a, b) in zip(shownTimes, shownTimes.dropFirst()) {
                #expect(b.timeIntervalSince(a) >= constants.thoughtMinInterval, "间隔 \(a) → \(b)：\(frames)")
            }
        }
    }
}
