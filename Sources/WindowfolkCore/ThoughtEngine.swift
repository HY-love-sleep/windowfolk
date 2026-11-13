import Foundation

/// Thought_Engine：Thought 的纯状态机（Requirement 14）。
///
/// 每帧由 `WorldEngine` 在全部事件产生后调用一次 `step`：输入本帧事件、上一帧以来回到主线程的 LLM 结果、
/// 「小心思」开关和需要压制 Thought 的居民集合，输出要发出的请求和本帧开始显示的 `thought_shown` 记录。
/// 不做任何 IO，也从不等待 LLM（Requirement 12.5）。
public struct ThoughtEngine: Hashable, Sendable {
    /// 进行中的请求；同一时刻至多一个（Requirement 14.9）。
    public var inFlight: ThoughtInFlight?
    /// 本次启动内最近一次开始显示 Thought 的时间；尚未显示过时为 nil（Requirement 14.1）。
    public var lastShownAt: Date?
    /// Event_Log 中最近的事件，最多 `Tunables.recentEventCount` 条，按时间从旧到新。
    public var recent: [EventRecord]
    /// 下一次请求使用的 id。
    public private(set) var nextID: UInt64

    /// 会触发 Thought 请求的事件类型（Requirement 14.1）。
    public static let triggerTypes: Set<EventType> = [.wishFulfilled, .landed, .woke, .visited]

    public init(
        inFlight: ThoughtInFlight? = nil, lastShownAt: Date? = nil, recent: [EventRecord] = [],
        nextID: UInt64 = 1
    ) {
        self.inFlight = inFlight
        self.lastShownAt = lastShownAt
        self.recent = recent
        self.nextID = nextID
    }

    // MARK: - 文本规整

    /// 文本规整（Requirement 14.2、14.7）：每段连续换行（`\r`、`\n`、`\r\n`）替换为一个空格，去首尾空白，
    /// 按 Unicode 字素截断到不超过 `maxLength` 个 Character，再去一次尾部空白。结果为空时返回 nil。
    public static func normalize(_ raw: String, maxLength: Int) -> String? {
        // `\r\n` 在 Swift 中是一个 Character，正则按 Unicode 标量匹配，同样会被替换。
        let joined = raw.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(trimmed.prefix(max(0, maxLength)))
        let result = trimTrailingWhitespace(cut)
        return result.isEmpty ? nil : result
    }

    private static func trimTrailingWhitespace(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let isSpace = s[prev].unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            if !isSpace { break }
            end = prev
        }
        return String(s[s.startIndex..<end])
    }

    // MARK: - 每帧推进

    /// 推进一帧，依次：关闭、收结果、移除、发请求。
    ///
    /// - Parameters:
    ///   - events: 本帧产生的全部事件，按产生顺序。
    ///   - results: 自上一帧以来返回的 `(请求 id, 结果)`；只有 id 等于进行中请求的结果会被处理。
    ///   - enabled: 「小心思」开关（已经过配置合法性判定）。
    ///   - residents: 居民表；本方法只写 `Resident.thought`。
    ///   - suppressed: 处于 `falling`、`hanging`、`sleeping`、附着在 Hidden_Window 上或世界隐藏的居民（Requirement 14.3）。
    ///   - now: 当前时间。
    ///   - timeZone: Local_Clock 时区，用于 Payload 的本地日期与时间格式。
    /// - Returns: 本帧发出的请求（至多一个）和本帧开始显示的 `thought_shown` 记录。
    public mutating func step(
        events: [EventRecord], results: [(UInt64, ThoughtResult)], enabled: Bool,
        residents: inout [ResidentID: Resident], suppressed: Set<ResidentID>,
        now: Date, timeZone: TimeZone = .current, constants: Tunables
    ) -> (requests: [ThoughtRequest], shown: [EventRecord]) {
        // 1. 关闭：丢弃进行中请求，移除全部显示中的 Thought（Requirement 14.10）。
        if !enabled {
            inFlight = nil
            for id in residents.keys where residents[id]?.thought != nil {
                residents[id]?.thought = nil
            }
        }

        // 2. 收结果：只认进行中请求的 id（Requirement 12.4、14.10）。
        var shown: [EventRecord] = []
        for (id, result) in results {
            guard let pending = inFlight, pending.id == id else { continue }
            inFlight = nil
            guard case .text(let raw) = result,
                let text = ThoughtEngine.normalize(raw, maxLength: constants.thoughtMaxLength)
            else { continue }  // 失败或规整后为空：不显示，不改 lastShownAt（Requirement 14.5）
            guard !suppressed.contains(pending.resident), residents[pending.resident] != nil else {
                continue  // 尚未显示就丢弃：不写记录，不计入间隔（Requirement 14.3）
            }
            residents[pending.resident]?.thought = ThoughtDisplay(
                text: text, until: now.addingTimeInterval(constants.thoughtDisplayDuration))
            lastShownAt = now
            shown.append(
                EventRecord(
                    time: now, type: .thoughtShown, actor: EventRecord.residentRef(pending.resident),
                    detail: ["text": text]))
        }

        // 3. 移除：显示到时或居民被压制时，同帧清除（Requirement 14.2、14.3）。
        for id in residents.keys {
            guard let t = residents[id]?.thought else { continue }
            if now >= t.until || suppressed.contains(id) {
                residents[id]?.thought = nil
            }
        }

        // 4. 发请求（Requirement 14.1、14.9）。本帧事件与 thought_shown 记录都进入最近事件窗口。
        appendRecent(events + shown, limit: constants.recentEventCount)
        var requests: [ThoughtRequest] = []
        let intervalOK = lastShownAt.map { now.timeIntervalSince($0) >= constants.thoughtMinInterval } ?? true
        if enabled, inFlight == nil, intervalOK,
            let actor = events.lazy.compactMap({ ThoughtEngine.triggerActor($0) }).first
        {
            let id = nextID
            nextID &+= 1
            inFlight = ThoughtInFlight(id: id, resident: actor)
            let payload = PromptBuilder.thought(
                actor: actor, recent: recent, date: LocalDate.of(now, timeZone: timeZone), timeZone: timeZone)
            requests.append(ThoughtRequest(id: id, resident: actor, payload: payload))
        }
        return (requests, shown)
    }

    /// 事件可触发 Thought 时返回其 `actor` 居民。
    static func triggerActor(_ e: EventRecord) -> ResidentID? {
        guard triggerTypes.contains(e.type), let ref = e.actor else { return nil }
        return ResidentID(rawValue: ref)
    }

    private mutating func appendRecent(_ new: [EventRecord], limit: Int) {
        recent.append(contentsOf: new)
        let keep = max(0, limit)
        if recent.count > keep {
            recent.removeFirst(recent.count - keep)
        }
    }
}
