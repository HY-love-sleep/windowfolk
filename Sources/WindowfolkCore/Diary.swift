import Foundation

// MARK: - 本地日期

/// 某个时区下的本地日期（年、月、日），编码为 `"yyyy-MM-dd"` 字符串（Requirement 13.1、13.9）。
///
/// 比较按年、月、日的字典序。只有公历中真实存在、年份在 1...9999 的日期能被解码；
/// 构造器不做校验，由调用方（通常是 `of(_:timeZone:)`）保证合法。
public struct LocalDate: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// 绝对时间 `d` 在时区 `timeZone` 下的本地日期。
    public static func of(_ d: Date, timeZone: TimeZone) -> LocalDate {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: d)
        return LocalDate(year: c.year ?? 1, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// 该日期在 `timeZone` 下的 [当天 00:00:00, 次日 00:00:00)。
    /// 用日历计算，夏令时切换日的长度可能不是 24 小时。
    public func range(timeZone: TimeZone) -> Range<Date> {
        let cal = LocalDate.calendar(timeZone)
        let comps = DateComponents(year: year, month: month, day: day)
        let start = cal.date(from: comps).map { cal.startOfDay(for: $0) } ?? Date(timeIntervalSince1970: 0)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start..<end
    }

    /// `yyyy-MM-dd`。
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 解析 `yyyy-MM-dd`。格式不对或日期不存在（如 `2026-02-30`）时返回 nil。
    public init?(string s: String) {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              y >= 1, (1...12).contains(m), d >= 1
        else { return nil }
        let cal = LocalDate.calendar(TimeZone(identifier: "UTC") ?? .current)
        guard let first = cal.date(from: DateComponents(year: y, month: m, day: 1)),
              let days = cal.range(of: .day, in: .month, for: first),
              days.contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = LocalDate(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid local date: \(s)")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
}

// MARK: - 日记

/// Diary_Entry 的生成方式。
public enum DiaryMethod: String, Hashable, Sendable, Codable {
    case template, llm
}

/// 某位居民在某个本地日期的一篇日记（Requirement 13）。
public struct DiaryEntry: Hashable, Sendable, Codable {
    public var date: LocalDate
    public var resident: ResidentID
    public var text: String
    public var method: DiaryMethod

    public init(date: LocalDate, resident: ResidentID, text: String, method: DiaryMethod) {
        self.date = date
        self.resident = resident
        self.text = text
        self.method = method
    }

    /// 该篇所属的（日期，居民）。
    public var key: DiaryKey { DiaryKey(date: date, resident: resident) }
}

/// 日记的唯一定位：同一居民、同一本地日期最多一篇有效日记（Requirement 13.10）。
public struct DiaryKey: Hashable, Sendable {
    public var date: LocalDate
    public var resident: ResidentID

    public init(date: LocalDate, resident: ResidentID) {
        self.date = date
        self.resident = resident
    }
}
