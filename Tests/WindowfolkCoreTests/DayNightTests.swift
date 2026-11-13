import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// MARK: - 生成器

/// 一个 Night 判定样本：时区下的本地日期与时刻、覆盖和 Night 时段。
///
/// 时区用固定偏移（-12:00 到 +14:00，15 分钟步长），这样期望值可以直接从生成的本地时刻算出，
/// 不依赖 `Calendar`（避开夏令时缺口），与被测实现相互独立。
private struct LocalTimeCase: Sendable {
    var dayIndex: Int          // 自 1970-01-01 起的本地日序号
    var secondOfDay: Int       // 本地时刻（0..<86400）
    var subSecond: Double      // 亚秒部分（0..<1），实现应舍去
    var offsetSeconds: Int     // 时区相对 GMT 的偏移
    var override: DayNightOverride
    var nightStart: Int
    var nightEnd: Int

    var timeZone: TimeZone { TimeZone(secondsFromGMT: offsetSeconds)! }

    /// 本地时刻对应的绝对时间：本地午夜的 UTC 时间减去时区偏移。
    var now: Date {
        Date(timeIntervalSince1970:
            TimeInterval(dayIndex * 86_400 + secondOfDay - offsetSeconds) + subSecond)
    }
}

/// Night_Start 19:00:00、Night_End 06:00:00 前后的边界时刻（Requirement 5.1）。
private let boundarySeconds: [Int] = [
    0, 86_399,
    19 * 3600 - 1, 19 * 3600, 19 * 3600 + 1,
    6 * 3600 - 1, 6 * 3600, 6 * 3600 + 1,
]

private extension Gen where Value == LocalTimeCase {
    static var localTime: Generator<LocalTimeCase, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...30_000),                 // 1970 至约 2052 年
            Gen<Int>.int(in: 0...86_399),
            Gen<Int>.int(in: 0...9),                      // 选择器：0 到 3 时用边界时刻
            Gen<Int>.int(in: 0...(boundarySeconds.count - 1)),
            Gen<Double>.double(in: 0...0.999),
            Gen<Int>.int(in: -48...56),                   // 15 分钟为单位的偏移
            Gen<Int>.int(in: 0...2),
            zip(
                Gen<Int>.int(in: 0...3),                  // 选择器：0 到 2 用默认 19:00/06:00
                Gen<Int>.int(in: 1...86_399),
                Gen<Int>.int(in: 0...86_398)
            )
        ).map { day, randomSecond, pick, boundaryIndex, sub, quarter, overrideIndex, night in
            let (nightPick, rawStart, rawEnd) = night
            let second = pick <= 3 ? boundarySeconds[boundaryIndex] : randomSecond
            // 随机时段保持跨午夜（nightStart > nightEnd），与 Property 15 的「≥ Start 或 < End」一致
            let start: Int
            let end: Int
            if nightPick <= 2 {
                start = 19 * 3600
                end = 6 * 3600
            } else {
                start = max(rawStart, 1)
                end = rawEnd % start
            }
            return LocalTimeCase(
                dayIndex: day, secondOfDay: second, subSecond: sub,
                offsetSeconds: quarter * 900,
                override: DayNightOverride.allCases[overrideIndex],
                nightStart: start, nightEnd: end)
        }
    }
}

// MARK: - 属性测试

@Suite struct DayNightPropertyTests {
    // Feature: V2, Property 15: Night 判定
    // 覆盖为 night 时为真、为 day 时为假；auto 时当且仅当本地时刻（秒）≥ Night_Start 或 < Night_End。
    // **Validates: Requirements 5.1, 17.4**
    @Test func nightDecisionFollowsOverrideAndLocalTime() async {
        await propertyCheck(count: 200, input: Gen.localTime) { c in
            let result = DayNight.isNight(now: c.now, timeZone: c.timeZone, override: c.override,
                                          nightStart: c.nightStart, nightEnd: c.nightEnd)
            let expected: Bool
            switch c.override {
            case .night: expected = true
            case .day: expected = false
            case .auto: expected = c.secondOfDay >= c.nightStart || c.secondOfDay < c.nightEnd
            }
            #expect(result == expected,
                    "override=\(c.override) local=\(c.secondOfDay) offset=\(c.offsetSeconds) start=\(c.nightStart) end=\(c.nightEnd)")
        }
    }
}

