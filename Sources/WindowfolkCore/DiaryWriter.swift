import Foundation

// Diary_Writer：按日期归类事件、找出需要补写的日记、用模板或 LLM 生成正文
// （design.md「Core：日记」，Requirement 13、22.8）。

// MARK: - 模板

/// 日记模板（Requirement 13.5、22.8）。
///
/// 每种事件类型对应一个固定句式，用写日记的居民的视角书写，提到另一位居民时用其名字。
/// 句式只由事件类型、写日记者是 `actor` 还是 `target`，以及 `detail` 中的 Wish_Type、
/// Decor_Type、Chase_Outcome 决定，不读取应用名称或其他自由文本，同样的输入逐字符相同。
public enum DiaryTemplates {
    /// 一条事件对应的句子。
    ///
    /// 写日记者既不是 `actor` 也不是 `target` 时返回 nil（不是该居民的相关事件）；
    /// `thought_shown` 不适合写进日记，返回 nil。
    public static func sentence(for r: EventRecord, writer: ResidentID) -> String? {
        let me = EventRecord.residentRef(writer)
        let isActor = r.actor == me
        guard isActor || r.target == me else { return nil }
        let other = ResidentName(writer == .a ? .b : .a).rawValue
        // 写日记者是 target 时，另一位居民是 actor 才用「对方做了什么」的句式。
        let otherIsActor = !isActor && r.actor == EventRecord.residentRef(writer == .a ? .b : .a)
        let otherIsTarget = isActor && r.target == EventRecord.residentRef(writer == .a ? .b : .a)
        let wish = r.detail["wish_type"].flatMap(WishType.init(rawValue:))
        let decor = r.detail["decor_type"].flatMap(DecorType.init(rawValue:))

        switch r.type {
        case .thoughtShown:
            return nil
        case .crossedBridge:
            return "我走过了一座木板桥。"
        case .climbedLadder:
            return "我爬了一次梯子。"
        case .fell:
            return "我不小心掉了下去。"
        case .landed:
            return "我稳稳地落了地。"
        case .waitingStarted:
            if otherIsTarget { return "我停下来等\(other)。" }
            if otherIsActor { return "\(other)停下来等我。" }
            return "我停下来等了一会儿。"
        case .roundStarted:
            return "新的一轮开始了。"
        case .planted:
            if otherIsTarget { return "我为\(other)种下了一盆花。" }
            if otherIsActor { return "\(other)为我种下了一盆花。" }
            return "我种下了一盆花。"
        case .sprouted:
            return "花发芽了。"
        case .bloomed:
            return "花开了。"
        case .giftDelivered:
            if otherIsTarget { return "我把果子送给了\(other)。" }
            if otherIsActor { return "\(other)送给我一个果子。" }
            return "我收到了一个果子。"
        case .plankPlaced:
            return "有人帮我架起了一块木板。"
        case .plankDropped:
            return "一块木板掉了下去。"
        case .ladderPlaced:
            return "有人帮我搭起了一架梯子。"
        case .ladderDropped:
            return "一架梯子掉了下去。"
        case .decorUnlocked:
            return "多了一\(decorPhrase(decor))可以用了。"
        case .decorPlaced:
            return "有人摆好了一\(decorPhrase(decor))。"
        case .decorRemoved:
            return "一\(decorPhrase(decor))被收走了。"
        case .wishStarted:
            if otherIsActor { return "\(other)想\(wishPhrase(wish, otherForTarget: other))。" }
            return "我想\(wishPhrase(wish, other: other))。"
        case .wishDropped:
            if otherIsActor { return "\(other)想\(wishPhrase(wish, otherForTarget: other))，这次先算了。" }
            return "我想\(wishPhrase(wish, other: other))，这次先算了。"
        case .wishFulfilled:
            return fulfilled(wish: wish, record: r, writer: writer, other: other, otherIsActor: otherIsActor)
        case .visited:
            if otherIsTarget { return "我去找\(other)玩了。" }
            if otherIsActor { return "\(other)来找我玩了。" }
            return "我去别的窗口看了看。"
        case .sat:
            return "我在椅子上坐了一会儿。"
        case .slept:
            return "我在台灯旁睡了一觉。"
        case .woke:
            return "我醒了过来。"
        }
    }

    /// 依次取每条事件的句子，跳过 nil，直接拼接（中文句子自带句号，不加分隔符）。不截断。
    public static func text(writer: ResidentID, events: [EventRecord]) -> String {
        events.compactMap { sentence(for: $0, writer: writer) }.joined()
    }

    /// Chase_Wish 的 4 种句式（Requirement 22.8）：Chaser 固定为 Resident_A，Runner 固定为 Resident_B。
    /// 都不含「输」「赢」「失败」。
    public static func chaseSentence(writer: ResidentID, outcome: ChaseOutcome) -> String {
        switch (writer, outcome) {
        case (.a, .caught): return "和嘟嘟玩追逐，我抓到嘟嘟啦。"
        case (.a, .escaped): return "和嘟嘟玩追逐，我没抓到嘟嘟，它跑得真快。"
        case (.b, .caught): return "和都都玩追逐，我被都都抓到了。"
        case (.b, .escaped): return "和都都玩追逐，我没被都都抓到。"
        }
    }

