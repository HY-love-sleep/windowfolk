import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// MARK: - 生成器

/// 后缀里容易出错的字符：引号、反斜杠、换行、等号、空格、居民名用字、中文、emoji。
fileprivate let ppTrickyCharacters: [Character] = [
    "\"", "\\", "\n", "\r", "\t", "=", " ", ":", "-", "都", "嘟", "备", "忘", "录", "あ", "é",
    "🐹", "🌸", "👨‍👩‍👧",
]

fileprivate var ppSuffixCharacter: Generator<Character, some SendableSequenceType> {
    zip(
        Gen<Bool>.bool,
        Gen<Character?>.element(of: ppTrickyCharacters).map { $0! },
        Gen<UInt32>.value(in: 0x20...0x7E)
    ).map { useTricky, tricky, raw -> Character in
        useTricky ? tricky : Character(UnicodeScalar(raw)!)
    }
}

/// 私密文本（应用名称、Thought 文本）：6 个大写 ASCII 字母的随机前缀加任意后缀。
/// 内置文本是中文，枚举取值是小写，ISO 时间里没有连续的大写字母，
/// 因此带这样前缀的字符串不会和居民名、固定文本、事件类型名巧合重合。
fileprivate var ppPrivateText: Generator<String, some SendableSequenceType> {
    zip(
        Gen<Character>.character(in: "A"..."Z").string(of: 6),
        ppSuffixCharacter.string(of: 0...8)
    ).map { prefix, suffix in prefix + suffix }
}

/// 一条原始事件的形状。具体的应用名称、窗口 ID 在测试体里按下标取用。
fileprivate struct RawEvent: Sendable {
    var type: EventType
    var actorKind: Int
    var targetKind: Int
    var nameIndex: Int
    /// 五个白名单键各自是否出现（bit 0...4）。
    var whitelistMask: Int
    /// 出现的白名单键是否取合法枚举值（bit 置位）还是取私密文本（bit 清零）。
    var validMask: Int
    /// 私密键 `app`、`window_id`、`x`、`y`、`text` 各自是否出现（bit 0...4）。
    var privateMask: Int
    var enumPick: Int
    var seconds: Int
    var x: Double
    var y: Double
}

fileprivate var rawEvent: Generator<RawEvent, some SendableSequenceType> {
    zip(
        Gen<EventType>.case,
        Gen<Int>.int(in: 0...10),
        Gen<Int>.int(in: 0...10),
        Gen<Int>.int(in: 0...100),
        Gen<Int>.int(in: 0...31),
        Gen<Int>.int(in: 0...31),
        Gen<Int>.int(in: 0...31),
        Gen<Int>.int(in: 0...100),
        zip(
            Gen<Int>.int(in: 315_532_800...4_102_444_800),
            Gen<Double>.double(in: -5000...5000),
            Gen<Double>.double(in: -5000...5000))
    ).map { type, a, t, n, wl, valid, priv, pick, rest in
        RawEvent(
            type: type, actorKind: a, targetKind: t, nameIndex: n, whitelistMask: wl, validMask: valid,
            privateMask: priv, enumPick: pick, seconds: rest.0, x: rest.1, y: rest.2)
    }
}

fileprivate struct PrivacyCase: Sendable {
    var appNames: [String]
    var thoughts: [String]
    var windowIDs: [Int]
    var events: [RawEvent]
    var date: LocalDate
    var timeZone: TimeZone
}

fileprivate var privacyCase: Generator<PrivacyCase, some SendableSequenceType> {
    zip(
        ppPrivateText.array(of: 1...3),
        ppPrivateText.array(of: 1...3),
        Gen<Int>.int(in: 100_000...99_999_999).array(of: 1...3),
        rawEvent.array(of: 0...20),
        zip(Gen<Int>.int(in: 1980...2100), Gen<Int>.int(in: 1...12), Gen<Int>.int(in: 1...28)),
        Gen<Int>.int(in: -48...56)  // 固定偏移 -12:00 到 +14:00，以 15 分钟为单位
    ).map { names, thoughts, ids, events, ymd, quarters in
        PrivacyCase(
            appNames: names, thoughts: thoughts, windowIDs: ids, events: events,
            date: LocalDate(year: ymd.0, month: ymd.1, day: ymd.2),
            timeZone: TimeZone(secondsFromGMT: quarters * 15 * 60)!)
    }
}

