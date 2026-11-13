import Foundation
import WindowfolkCore

/// 调度日记批次（design.md「线程模型」，Requirement 13.2–13.4、13.7、13.11、13.12）。
///
/// - 是一个 actor：读取 `events.jsonl`、生成日记（含 LLM 请求）和写入 `diary.jsonl` 都不在主线程上，
///   Game_Loop 从不等待它（Requirement 12.5）。
/// - 批次串行：同一时刻只运行一个批次，后到的排在前一个之后，因此不会为同一（日期，居民）重复补写。
/// - 每个批次开始时重新读取 LLM 设置和 API Key，设置改动对之后的批次生效（Requirement 11.4）。
///   「日记使用 LLM」关闭时不读取钥匙串，也不发请求（Requirement 12.6）。
/// - 批次结束后把最新列表交给 Diary_Window（窗口未打开时只更新数据）。
///
/// 日期变化的检测与 Game_Loop 接线在任务 15.4，菜单接入在任务 15.6。
actor DiaryCoordinator {
    /// 读取 `events.jsonl` 全部内容；文件不存在或无法读取时为 nil。
    typealias EventSource = @Sendable () async -> Data?

    private let store: DiaryStore
    private let writer: DiaryWriter
    private let clock: any LocalClock
    private let readEvents: EventSource
    private let settings: any LLMSettingsStore
    private let secrets: any SecretStore
    /// Diary_Window。主线程类，可跨 actor 持有。
    nonisolated let window: DiaryWindowController
    /// 最后一个排队的批次。新批次先等待它完成。
    private var tail: Task<Void, Never>?

    init(
        store: DiaryStore, writer: DiaryWriter, clock: any LocalClock,
        readEvents: @escaping EventSource,
        settings: any LLMSettingsStore, secrets: any SecretStore,
        window: DiaryWindowController
    ) {
        self.store = store
        self.writer = writer
        self.clock = clock
        self.readEvents = readEvents
        self.settings = settings
        self.secrets = secrets
        self.window = window
    }

    /// 组装协调器与 Diary_Window。
    ///
    /// - `directory`：数据目录，`diary.jsonl` 写在这里；没有 `eventLog` 时也从这里直接读 `events.jsonl`。
    /// - `eventLog`：传入时经由它的串行队列读取事件，避免读到正在追加的行。
    @MainActor
    static func make(
        directory: URL, eventLog: EventLogWriter?,
        settings: any LLMSettingsStore, secrets: any SecretStore,
        client: (any LLMClient)?, clock: any LocalClock = SystemLocalClock(),
        tunables: Tunables = Tunables()
    ) -> DiaryCoordinator {
        let readEvents: EventSource
        if let eventLog {
            readEvents = { await eventLog.readAll() }
        } else {
            let url = directory.appendingPathComponent(FileEventSink.defaultFileName, isDirectory: false)
            readEvents = { try? Data(contentsOf: url) }
        }
        let window = DiaryWindowController()
        let coordinator = DiaryCoordinator(
            store: DiaryStore(storage: FileDiaryStorage(directory: directory)),
            writer: DiaryWriter(client: client, maxLength: tunables.diaryMaxLength),
            clock: clock, readEvents: readEvents,
            settings: settings, secrets: secrets, window: window)
        window.attach(coordinator)
        return coordinator
    }

    /// 使用默认数据目录 `~/Library/Application Support/Windowfolk/`；无法确定目录时返回 nil。
    @MainActor
    static func makeDefault(
        eventLog: EventLogWriter?, settings: any LLMSettingsStore, secrets: any SecretStore,
        client: (any LLMClient)?
    ) -> DiaryCoordinator? {
        guard let dir = FileEventSink.defaultDirectory() else { return nil }
        return make(directory: dir, eventLog: eventLog, settings: settings, secrets: secrets, client: client)
    }

    // MARK: 入口

    /// 启动补写：早于今天、有相关事件且缺日记的（日期，居民）各写一篇（Requirement 13.3）。
    func startup() async {
        await enqueue(.catchUp)
    }

    /// 运行中本地日期从 `from` 变为 `to`：为 `from`（以及到 `to` 之前被跳过的日期）补写（Requirement 13.2）。
    func dateChanged(from: LocalDate, to: LocalDate) async {
        guard from < to else { return }
        await enqueue(.dayChanged(from: from, to: to))
    }

    /// 「写今天的日记」：用今天 00:00:00 到调用时刻的事件替换今天已有的日记；
    /// 今天没有相关事件的居民不生成（Requirement 13.4）。
    func writeToday() async {
        await enqueue(.today)
    }

    /// 打开 Diary_Window；已打开时移到最前（Requirement 13.12）。
    @MainActor
    func showWindow() {
        window.show()
    }

    /// Diary_Window 要显示的全部日记，按日期从新到旧（Requirement 13.10、13.12）。
    func entries() -> [DiaryEntry] {
        DiaryBatch.displayOrder(store.entries())
    }

    // MARK: 批次

    /// 排队一个批次并等待它完成。「此刻」在排队时取，排在前面的批次不会推迟它。
    private func enqueue(_ kind: DiaryBatchKind) async {
        let now = clock.now
        let timeZone = clock.timeZone
        let previous = tail
        let task = Task {
            await previous?.value
            await self.run(kind, now: now, timeZone: timeZone)
        }
        tail = task
        await task.value
    }

    private func run(_ kind: DiaryBatchKind, now: Date, timeZone: TimeZone) async {
        let events = (await readEvents()).map(EventLogReader.parse) ?? []
        let secrets = self.secrets
        let config = DiaryBatch.config(settings.load(), apiKey: { secrets.readAPIKey() })
        await DiaryBatch.run(
            kind, events: events, store: store, writer: writer,
            config: config, now: now, timeZone: timeZone)
        let list = entries()
        await window.update(list)
    }
}
