import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// MARK: - 生成器

/// 发起方 / 作用对象标识池：两位居民、玩家、无、应用与摆件引用。
fileprivate let diaryRefPool: [String?] = [
    "resident_a", "resident_b", "player", nil, "app:Safari", "decor:1",
]

/// 一行 Event_Log 的生成规格。
///
/// 合法行的 `time` 用任意固定偏移（15 分钟步长）书写；非法行分三类：不是 JSON、缺字段、时间无法解析。
/// 非法行的 actor 固定为被测居民，若实现误收这些行会被检出。
fileprivate struct DiaryLineSpec: Sendable {
    /// 0：非法 JSON；1：缺 `detail` 字段；2：时间无法解析；其余：合法行。
    var kind: Int
    /// 相对目标日期本地 00:00:00 的秒偏移。
    var delta: Int
    /// 写入该行时使用的时区偏移（秒）。
    var lineOffset: Int
    var type: EventType
    var actor: String?
    var target: String?

    var isValid: Bool { kind >= 3 }
}

/// 一个用例：Local_Clock 时区（固定偏移）、目标日期（自 1970-01-01 起的日序号）、居民和事件行。
fileprivate struct DiaryRelevanceCase: Sendable {
    var dayIndex: Int
    var clockOffset: Int
    var resident: ResidentID
    var lines: [DiaryLineSpec]

    var timeZone: TimeZone { TimeZone(secondsFromGMT: clockOffset)! }

    /// 目标日期：日序号对应的公历日期（用 UTC 换算，与时区无关）。
    var date: LocalDate {
        LocalDate.of(Date(timeIntervalSince1970: TimeInterval(dayIndex * 86_400)),
                     timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    /// 某行的绝对时间：目标日期本地午夜（UTC 时间减去时区偏移）加上 `delta`。
    func time(of line: DiaryLineSpec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(dayIndex * 86_400 - clockOffset + line.delta))
    }
}

/// 日界附近的偏移：前一天最后一秒、当天第一秒、当天最后一秒、次日 00:00:00。
fileprivate let diaryBoundaryDeltas: [Int] = [-1, 0, 1, 86_399, 86_400, 86_401]

fileprivate extension Gen where Value == DiaryLineSpec {
    static var diaryLine: Generator<DiaryLineSpec, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...9),
            Gen<Int>.int(in: 0...3),                         // 选择器：0 时用日界偏移
            Gen<Int>.int(in: 0...(diaryBoundaryDeltas.count - 1)),
            Gen<Int>.int(in: -2 * 86_400...3 * 86_400),
            Gen<Int>.int(in: -48...56),
            Gen<Int>.int(in: 0...(EventType.allCases.count - 1)),
            Gen<Int>.int(in: 0...(diaryRefPool.count - 1)),
            Gen<Int>.int(in: 0...(diaryRefPool.count - 1))
        ).map { kind, pick, boundaryIndex, randomDelta, quarter, typeIndex, actorIndex, targetIndex in
            DiaryLineSpec(
                kind: kind,
                delta: pick == 0 ? diaryBoundaryDeltas[boundaryIndex] : randomDelta,
                lineOffset: quarter * 900,
                type: EventType.allCases[typeIndex],
                actor: diaryRefPool[actorIndex],
                target: diaryRefPool[targetIndex])
        }
    }
}

fileprivate extension Gen where Value == DiaryRelevanceCase {
    static var diaryRelevanceCase: Generator<DiaryRelevanceCase, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...30_000),                   // 1970 至约 2052 年
            Gen<Int>.int(in: -48...56),
            Gen<Int>.int(in: 0...1),
            Gen<DiaryLineSpec>.diaryLine.array(of: 0...24)
        ).map { day, quarter, residentIndex, lines in
            DiaryRelevanceCase(
                dayIndex: day, clockOffset: quarter * 900,
                resident: ResidentID.allCases[residentIndex], lines: lines)
        }
    }
}