// MARK: - 由形状构造事件记录

fileprivate let validWishStates = ["active", "fulfilled", "dropped"]
fileprivate let validChaseOutcomes = ["caught", "escaped"]

fileprivate extension PrivacyCase {
    func appName(_ i: Int) -> String { appNames[i % appNames.count] }
    func thought(_ i: Int) -> String { thoughts[i % thoughts.count] }
    func windowID(_ i: Int) -> Int { windowIDs[i % windowIDs.count] }

    /// actor / target 的候选：居民、玩家、应用、窗口 ID、木板、Decor 等。
    func ref(_ kind: Int, _ e: RawEvent) -> String? {
        let id = windowID(e.nameIndex)
        switch kind {
        case 0: return nil
        case 1: return "resident_a"
        case 2: return "resident_b"
        case 3: return EventRecord.playerActor
        case 4: return EventRecord.appRef(appName(e.nameIndex))
        case 5: return "window:\(id)"
        case 6: return "plank:\(id)"
        case 7: return "decor:\(id)"
        case 8: return appName(e.nameIndex)
        case 9: return String(id)
        default: return "ground"
        }
    }

    func record(_ e: RawEvent) -> EventRecord {
        let name = appName(e.nameIndex)
        let id = windowID(e.nameIndex)
        var detail: [String: String] = [:]
        let validValues: [String] = [
            DecorType.allCases[e.enumPick % DecorType.allCases.count].rawValue,
            WishType.allCases[e.enumPick % WishType.allCases.count].rawValue,
            validWishStates[e.enumPick % validWishStates.count],
            validChaseOutcomes[e.enumPick % validChaseOutcomes.count],
            GrowthStage.allCases[e.enumPick % GrowthStage.allCases.count].name,
        ]
        let keys = ["decor_type", "wish_type", "wish_state", "chase_outcome", "stage"]
        for (bit, key) in keys.enumerated() where e.whitelistMask & (1 << bit) != 0 {
            detail[key] = e.validMask & (1 << bit) != 0 ? validValues[bit] : name
        }
        let privateKeys: [(String, String)] = [
            ("app", EventRecord.appRef(name)),
            ("window_id", String(id)),
            ("x", String(e.x)),
            ("y", String(e.y)),
            ("text", thought(e.nameIndex)),
        ]
        for (bit, kv) in privateKeys.enumerated() where e.privateMask & (1 << bit) != 0 {
            detail[kv.0] = kv.1
        }
        if e.type == .thoughtShown { detail["text"] = thought(e.nameIndex) }
        return EventRecord(
            time: Date(timeIntervalSince1970: Double(e.seconds)), type: e.type,
            actor: ref(e.actorKind, e), target: ref(e.targetKind, e), detail: detail)
    }
}

// MARK: - 渲染结果的白名单

fileprivate let allowedFieldValues: [String: Set<String>] = [
    "actor": Set(ResidentName.allCases.map(\.rawValue)),
    "target": Set(ResidentName.allCases.map(\.rawValue)),
    "decor_type": Set(DecorType.allCases.map(\.rawValue)),
    "wish_type": Set(WishType.allCases.map(\.rawValue)),
    "wish_state": Set(validWishStates),
    "chase_outcome": Set(validChaseOutcomes),
    "stage": Set(GrowthStage.allCases.map(\.name)),
]

// MARK: - 属性测试