// MARK: - 单元测试（任务 1.5 追加）
@Suite struct DayNightUnitTests {
    private let defaults = Tunables()

    /// 默认 Night 时段（19:00:00 → 06:00:00）下判定 `clock` 当前时刻。
    private func autoNight(_ clock: ManualLocalClock) -> Bool {
        DayNight.isNight(now: clock.now, timeZone: clock.timeZone, override: .auto, constants: defaults)
    }

    @Test func tunablesDefaultNightWindow() {
        #expect(defaults.nightStart == 19 * 3600)
        #expect(defaults.nightEnd == 6 * 3600)
    }

    @Test(arguments: [
        (18, 59, 59, false),
        (19, 0, 0, true),
        (5, 59, 59, true),
        (6, 0, 0, false),
    ])
    func boundaryTimes(hour: Int, minute: Int, second: Int, expected: Bool) {
        // 用非 GMT 时区，确认判定读的是本地时刻
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let clock = ManualLocalClock(year: 2025, month: 3, day: 14,
                                     hour: hour, minute: minute, second: second, timeZone: tz)
        #expect(autoNight(clock) == expected)
        // 与显式传 nightStart/nightEnd 的重载结果一致
        #expect(DayNight.isNight(now: clock.now, timeZone: tz, override: .auto,
                                 nightStart: 19 * 3600, nightEnd: 6 * 3600) == expected)
    }

    @Test func overrideIgnoresClock() {
        let clock = ManualLocalClock(year: 2025, month: 3, day: 14, hour: 12, minute: 0, second: 0)
        #expect(DayNight.isNight(now: clock.now, timeZone: clock.timeZone, override: .night, constants: defaults))
        clock.set(year: 2025, month: 3, day: 14, hour: 23, minute: 0, second: 0)
        #expect(!DayNight.isNight(now: clock.now, timeZone: clock.timeZone, override: .day, constants: defaults))
    }

    @Test func constantsOverloadReadsCustomValues() {
        var custom = Tunables()
        custom.nightStart = 20 * 3600
        custom.nightEnd = 5 * 3600
        let clock = ManualLocalClock(year: 2025, month: 3, day: 14, hour: 19, minute: 30, second: 0)
        #expect(autoNight(clock))
        #expect(!DayNight.isNight(now: clock.now, timeZone: clock.timeZone, override: .auto, constants: custom))
    }

    @Test func manualClockSetProducesLocalTime() {
        let tz = TimeZone(secondsFromGMT: -5 * 3600)!
        let clock = ManualLocalClock(year: 2025, month: 1, day: 2, hour: 7, minute: 8, second: 9, timeZone: tz)
        #expect(DayNight.secondOfDay(now: clock.now, timeZone: tz) == 7 * 3600 + 8 * 60 + 9)
        // 本地 07:08:09（UTC-5）= UTC 12:08:09
        #expect(DayNight.secondOfDay(now: clock.now, timeZone: TimeZone(secondsFromGMT: 0)!)
                == 12 * 3600 + 8 * 60 + 9)

        clock.set(year: 2025, month: 1, day: 2, hour: 23, minute: 59, second: 59)
        #expect(DayNight.secondOfDay(now: clock.now, timeZone: tz) == 86_399)
    }

    @Test func manualClockAdvanceCrossesBoundaries() {
        let clock = ManualLocalClock(year: 2025, month: 3, day: 14, hour: 18, minute: 59, second: 59)
        let start = clock.now
        #expect(!autoNight(clock))

        clock.advance(by: 1)                       // 19:00:00
        #expect(clock.now.timeIntervalSince(start) == 1)
        #expect(autoNight(clock))

        clock.advance(by: 11 * 3600 - 1)           // 次日 05:59:59
        #expect(DayNight.secondOfDay(now: clock.now, timeZone: clock.timeZone) == 6 * 3600 - 1)
        #expect(autoNight(clock))

        clock.advance(by: 1)                       // 次日 06:00:00
        #expect(!autoNight(clock))

        clock.advance(by: -1)                      // 负值向后退回 05:59:59
        #expect(autoNight(clock))
    }
}