// MARK: - 属性测试

@Suite struct DiaryWriterPropertyTests {
    /// 按规格生成一行（含行尾换行）。合法行同时返回期望解码得到的记录。
    private static func render(_ line: DiaryLineSpec, in c: DiaryRelevanceCase) -> (Data, EventRecord?) {
        let time = c.time(of: line)
        let lineTZ = TimeZone(secondsFromGMT: line.lineOffset)!
        let stamp = EventCodec.formatTime(time, timeZone: lineTZ)
        let me = EventRecord.residentRef(c.resident)
        switch line.kind {
        case 0:
            return (Data("{\"time\":\"\(stamp)\",\"type\":\"landed\",\"actor\":\"\(me)\"\n".utf8), nil)
        case 1:
            return (Data("{\"actor\":\"\(me)\",\"target\":null,\"time\":\"\(stamp)\",\"type\":\"landed\"}\n".utf8), nil)
        case 2:
            return (Data("{\"actor\":\"\(me)\",\"detail\":{},\"target\":null,\"time\":\"not-a-time\",\"type\":\"landed\"}\n".utf8), nil)
        default:
            let r = EventRecord(time: time, type: line.type, actor: line.actor, target: line.target)
            return (EventCodec.encodeLine(r, timeZone: lineTZ), r)
        }
    }

    // Feature: V2, Property 39: 日记事件归类
    // relevant 的结果恰好是合法行中换算到 Local_Clock 时区后落在该日期 [00:00:00, 次日 00:00:00) 内、
    // actor 或 target 等于该居民标识的记录，保持文件中的顺序。
    // **Validates: Requirements 13.1**
    @Test func relevantSelectsValidRecordsOfDateAndResidentInFileOrder() async {
        await propertyCheck(count: 200, input: Gen.diaryRelevanceCase) { c in
            var data = Data()
            var expected: [EventRecord] = []
            let me = EventRecord.residentRef(c.resident)
            for line in c.lines {
                let (bytes, record) = Self.render(line, in: c)
                data.append(bytes)
                // 期望值直接由生成参数算出：固定偏移时区下，本地日期内即 0 ≤ delta < 86400。
                if let record, line.delta >= 0, line.delta < 86_400,
                   record.actor == me || record.target == me {
                    expected.append(record)
                }
            }
            let parsed = EventLogReader.parse(data)
            #expect(parsed.count == c.lines.filter(\.isValid).count)
            let result = DiaryWriter.relevant(parsed, resident: c.resident, date: c.date, timeZone: c.timeZone)
            #expect(result == expected,
                    "date=\(c.date) offset=\(c.clockOffset) resident=\(c.resident) lines=\(c.lines.count)")
        }
    }
}

// MARK: - Property 40 生成器

/// 日序号对应的公历日期（用 UTC 换算，与时区无关）。
fileprivate func diaryDate(dayIndex: Int) -> LocalDate {
    LocalDate.of(Date(timeIntervalSince1970: TimeInterval(dayIndex * 86_400)),
                 timeZone: TimeZone(secondsFromGMT: 0)!)
}

/// 一条事件：落在 `base + day` 这一本地日期内的第 `second` 秒。
fileprivate struct DiaryPendingEvent: Sendable {
    var day: Int
    var second: Int
    var type: EventType
    var actor: String?
    var target: String?
}

/// 一个用例：Local_Clock 时区（固定偏移）、起始日序号、「今天」相对起始日的偏移、事件和已有日记的键。
fileprivate struct DiaryPendingCase: Sendable {
    var base: Int
    var clockOffset: Int
    var today: Int
    var events: [DiaryPendingEvent]
    /// 已有日记：（相对起始日的偏移，居民序号）。
    var existing: [(Int, Int)]

    var timeZone: TimeZone { TimeZone(secondsFromGMT: clockOffset)! }

    func record(_ e: DiaryPendingEvent) -> EventRecord {
        EventRecord(
            time: Date(timeIntervalSince1970: TimeInterval((base + e.day) * 86_400 - clockOffset + e.second)),
            type: e.type, actor: e.actor, target: e.target)
    }
}

