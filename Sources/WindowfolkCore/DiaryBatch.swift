import Foundation

// 日记批次：决定一次批次要写哪些（日期，居民）、用哪些事件，并按顺序生成和写入
// （design.md「线程模型」中 DiaryCoordinator 的纯逻辑部分，Requirement 13.2–13.4、13.7、13.11、13.12）。
// 应用层的 `DiaryCoordinator` 负责读文件、取设置和串行调度，这里不做 I/O 以外的任何调度。

/// 触发日记批次的原因。
public enum DiaryBatchKind: Hashable, Sendable {
    /// 启动补写：早于今天、有相关事件且还没有日记的（日期，居民）（Requirement 13.3）。
    case catchUp
    /// 运行中本地日期从 `from` 变为 `to`：补写 `from` 起、早于 `to` 的日期（Requirement 13.2）。
    /// 通常 `to` 是 `from` 的下一天，此时只补写 `from`。
    case dayChanged(from: LocalDate, to: LocalDate)
    /// 「写今天的日记」：用今天 00:00:00 到此刻的事件替换已有的今天日记（Requirement 13.4）。
    case today
}

/// 一篇待写的日记及其相关事件。
public struct DiaryJob: Hashable, Sendable {
    public var key: DiaryKey
    public var events: [EventRecord]

    public init(key: DiaryKey, events: [EventRecord]) {
        self.key = key
        self.events = events
    }
}

public enum DiaryBatch {
    /// 列出批次要写的日记，按日期从早到晚、同日按居民标识排序。
    ///
    /// - `existing`：Diary_Store 中已有日记的（日期，居民）。`.today` 不看它，直接替换。
    /// - `now`：当前时刻；决定「今天」，`.today` 只取不晚于 `now` 的事件。
    public static func plan(
        _ kind: DiaryBatchKind, events: [EventRecord], existing: Set<DiaryKey>,
        now: Date, timeZone: TimeZone
    ) -> [DiaryJob] {
        let today = LocalDate.of(now, timeZone: timeZone)
        let keys: [DiaryKey]
        switch kind {
        case .catchUp:
            keys = DiaryWriter.pending(events: events, existing: existing, before: today, timeZone: timeZone)
        case let .dayChanged(from, to):
            keys = DiaryWriter.pending(events: events, existing: existing, before: to, timeZone: timeZone)
                .filter { $0.date >= from }
        case .today:
            let upToNow = events.filter { $0.time <= now }
            return ResidentID.allCases.sorted().compactMap { id in
                let mine = DiaryWriter.relevant(upToNow, resident: id, date: today, timeZone: timeZone)
                return mine.isEmpty ? nil : DiaryJob(key: DiaryKey(date: today, resident: id), events: mine)
            }
        }
        return keys.map {
            DiaryJob(key: $0, events: DiaryWriter.relevant(
                events, resident: $0.resident, date: $0.date, timeZone: timeZone))
        }
    }

    /// 计划并依次生成、追加批次中的日记，返回成功写入的篇目。
    ///
    /// 每篇单独调用 `writer.write`：LLM 失败只让该篇回退模板（Requirement 13.7）。
    /// 追加失败的篇目直接丢弃，不重试（Requirement 13.11）。
    @discardableResult
    public static func run(
        _ kind: DiaryBatchKind, events: [EventRecord], store: DiaryStore, writer: DiaryWriter,
        config: LLMRequestConfig?, now: Date, timeZone: TimeZone
    ) async -> [DiaryEntry] {
        let existing = Set(store.entries().keys)
        let jobs = plan(kind, events: events, existing: existing, now: now, timeZone: timeZone)
        var written: [DiaryEntry] = []
        for job in jobs {
            let entry = await writer.write(job.key, events: job.events, config: config, timeZone: timeZone)
            if store.append(entry) { written.append(entry) }
        }
        return written
    }

    /// Diary_Window 的显示顺序：按日期从新到旧，同日按居民标识（都都在前）（Requirement 13.12）。
    /// 输入应为 `DiaryStore.entries()`，同一（日期，居民）已只剩最后一行。
    public static func displayOrder(_ entries: [DiaryKey: DiaryEntry]) -> [DiaryEntry] {
        entries.values.sorted {
            $0.date != $1.date ? $0.date > $1.date : $0.resident < $1.resident
        }
    }

    /// 日记批次使用的 LLM 配置：「日记使用 LLM」关闭时为 nil，且不读取 API Key；
    /// 打开时按 `LLMSettingsValidation.config` 校验，设置不完整或钥匙串失败时为 nil（Requirement 12.6、13.5）。
    public static func config(
        _ settings: LLMSettings, apiKey: () -> Result<String?, SecretStoreError>
    ) -> LLMRequestConfig? {
        guard settings.diaryEnabled else { return nil }
        return LLMSettingsValidation.config(settings, apiKeyResult: apiKey())
    }
}
