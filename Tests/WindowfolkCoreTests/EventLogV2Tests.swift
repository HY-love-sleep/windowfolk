import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// MARK: - 生成器

/// 一条 v2 事件记录和编码时使用的时区。
fileprivate struct EventV2Case: Sendable {
    var record: EventRecord
    var timeZone: TimeZone
}

/// 应用名称和 Thought 文本中容易出错的字符：引号、反斜杠、换行、控制字符、U+2028/2029、BOM、
/// 中文、组合字符、emoji。
fileprivate let v2TrickyCharacters: [Character] = [
    "\"", "\\", "\n", "\r", "\t", "\r\n", "\u{0}", "\u{1F}", "\u{7F}", "\u{2028}", "\u{2029}", "\u{FEFF}",
    "/", ":", "{", "}", ",", " ", "备", "忘", "录", "窗", "都", "嘟", "あ", "é", "e\u{301}",
    "🐹", "🌸", "👨‍👩‍👧", "🇨🇳", "👍🏽",
]

/// 一半取自易错字符表，一半是任意合法 Unicode 标量（跳过代理区）。
fileprivate var v2Character: Generator<Character, some SendableSequenceType> {
    zip(
    Gen<Bool>.bool,
    Gen<Character?>.element(of: v2TrickyCharacters).map { $0! },
    Gen<UInt32>.value(in: 0...(0x10FFFF - 0x800))
).map { useTricky, tricky, raw -> Character in
    if useTricky { return tricky }
    let v = raw >= 0xD800 ? raw + 0x800 : raw
    return Character(UnicodeScalar(v)!)
}
}

fileprivate var v2Text: Generator<String, some SendableSequenceType> { v2Character.string(of: 0...16) }

fileprivate func pick(_ values: [String]) -> Generator<String, some SendableSequenceType> {
    Gen<String?>.element(of: values).map { $0! }
}

/// 按「EventType 扩充」表构造的合法字段选择：居民、Decor 编号、各枚举取值。
fileprivate struct V2Choices: Sendable {
    var resident: String
    var other: String
    var decorID: Int
    var decorType: String
    var surface: String
    var wishType: String
    var wishState: String
    var chaseOutcome: String
    var visitSource: String
    var wokeReason: String
}

fileprivate var v2Choices: Generator<V2Choices, some SendableSequenceType> {
    zip(
    pick(["resident_a", "resident_b"]),
    Gen<Int>.int(in: 0...10_000),
    pick(["chair", "lamp"]),
    pick(["window_ledge", "plank", "ground"]),
    pick(["flower", "chair", "lamp", "visit", "chase"]),
    pick(["active", "fulfilled", "dropped"]),
    pick(["caught", "escaped"]),
    pick(["visit_neighbor", "visit_wish"]),
    pick(["night_ended", "lamp_moved", "surface_gone", "became_busy"])
).map { resident, decorID, decorType, surface, wishType, wishState, chase, source, reason in
    V2Choices(
        resident: resident, other: resident == "resident_a" ? "resident_b" : "resident_a",
        decorID: decorID, decorType: decorType, surface: surface, wishType: wishType,
        wishState: wishState, chaseOutcome: chase, visitSource: source, wokeReason: reason)
}
}

