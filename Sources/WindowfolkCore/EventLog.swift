import Foundation

// MARK: - 事件类型与记录

/// Event_Log 记录的事件类型，恰好 14 种（Requirement 21.1）。列表之外的事件不写入。
public enum EventType: String, Hashable, Sendable, Codable, CaseIterable {
    case crossedBridge = "crossed_bridge"
    case climbedLadder = "climbed_ladder"
    case fell
    case landed
    case waitingStarted = "waiting_started"
    case roundStarted = "round_started"
    case planted
    case sprouted
    case bloomed
    case giftDelivered = "gift_delivered"
    case plankPlaced = "plank_placed"
    case plankDropped = "plank_dropped"
    case ladderPlaced = "ladder_placed"
    case ladderDropped = "ladder_dropped"
}

/// 一条事件记录。字段固定为 `time`、`type`、`actor`、`target`、`detail`（Requirement 21.3）。
///
/// `time` 在构造时向下截断到整秒，保证编码再解码后与原值相等（Requirement 21.4、21.9）。
public struct EventRecord: Hashable, Sendable {
    /// 玩家作为发起方时的 `actor` 标识。
    public static let playerActor = "player"

    public var time: Date {
        didSet { time = EventRecord.truncateToSecond(time) }
    }
    public var type: EventType
    /// 发起方：`resident_a`、`resident_b`、`player`，没有发起方时为 nil（编码为 JSON `null`）。
    public var actor: String?
    /// 作用对象标识，没有时为 nil（编码为 JSON `null`）。
    public var target: String?
    /// 附加信息；没有时为空对象。
    public var detail: [String: String]

    public init(
        time: Date, type: EventType, actor: String? = nil, target: String? = nil,
        detail: [String: String] = [:]
    ) {
        self.time = EventRecord.truncateToSecond(time)
        self.type = type
        self.actor = actor
        self.target = target
        self.detail = detail
    }

    /// 居民作为发起方或作用对象时的标识。
    public static func residentRef(_ id: ResidentID) -> String { id.rawValue }

    /// 涉及窗口时的标识：只写所属应用名称，从不写窗口标题（Requirement 21.8）。
    public static func appRef(_ ownerName: String) -> String { "app:\(ownerName)" }

    static func truncateToSecond(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970).rounded(.down))
    }
}

// MARK: - 编解码

public enum EventCodecError: Error, Equatable, Sendable {
    case invalidTime(String)
    case unexpectedKeys([String])
}

/// 事件记录与一行 JSON 之间的编解码。
public enum EventCodec {
    /// 编码为一行 UTF-8 JSON，键按字典序，行尾恰好一个 `\n`。
    /// 字符串中的换行、引号、反斜杠由 JSONEncoder 转义，因此一条记录总是一行。
    public static func encodeLine(_ r: EventRecord, timeZone: TimeZone = .current) -> Data {
        let wire = Wire(
            time: formatTime(r.time, timeZone: timeZone), type: r.type,
            actor: r.actor, target: r.target, detail: r.detail)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Wire 只含 String、[String: String] 和 String 枚举，编码不会失败。
        var data = (try? encoder.encode(wire)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// 解码一行 JSON（允许带行尾换行）。要求恰好包含五个字段。
    public static func decodeLine(_ d: Data) throws -> EventRecord {
        var body = d
        while let last = body.last, last == 0x0A || last == 0x0D { body.removeLast() }
        let wire = try JSONDecoder().decode(Wire.self, from: body)
        guard let time = parseTime(wire.time) else { throw EventCodecError.invalidTime(wire.time) }
        return EventRecord(
            time: time, type: wire.type, actor: wire.actor, target: wire.target,
            detail: wire.detail)
    }

    /// 带时区偏移、精确到秒的 ISO 8601 字符串，例如 `2026-10-20T21:05:33+08:00`。
    /// UTC 也写为 `+00:00` 而不是 `Z`。
    public static func formatTime(_ date: Date, timeZone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        let s = f.string(from: date)
        return s.hasSuffix("Z") ? String(s.dropLast()) + "+00:00" : s
    }

    static func parseTime(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// JSON 线格式。nil 显式编码为 `null`；解码时五个键必须全部出现且不能有其他键。
    struct Wire: Codable {
        var time: String
        var type: EventType
        var actor: String?
        var target: String?
        var detail: [String: String]

        enum CodingKeys: String, CodingKey, CaseIterable { case time, type, actor, target, detail }

        init(time: String, type: EventType, actor: String?, target: String?, detail: [String: String]) {
            self.time = time; self.type = type; self.actor = actor
            self.target = target; self.detail = detail
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            let keys = Set(c.allKeys.map(\.stringValue))
            let expected = Set(CodingKeys.allCases.map(\.rawValue))
            guard keys == expected else {
                throw EventCodecError.unexpectedKeys(keys.symmetricDifference(expected).sorted())
            }
            func key(_ k: CodingKeys) -> AnyKey { AnyKey(k.rawValue) }
            time = try c.decode(String.self, forKey: key(.time))
            type = try c.decode(EventType.self, forKey: key(.type))
            actor = try c.decodeNil(forKey: key(.actor)) ? nil : c.decode(String.self, forKey: key(.actor))
            target = try c.decodeNil(forKey: key(.target)) ? nil : c.decode(String.self, forKey: key(.target))
            detail = try c.decode([String: String].self, forKey: key(.detail))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(time, forKey: .time)
            try c.encode(type, forKey: .type)
            if let actor { try c.encode(actor, forKey: .actor) } else { try c.encodeNil(forKey: .actor) }
            if let target { try c.encode(target, forKey: .target) } else { try c.encodeNil(forKey: .target) }
            try c.encode(detail, forKey: .detail)
        }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// MARK: - 输出端

/// 事件行的输出端。应用层实现为文件追加（任务 14.2），测试可用内存实现。
/// 实现必须吞掉写入失败，不抛出、不重试（Requirement 21.11）。
public protocol EventSink {
    func append(_ line: Data)
}