    private static func fulfilled(
        wish: WishType?, record r: EventRecord, writer: ResidentID, other: String, otherIsActor: Bool
    ) -> String {
        switch wish {
        case .chase?:
            if let outcome = r.detail["chase_outcome"].flatMap(ChaseOutcome.init(rawValue:)) {
                return chaseSentence(writer: writer, outcome: outcome)
            }
            return "和\(other)玩了一场追逐。"
        case .flower?:
            return otherIsActor ? "\(other)想给我送花的心愿实现了。" : "我想给\(other)送花的心愿实现了。"
        case .chair?:
            return otherIsActor ? "\(other)有椅子坐了。" : "我终于有椅子坐了。"
        case .lamp?:
            return otherIsActor ? "\(other)的夜里有台灯陪着了。" : "夜里有台灯陪着我了。"
        case .visit?:
            return otherIsActor ? "\(other)去看了想看的那扇窗。" : "我去看了想看的那扇窗。"
        case nil:
            return otherIsActor ? "\(other)的心愿实现了。" : "我的心愿实现了。"
        }
    }

    /// 写日记者是 Wisher 时「我想……」后面的内容。
    private static func wishPhrase(_ w: WishType?, other: String) -> String {
        switch w {
        case .flower?: return "给\(other)送花"
        case .chair?: return "要一把椅子"
        case .lamp?: return "要一盏台灯"
        case .visit?: return "去别的窗口看看"
        case .chase?: return "和\(other)玩追逐"
        case nil: return "做一件小事"
        }
    }

    /// 另一位是 Wisher、写日记者是 target 时「某某想……」后面的内容。
    private static func wishPhrase(_ w: WishType?, otherForTarget other: String) -> String {
        switch w {
        case .flower?: return "给我送花"
        case .chase?: return "和我玩追逐"
        default: return wishPhrase(w, other: other)
        }
    }

    private static func decorPhrase(_ d: DecorType?) -> String {
        switch d {
        case .chair?: return "把椅子"
        case .lamp?: return "盏台灯"
        case nil: return "件小摆设"
        }
    }
}

// MARK: - Diary_Writer

/// 生成日记（Requirement 13.1 至 13.8、13.13）。
public struct DiaryWriter: Sendable {
    public let client: (any LLMClient)?
    /// Diary_Max_Length，按 Unicode 字素计。
    public let maxLength: Int

    public init(client: (any LLMClient)?, maxLength: Int) {
        self.client = client
        self.maxLength = maxLength
    }

    /// 某居民在某日期的相关事件：`time` 换算到 `timeZone` 后落在 `date` 内，
    /// 且 `actor` 或 `target` 等于该居民标识。保持输入顺序（Requirement 13.1）。
    public static func relevant(
        _ events: [EventRecord], resident: ResidentID, date: LocalDate, timeZone: TimeZone
    ) -> [EventRecord] {
        let range = date.range(timeZone: timeZone)
        let me = EventRecord.residentRef(resident)
        return events.filter { (($0.actor == me) || ($0.target == me)) && range.contains($0.time) }
    }

    /// 需要补写的（日期，居民）：日期早于 `today`、该居民在该日期有相关事件、`existing` 中没有。
    /// 每个最多一次，按日期从早到晚、同日按居民标识排序（Requirement 13.2、13.3、13.13）。
    public static func pending(
        events: [EventRecord], existing: Set<DiaryKey>, before today: LocalDate, timeZone: TimeZone
    ) -> [DiaryKey] {
        var keys = Set<DiaryKey>()
        for e in events {
            let date = LocalDate.of(e.time, timeZone: timeZone)
            guard date < today else { continue }
            for id in ResidentID.allCases {
                let ref = EventRecord.residentRef(id)
                guard e.actor == ref || e.target == ref else { continue }
                let key = DiaryKey(date: date, resident: id)
                if !existing.contains(key) { keys.insert(key) }
            }
        }
        return keys.sorted { ($0.date, $0.resident) < ($1.date, $1.resident) }
    }

    /// 按字素截断到 `maxLength`；不超过时原样返回（Requirement 13.8）。
    public static func truncate(_ text: String, maxLength: Int) -> String {
        String(text.prefix(max(0, maxLength)))
    }

    /// 为 `key` 生成一篇日记。`events` 应为 `relevant` 选出的相关事件，本方法不再过滤。
    ///
    /// `config` 为 nil（「日记使用 LLM」关闭或设置不完整）或没有 client 时用模板；
    /// 否则请求 LLM，失败（超时、HTTP 错误、空白文本等）时改用模板，不重试（Requirement 13.5 至 13.7）。
    /// 正文最后截断到 Diary_Max_Length（Requirement 13.8）。
    public func write(
        _ key: DiaryKey, events: [EventRecord], config: LLMRequestConfig?, timeZone: TimeZone
    ) async -> DiaryEntry {
        if let config, let client {
            let payload = PromptBuilder.diary(
                resident: key.resident, date: key.date, events: events, timeZone: timeZone)
            if case .success(let text) = LLMTimeout.validate(await client.complete(payload, config: config)) {
                return entry(key, text: text, method: .llm)
            }
        }
        return entry(key, text: DiaryTemplates.text(writer: key.resident, events: events), method: .template)
    }

    private func entry(_ key: DiaryKey, text: String, method: DiaryMethod) -> DiaryEntry {
        DiaryEntry(
            date: key.date, resident: key.resident,
            text: DiaryWriter.truncate(text, maxLength: maxLength), method: method)
    }
}
