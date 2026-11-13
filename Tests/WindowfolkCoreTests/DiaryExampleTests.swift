import Foundation
import Testing
@testable import WindowfolkCore

/// 日记示例测试（任务 12.6，Requirement 13.4、13.7、13.11、19.5、22.8）。
/// 文件读写只用临时目录，不访问 `~/Library/Application Support/Windowfolk/`。
@Suite struct DiaryExampleTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let today = LocalDate(year: 2026, month: 10, day: 21)
    private let yesterday = LocalDate(year: 2026, month: 10, day: 20)
    private let config = LLMRequestConfig(
        endpoint: URL(string: "https://example.invalid/v1/chat")!, model: "m", apiKey: "k")

    /// 上海时间 `date` 00:00:00 之后 `seconds` 秒。
    private func at(_ date: LocalDate, _ seconds: TimeInterval) -> Date {
        date.range(timeZone: shanghai).lowerBound.addingTimeInterval(seconds)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-diary-example-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: 生成方式

    /// Requirement 19.5：假 LLM_Client 返回失败时，生成方式为 `template`，正文为模板正文。
    @Test func failingFakeClientYieldsTemplateEntry() async {
        let events = [
            EventRecord(time: at(today, 60), type: .visited, actor: "resident_a", target: "resident_b"),
            EventRecord(time: at(today, 120), type: .slept, actor: "resident_a", target: "decor:2"),
        ]
        for failure in [FakeLLMClient.Script.failure(.httpStatus(500)), .failure(.transport),
                        .failure(.emptyText), .timeout, .text("  \n ")] {
            let fake = FakeLLMClient([failure])
            let writer = DiaryWriter(client: fake, maxLength: 300)
            let e = await writer.write(
                DiaryKey(date: today, resident: .a), events: events, config: config, timeZone: shanghai)
            #expect(e.method == .template, "\(failure)")
            #expect(e.text == "我去找嘟嘟玩了。我在台灯旁睡了一觉。", "\(failure)")
            #expect(await fake.requestCount == 1, "失败后不重试：\(failure)")
        }
    }

    /// Requirement 13.6、13.7：同一批次中一位居民失败改用模板，另一位仍单独请求 LLM 并记为 `llm`。
    @Test func batchFallsBackPerResident() async {
        let events = [
            EventRecord(time: at(today, 60), type: .giftDelivered, actor: "resident_a", target: "resident_b"),
        ]
        let fake = FakeLLMClient([.failure(.httpStatus(503)), .text("都都送了我一个果子，好甜。")])
        let writer = DiaryWriter(client: fake, maxLength: 300)
        let a = await writer.write(DiaryKey(date: today, resident: .a), events: events, config: config, timeZone: shanghai)
        let b = await writer.write(DiaryKey(date: today, resident: .b), events: events, config: config, timeZone: shanghai)

        #expect(a == DiaryEntry(date: today, resident: .a, text: "我把果子送给了嘟嘟。", method: .template))
        #expect(b == DiaryEntry(date: today, resident: .b, text: "都都送了我一个果子，好甜。", method: .llm))
        #expect(await fake.requestCount == 2)
        #expect(await fake.payloads.map(\.purpose) == [.diary(.dudu), .diary(.doodoo)])
    }

    // MARK: 追逐句式

    /// Requirement 22.8：经 Diary_Writer 生成的模板正文中，追逐按角色和结果选 4 种句式之一，
    /// 与其他事件按顺序拼接，重复生成逐字符相同。
    @Test func chaseSentencesInTemplateDiary() async {
        let writer = DiaryWriter(client: FakeLLMClient([.text("不该用到")]), maxLength: 300)
        let cases: [(ResidentID, ChaseOutcome, String)] = [
            (.a, .caught, "我稳稳地落了地。和嘟嘟玩追逐，我抓到嘟嘟啦。"),
            (.a, .escaped, "我稳稳地落了地。和嘟嘟玩追逐，我没抓到嘟嘟，它跑得真快。"),
            (.b, .caught, "我稳稳地落了地。和都都玩追逐，我被都都抓到了。"),
            (.b, .escaped, "我稳稳地落了地。和都都玩追逐，我没被都都抓到。"),
        ]
        for (writerID, outcome, expected) in cases {
            let events = [
                EventRecord(time: at(today, 10), type: .landed, actor: EventRecord.residentRef(writerID)),
                EventRecord(time: at(today, 20), type: .wishFulfilled, actor: "resident_a", target: "resident_b",
                            detail: ["wish_type": "chase", "wish_state": "fulfilled",
                                     "chase_outcome": outcome.rawValue]),
            ]
            let key = DiaryKey(date: today, resident: writerID)
            let first = await writer.write(key, events: events, config: nil, timeZone: shanghai)
            let second = await writer.write(key, events: events, config: nil, timeZone: shanghai)
            #expect(first.method == .template)
            #expect(first.text == expected, "\(writerID) \(outcome)")
            #expect(first == second)
            #expect(!first.text.contains("输") && !first.text.contains("赢") && !first.text.contains("失败"))
        }
    }

    // MARK: 写入失败

    /// Requirement 13.11：`diary.jsonl` 无写权限时丢弃该篇，已有行逐字节不变。
    @Test func writeFailureDropsEntryAndKeepsExistingLines() throws {
        let dir = tempDir()
        let fm = FileManager.default
        let storage = FileDiaryStorage(directory: dir)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storage.fileURL.path)
            try? fm.removeItem(at: dir)
        }
        let store = DiaryStore(storage: storage)
        let old1 = DiaryEntry(date: yesterday, resident: .a, text: "昨天的都都", method: .template)
        let old2 = DiaryEntry(date: yesterday, resident: .b, text: "昨天的嘟嘟", method: .llm)
        #expect(store.append(old1))
        #expect(store.append(old2))
        let before = try Data(contentsOf: storage.fileURL)

        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: storage.fileURL.path)
        let fresh = DiaryEntry(date: today, resident: .a, text: "今天的都都", method: .template)
        #expect(store.append(fresh) == false)

        #expect(try Data(contentsOf: storage.fileURL) == before)
        #expect(store.entries() == [old1.key: old1, old2.key: old2])
    }

    // MARK: 写今天的日记

    /// Requirement 13.4：只用今天的事件为今天有相关事件的居民生成并替换；
    /// 今天没有相关事件的居民不生成，其已有日记和更早的日记保持不变。
    @Test func writeTodayUsesOnlyTodayEventsAndReplaces() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiaryStore(storage: FileDiaryStorage(directory: dir))
        let oldYesterdayA = DiaryEntry(date: yesterday, resident: .a, text: "昨天", method: .template)
        let oldTodayA = DiaryEntry(date: today, resident: .a, text: "旧的今天", method: .llm)
        let oldTodayB = DiaryEntry(date: today, resident: .b, text: "嘟嘟的今天", method: .template)
        for e in [oldYesterdayA, oldTodayA, oldTodayB] { #expect(store.append(e)) }

        // 事件先编码成 events.jsonl 的行，再由 EventLogReader 读回。
        let records = [
            EventRecord(time: at(yesterday, 80_000), type: .fell, actor: "resident_a"),
            EventRecord(time: at(yesterday, 80_100), type: .landed, actor: "resident_b"),
            EventRecord(time: at(today, 100), type: .landed, actor: "resident_a"),
            EventRecord(time: at(today, 200), type: .sat, actor: "resident_a", target: "decor:1"),
        ]
        let events = EventLogReader.parse(records.reduce(Data()) { $0 + EventCodec.encodeLine($1, timeZone: shanghai) })
        #expect(events == records)

        let writer = DiaryWriter(client: nil, maxLength: 300)
        var written: [DiaryEntry] = []
        for id in ResidentID.allCases {
            let mine = DiaryWriter.relevant(events, resident: id, date: today, timeZone: shanghai)
            guard !mine.isEmpty else { continue }
            let e = await writer.write(DiaryKey(date: today, resident: id), events: mine, config: nil, timeZone: shanghai)
            #expect(store.append(e))
            written.append(e)
        }

        let newTodayA = DiaryEntry(date: today, resident: .a, text: "我稳稳地落了地。我在椅子上坐了一会儿。", method: .template)
        #expect(written == [newTodayA])
        #expect(store.entries() == [
            oldYesterdayA.key: oldYesterdayA,
            newTodayA.key: newTodayA,
            oldTodayB.key: oldTodayB,
        ])
    }
}