/// 由类型和字段选择拼出一条合法记录的 actor、target、detail。
/// v2 新类型按设计表填写；v1 类型沿用 v1 往返测试的做法，字段取任意文本。
fileprivate func fields(
    _ type: EventType, _ c: V2Choices, appName: String, thought: String,
    freeActor: String?, freeTarget: String?, freeDetail: [String: String]
) -> (String?, String?, [String: String]) {
    let decorRef = "decor:\(c.decorID)"
    func wishTarget() -> String? {
        switch c.wishType {
        case "flower", "chase": return c.other
        case "visit": return EventRecord.appRef(appName)
        default: return nil
        }
    }
    switch type {
    case .decorUnlocked:
        return (nil, nil, ["decor_type": c.decorType])
    case .decorPlaced:
        return (EventRecord.playerActor, decorRef, ["decor_type": c.decorType, "surface": c.surface])
    case .decorRemoved:
        return (EventRecord.playerActor, decorRef, ["decor_type": c.decorType])
    case .wishStarted, .wishDropped:
        return (c.resident, wishTarget(), ["wish_type": c.wishType, "wish_state": c.wishState])
    case .wishFulfilled:
        var d = ["wish_type": c.wishType, "wish_state": c.wishState]
        if c.wishType == "chase" { d["chase_outcome"] = c.chaseOutcome }
        return (c.resident, wishTarget(), d)
    case .visited:
        let target = c.visitSource == "visit_neighbor" ? c.other : EventRecord.appRef(appName)
        return (c.resident, target, ["source": c.visitSource])
    case .sat, .slept:
        return (c.resident, decorRef, [:])
    case .woke:
        return (c.resident, nil, ["reason": c.wokeReason])
    case .thoughtShown:
        return (c.resident, nil, ["text": thought])
    case .crossedBridge, .climbedLadder, .fell, .landed, .waitingStarted, .roundStarted, .planted,
        .sprouted, .bloomed, .giftDelivered, .plankPlaced, .plankDropped, .ladderPlaced, .ladderDropped:
        return (freeActor, freeTarget, freeDetail)
    }
}

fileprivate var eventV2Case: Generator<EventV2Case, some SendableSequenceType> {
    zip(
    Gen<EventType>.case,
    v2Choices,
    v2Text,  // 应用名称
    v2Text,  // Thought 文本
    zip(v2Text.optional(), v2Text.optional(), zip(v2Text, v2Text).dictionary(ofAtMost: 0...3)),
    Gen<Int>.int(in: 315_532_800...4_102_444_800),  // 1980 到 2100 年
    Gen<Double>.double(in: 0..<1),
    Gen<Int>.int(in: -48...56)  // 固定偏移 -12:00 到 +14:00，以 15 分钟为单位
).map { type, choices, appName, thought, free, seconds, fraction, quarters in
    let (actor, target, detail) = fields(
        type, choices, appName: appName, thought: thought,
        freeActor: free.0, freeTarget: free.1, freeDetail: free.2)
    let record = EventRecord(
        time: Date(timeIntervalSince1970: Double(seconds) + fraction), type: type,
        actor: actor, target: target, detail: detail)
    return EventV2Case(record: record, timeZone: TimeZone(secondsFromGMT: quarters * 15 * 60)!)
}
}

// MARK: - 属性测试

struct EventLogV2Tests {
    @Test func eventTypeHas25Cases() {
        #expect(EventType.allCases.count == 25)
    }

    // Feature: V2, Property 51: 事件编码往返覆盖新类型
    // **Validates: Requirements 18.1**
    @Test func eventCodecRoundTripCoversV2Types() async {
        await propertyCheck(count: 200, input: eventV2Case) { c in
            let r = c.record
            let line = EventCodec.encodeLine(r, timeZone: c.timeZone)

            // 恰好一行：结尾一个 \n，中间没有 \n 或 \r 字节
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A))
            #expect(!line.dropLast().contains(0x0D))

            // 键集合恰好为五个字段，type 与记录一致
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                Issue.record("not a JSON object: \(String(decoding: line, as: UTF8.self))")
                return
            }
            #expect(Set(obj.keys) == ["time", "type", "actor", "target", "detail"])
            #expect(obj["type"] as? String == r.type.rawValue)

            // 往返相等
            #expect((try? EventCodec.decodeLine(line)) == r)
        }
    }

    /// 单元示例：带引号、反斜杠、换行的应用名称和 Thought 文本能原样读回。
    @Test func trickyAppNameAndThoughtRoundTrip() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            EventRecord(
                time: t, type: .visited, actor: "resident_a", target: EventRecord.appRef("备忘录 \"Notes\"\\\n"),
                detail: ["source": "visit_wish"]),
            EventRecord(
                time: t, type: .thoughtShown, actor: "resident_b", detail: ["text": "想睡觉了\n\"zz\"\\🌙"]),
        ]
        for r in records {
            let line = EventCodec.encodeLine(r, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
            #expect(!line.dropLast().contains(0x0A))
            #expect(try EventCodec.decodeLine(line) == r)
        }
    }
}
