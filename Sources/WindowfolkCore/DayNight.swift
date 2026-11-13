import Foundation

/// 本地时钟（Local_Clock）：提供当前时刻和所在时区（Requirement 5.1、19.2）。
/// 应用层用 `SystemLocalClock`，测试用 `ManualLocalClock`。
public protocol LocalClock: Sendable {
    var now: Date { get }
    var timeZone: TimeZone { get }
}

/// 读取系统时间和系统当前时区。
public struct SystemLocalClock: LocalClock {
    public init() {}
    public var now: Date { Date() }
    public var timeZone: TimeZone { TimeZone.current }
}

/// 测试替身：可设为任意本地日期时刻，也可向前推进任意时长，不需要实际等待（Requirement 19.2）。
/// 只在单线程测试中使用，因此标为 `@unchecked Sendable`。
public final class ManualLocalClock: LocalClock, @unchecked Sendable {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = Date(timeIntervalSince1970: 0), timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) {
        self.now = now
        self.timeZone = timeZone
    }

    /// 便利构造：直接设为 `timeZone` 下的某个本地日期时刻。
    public convenience init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
                            timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) {
        self.init(timeZone: timeZone)
        set(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// 把 `now` 设为当前 `timeZone` 下的本地日期时刻（公历）。
    public func set(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else {
            preconditionFailure("ManualLocalClock.set: 无效日期 \(components)")
        }
        now = date
    }

    /// 向前（或负值时向后）推进 `seconds` 秒。
    public func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Debug_Menu「昼夜」覆盖（Requirement 17.4）。不保存，启动时为 `.auto`。
public enum DayNightOverride: String, Hashable, Sendable, CaseIterable {
    case auto, day, night
}

/// Night 判定（Requirement 5.1）。
public enum DayNight {
    /// `timeZone` 下 `now` 的本地时刻，换算为一天中的秒数（0..<86400，舍去亚秒）。
    public static func secondOfDay(now: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: now)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    /// 秒级比较：覆盖为 `.night` 恒真，`.day` 恒假；`.auto` 时本地时刻 >= nightStart 或 < nightEnd 为 Night。
    /// `nightStart`、`nightEnd` 为一天中的秒数。
    public static func isNight(now: Date, timeZone: TimeZone, override: DayNightOverride,
                               nightStart: Int, nightEnd: Int) -> Bool {
        switch override {
        case .night: return true
        case .day: return false
        case .auto:
            let s = secondOfDay(now: now, timeZone: timeZone)
            if nightStart > nightEnd {
                // 跨午夜（默认 19:00 → 次日 06:00）
                return s >= nightStart || s < nightEnd
            } else {
                // 不跨午夜的配置：[nightStart, nightEnd)
                return s >= nightStart && s < nightEnd
            }
        }
    }

    /// 按 `Tunables` 中的 Night_Start、Night_End 判定。
    public static func isNight(now: Date, timeZone: TimeZone, override: DayNightOverride,
                               constants: Tunables) -> Bool {
        isNight(now: now, timeZone: timeZone, override: override,
                nightStart: constants.nightStart, nightEnd: constants.nightEnd)
    }
}
