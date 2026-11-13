import Foundation

// MARK: - 白名单类型

/// 可以出现在 Prompt_Payload 中的居民名字。只有都都（Resident_A）和嘟嘟（Resident_B）。
public enum ResidentName: String, Hashable, Sendable, Codable, CaseIterable {
    case dudu = "都都"
    case doodoo = "嘟嘟"

    public init(_ id: ResidentID) {
        switch id {
        case .a: self = .dudu
        case .b: self = .doodoo
        }
    }

    /// 事件记录中的 `actor` / `target` 只有恰好等于 `resident_a` 或 `resident_b` 时才映射；
    /// 其他标识（`app:<名称>`、`plank:3`、`decor:5`、`player` 等）返回 nil。
    public init?(ref: String?) {
        guard let ref, let id = ResidentID(rawValue: ref) else { return nil }
        self.init(id)
    }
}

/// 发送给 LLM 的一条事件摘要（Requirement 12.1）。
///
/// 每个字段都是封闭枚举或 `Date`，没有任何 `String` 字段，
/// 因此应用名称、窗口 ID、坐标和 Thought 文本在类型上就无法放进来。
public struct PromptEvent: Hashable, Sendable, Codable {
    public var type: EventType
    public var time: Date
    public var actor: ResidentName?
    public var target: ResidentName?
    public var decorType: DecorType?
    public var wishType: WishType?
    public var wishState: WishState?
    public var chaseOutcome: ChaseOutcome?
    public var growthStage: GrowthStage?

    public init(
        type: EventType, time: Date, actor: ResidentName? = nil, target: ResidentName? = nil,
        decorType: DecorType? = nil, wishType: WishType? = nil, wishState: WishState? = nil,
        chaseOutcome: ChaseOutcome? = nil, growthStage: GrowthStage? = nil
    ) {
        self.type = type
        self.time = time
        self.actor = actor
        self.target = target
        self.decorType = decorType
        self.wishType = wishType
        self.wishState = wishState
        self.chaseOutcome = chaseOutcome
        self.growthStage = growthStage
    }
}

/// Payload 的用途：为某位居民写日记，或生成某位居民的一条 Thought。
public enum PromptPurpose: Hashable, Sendable {
    case diary(ResidentName)
    case thought(ResidentName)

    public var resident: ResidentName {
        switch self {
        case .diary(let n), .thought(let n): return n
        }
    }
}

// MARK: - Payload

/// 发送给 LLM_Client 的全部内容（Requirement 12.1、12.2）。
///
/// `messages()` 只由内置固定文本、`ResidentName`、`EventType` 和各白名单枚举的取值、
/// ISO 8601 时间和本地日期拼成。`timeZone` 只用于把时间格式化为本地带偏移的写法，本身不输出。
public struct PromptPayload: Hashable, Sendable {
    public var purpose: PromptPurpose
    public var localDate: LocalDate
    public var events: [PromptEvent]
    public var timeZone: TimeZone

    public init(purpose: PromptPurpose, localDate: LocalDate, events: [PromptEvent], timeZone: TimeZone) {
        self.purpose = purpose
        self.localDate = localDate
        self.events = events
        self.timeZone = timeZone
    }

    /// 内置固定提示文本，按 purpose 选择。只插入居民名字。
    public var systemText: String {
        switch purpose {
        case .diary(let n):
            let other = n == .dudu ? ResidentName.doodoo : .dudu
            return """
                你是住在电脑桌面窗口上的小居民「\(n.rawValue)」，和「\(other.rawValue)」是邻居。\
                请根据下面列出的当天事件，以第一人称、\(n.rawValue)的口吻写一篇简短的日记。\
                只写列出的事件，不要编造其他地点、人物或名称。直接输出日记正文，不要标题。
                """
        case .thought(let n):
            let other = n == .dudu ? ResidentName.doodoo : .dudu
            return """
                你是住在电脑桌面窗口上的小居民「\(n.rawValue)」，和「\(other.rawValue)」是邻居。\
                请根据下面列出的最近事件，以第一人称、\(n.rawValue)的口吻说一句很短的心里话。\
                只输出这一句话，不要换行，不要引号。
                """
        }
    }

    /// 渲染为 Chat 消息：一条 system（`systemText`），一条 user（日期与事件列表）。
    public func messages() -> [(role: String, content: String)] {
        [(role: "system", content: systemText), (role: "user", content: userText)]
    }

    var userText: String {
        var lines = ["日期：\(localDate.description)", "事件："]
        if events.isEmpty {
            lines.append("（无）")
        }
        for e in events {
            var parts = [EventCodec.formatTime(e.time, timeZone: timeZone), e.type.rawValue]
            if let a = e.actor { parts.append("actor=\(a.rawValue)") }
            if let t = e.target { parts.append("target=\(t.rawValue)") }
            if let v = e.decorType { parts.append("decor_type=\(v.rawValue)") }
            if let v = e.wishType { parts.append("wish_type=\(v.rawValue)") }
            if let v = e.wishState { parts.append("wish_state=\(v.rawValue)") }
            if let v = e.chaseOutcome { parts.append("chase_outcome=\(v.rawValue)") }
            if let v = e.growthStage { parts.append("stage=\(v.name)") }
            lines.append("- " + parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 构造

/// 把事件记录映射成 Prompt_Payload。这是 Diary_Writer 和 Thought_Engine 向 LLM 提供世界信息的唯一途径。
public enum PromptBuilder {
    /// `detail` 中会被读取的全部键。其他键（包括 `thought_shown` 的 `text`）一律忽略。
    public static let detailWhitelist: Set<String> = [
        "decor_type", "wish_type", "wish_state", "chase_outcome", "stage",
    ]

    /// 映射一条事件记录。`thought_shown` 除 Thought 文本外没有可用信息，不进入 Payload，返回 nil。
    public static func event(_ r: EventRecord) -> PromptEvent? {
        if r.type == .thoughtShown { return nil }
        return PromptEvent(
            type: r.type,
            time: r.time,
            actor: ResidentName(ref: r.actor),
            target: ResidentName(ref: r.target),
            decorType: r.detail["decor_type"].flatMap(DecorType.init(rawValue:)),
            wishType: r.detail["wish_type"].flatMap(WishType.init(rawValue:)),
            wishState: r.detail["wish_state"].flatMap(WishState.init(rawValue:)),
            chaseOutcome: r.detail["chase_outcome"].flatMap(ChaseOutcome.init(rawValue:)),
            growthStage: r.detail["stage"].flatMap { s in GrowthStage.allCases.first { $0.name == s } })
    }

    /// 日记 Payload。`events` 由调用方选好（该居民该日期的相关事件），按原顺序映射（Requirement 13.6）。
    public static func diary(
        resident: ResidentID, date: LocalDate, events: [EventRecord], timeZone: TimeZone
    ) -> PromptPayload {
        PromptPayload(
            purpose: .diary(ResidentName(resident)), localDate: date,
            events: events.compactMap(event), timeZone: timeZone)
    }

    /// Thought Payload。`recent` 为 Event_Log 中最近的事件（Requirement 14.1）。
    public static func thought(
        actor: ResidentID, recent: [EventRecord], date: LocalDate, timeZone: TimeZone = .current
    ) -> PromptPayload {
        PromptPayload(
            purpose: .thought(ResidentName(actor)), localDate: date,
            events: recent.compactMap(event), timeZone: timeZone)
    }
}