/// 一天内的秒偏移，包含日界两端。
fileprivate let diaryDaySeconds: [Int] = [0, 1, 43_200, 86_398, 86_399]

fileprivate extension Gen where Value == DiaryPendingEvent {
    static var diaryPendingEvent: Generator<DiaryPendingEvent, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...8),
            Gen<Int>.int(in: 0...2),                         // 选择器：0 时用日界秒数
            Gen<Int>.int(in: 0...(diaryDaySeconds.count - 1)),
            Gen<Int>.int(in: 0...86_399),
            Gen<Int>.int(in: 0...(EventType.allCases.count - 1)),
            Gen<Int>.int(in: 0...(diaryRefPool.count - 1)),
            Gen<Int>.int(in: 0...(diaryRefPool.count - 1))
        ).map { day, pick, boundaryIndex, second, typeIndex, actorIndex, targetIndex in
            DiaryPendingEvent(
                day: day,
                second: pick == 0 ? diaryDaySeconds[boundaryIndex] : second,
                type: EventType.allCases[typeIndex],
                actor: diaryRefPool[actorIndex],
                target: diaryRefPool[targetIndex])
        }
    }
}

fileprivate extension Gen where Value == DiaryPendingCase {
    static var diaryPendingCase: Generator<DiaryPendingCase, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...30_000),
            Gen<Int>.int(in: -48...56),
            Gen<Int>.int(in: 0...9),
            Gen<DiaryPendingEvent>.diaryPendingEvent.array(of: 0...24),
            zip(Gen<Int>.int(in: 0...9), Gen<Int>.int(in: 0...1)).array(of: 0...12)
        ).map { base, quarter, today, events, existing in
            DiaryPendingCase(
                base: base, clockOffset: quarter * 900, today: today,
                events: events, existing: existing)
        }
    }
}

@Suite struct DiaryPendingPropertyTests {
    // Feature: V2, Property 40: 需要补写的日记
    // pending 恰好返回所有「日期早于今天、该居民在该日期有至少 1 条相关事件、existing 中没有」的（日期，居民），
    // 每个最多一次，按（日期，居民）排序。
    // **Validates: Requirements 13.2, 13.3, 13.13**
    @Test func pendingReturnsEachMissingPastKeyWithRelevantEventsOnce() async {
        await propertyCheck(count: 200, input: Gen.diaryPendingCase) { c in
            let residents = ResidentID.allCases
            let existingPairs = Set(c.existing.map { "\($0.0)-\($0.1)" })

            // 期望值由生成参数直接算出：固定偏移时区下，事件的本地日期即 base + day。
            var expectedPairs = Set<[Int]>()
            for e in c.events where e.day < c.today {
                for (i, id) in residents.enumerated() {
                    let ref = EventRecord.residentRef(id)
                    guard e.actor == ref || e.target == ref,
                          !existingPairs.contains("\(e.day)-\(i)") else { continue }
                    expectedPairs.insert([e.day, i])
                }
            }
            let expected = expectedPairs.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }.map {
                DiaryKey(date: diaryDate(dayIndex: c.base + $0[0]), resident: residents[$0[1]])
            }

            let existing = Set(c.existing.map {
                DiaryKey(date: diaryDate(dayIndex: c.base + $0.0), resident: residents[$0.1])
            })
            let result = DiaryWriter.pending(
                events: c.events.map(c.record), existing: existing,
                before: diaryDate(dayIndex: c.base + c.today), timeZone: c.timeZone)

            #expect(result == expected,
                    "base=\(c.base) offset=\(c.clockOffset) today=\(c.today) events=\(c.events.count) existing=\(c.existing)")
            #expect(Set(result).count == result.count)
        }
    }
}