struct PromptPayloadTests {
    // Feature: V2, Property 33: Prompt_Payload 隐私不变量
    // **Validates: Requirements 12.1, 12.2, 13.6**
    @Test func promptPayloadPrivacyInvariant() async {
        await propertyCheck(count: 200, input: privacyCase) { c in
            let records = c.events.map(c.record)
            let kept = records.filter { $0.type != .thoughtShown }

            for resident in [ResidentID.a, .b] {
                let payloads = [
                    PromptBuilder.diary(resident: resident, date: c.date, events: records, timeZone: c.timeZone),
                    PromptBuilder.thought(actor: resident, recent: records, date: c.date, timeZone: c.timeZone),
                ]
                for p in payloads {
                    let messages = p.messages()
                    let all = messages.map(\.content).joined(separator: "\n")

                    // 不含任何应用名称、Thought 文本、窗口 ID
                    for name in c.appNames { #expect(!all.contains(name), "app name leaked: \(name)") }
                    for t in c.thoughts { #expect(!all.contains(t), "thought leaked: \(t)") }
                    for id in c.windowIDs { #expect(!all.contains(String(id)), "window id leaked: \(id)") }
                    #expect(!all.contains("app:"))
                    #expect(!all.contains("window"))

                    // thought_shown 整条排除，其余按原顺序映射，字段只取白名单
                    #expect(p.events.count == kept.count)
                    for (pe, r) in zip(p.events, kept) {
                        #expect(pe.type == r.type)
                        #expect(pe.time == r.time)
                        #expect(pe.actor == ResidentName(ref: r.actor))
                        #expect(pe.target == ResidentName(ref: r.target))
                        #expect(pe.decorType == r.detail["decor_type"].flatMap(DecorType.init(rawValue:)))
                        #expect(pe.wishType == r.detail["wish_type"].flatMap(WishType.init(rawValue:)))
                        #expect(pe.wishState == r.detail["wish_state"].flatMap(WishState.init(rawValue:)))
                        #expect(pe.chaseOutcome == r.detail["chase_outcome"].flatMap(ChaseOutcome.init(rawValue:)))
                        #expect(pe.growthStage?.name == r.detail["stage"].flatMap { s in
                            GrowthStage.allCases.first { $0.name == s }?.name
                        })
                    }

                    // user 消息逐行检查：每个字段都是「时间 类型 key=白名单值」
                    #expect(messages.map(\.role) == ["system", "user"])
                    let lines = messages[1].content.components(separatedBy: "\n")
                    #expect(lines.first == "日期：\(c.date.description)")
                    #expect(lines.count >= 2 && lines[1] == "事件：")
                    let eventLines = Array(lines.dropFirst(2))
                    if kept.isEmpty {
                        #expect(eventLines == ["（无）"])
                        continue
                    }
                    #expect(eventLines.count == kept.count)
                    for (line, r) in zip(eventLines, kept) {
                        #expect(line.hasPrefix("- "))
                        let tokens = line.dropFirst(2).components(separatedBy: " ")
                        #expect(tokens.count >= 2)
                        guard tokens.count >= 2 else { continue }
                        #expect(tokens[0] == EventCodec.formatTime(r.time, timeZone: c.timeZone))
                        #expect(tokens[1] == r.type.rawValue)
                        for token in tokens.dropFirst(2) {
                            let kv = token.split(separator: "=", maxSplits: 1).map(String.init)
                            #expect(kv.count == 2, "bad field: \(token)")
                            guard kv.count == 2 else { continue }
                            #expect(allowedFieldValues[kv[0]]?.contains(kv[1]) == true, "bad field: \(token)")
                        }
                    }
                }
            }
        }
    }

    /// 单元示例：visit 心愿指向的应用名称、thought_shown 文本和窗口坐标都不进入 Payload。
    @Test func appNameAndThoughtNeverRendered() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            EventRecord(
                time: t, type: .wishStarted, actor: "resident_a", target: EventRecord.appRef("备忘录"),
                detail: ["wish_type": "visit", "wish_state": "active", "window_id": "4242", "x": "12.5"]),
            EventRecord(time: t, type: .thoughtShown, actor: "resident_a", detail: ["text": "悄悄话"]),
        ]
        let p = PromptBuilder.diary(
            resident: .a, date: LocalDate(year: 2023, month: 11, day: 15), events: records,
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        let all = p.messages().map(\.content).joined(separator: "\n")
        #expect(p.events.count == 1)
        #expect(!all.contains("备忘录"))
        #expect(!all.contains("悄悄话"))
        #expect(!all.contains("4242"))
        #expect(!all.contains("12.5"))
        #expect(all.contains("wish_started actor=都都 wish_type=visit wish_state=active"))
    }
}
