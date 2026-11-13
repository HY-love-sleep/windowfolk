import Foundation
import Testing
@testable import WindowfolkCore

/// 日记批次的单元测试（任务 15.3，Requirement 13.2–13.4、13.11、13.12、12.6）。
/// 文件读写只用临时目录。
@Suite struct DiaryBatchUnitTests {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private let d1 = LocalDate(year: 2026, month: 10, day: 19)
    private let d2 = LocalDate(year: 2026, month: 10, day: 20)
    private let today = LocalDate(year: 2026, month: 10, day: 21)

    private func at(_ date: LocalDate, _ seconds: TimeInterval) -> Date {
        date.range(timeZone: tz).lowerBound.addingTimeInterval(seconds)
    }

    private func tempStore() -> (DiaryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-diary-batch-\(UUID().uuidString)", isDirectory: true)
        return (DiaryStore(storage: FileDiaryStorage(directory: dir)), dir)
    }

    private var events: [EventRecord] {
        [
            EventRecord(time: at(d1, 100), type: .fell, actor: "resident_a"),
            EventRecord(time: at(d2, 100), type: .landed, actor: "resident_a"),
            EventRecord(time: at(d2, 200), type: .visited, actor: "resident_b", target: "resident_a"),
            EventRecord(time: at(today, 100), type: .sat, actor: "resident_a", target: "decor:1"),
            EventRecord(time: at(today, 5_000), type: .slept, actor: "resident_a", target: "decor:2"),
        ]
    }

    // MARK: plan

    @Test func catchUpSkipsTodayAndExisting() {
        let existing: Set = [DiaryKey(date: d2, resident: .a)]
        let jobs = DiaryBatch.plan(.catchUp, events: events, existing: existing, now: at(today, 9_000), timeZone: tz)
        #expect(jobs.map(\.key) == [DiaryKey(date: d1, resident: .a), DiaryKey(date: d2, resident: .b)])
        #expect(jobs[1].events == [events[2]])
    }

    @Test func dayChangedOnlyWritesEndedDay() {
        let jobs = DiaryBatch.plan(
            .dayChanged(from: d2, to: today), events: events, existing: [], now: at(today, 1), timeZone: tz)
        #expect(jobs.map(\.key) == [DiaryKey(date: d2, resident: .a), DiaryKey(date: d2, resident: .b)])
        #expect(jobs[0].events == [events[1], events[2]])
    }

    @Test func todayUsesEventsUpToNowAndIgnoresExisting() {
        let existing: Set = [DiaryKey(date: today, resident: .a), DiaryKey(date: today, resident: .b)]
        let jobs = DiaryBatch.plan(.today, events: events, existing: existing, now: at(today, 1_000), timeZone: tz)
        // 嘟嘟今天没有相关事件，不生成；都都只用此刻之前的那条。
        #expect(jobs == [DiaryJob(key: DiaryKey(date: today, resident: .a), events: [events[3]])])
    }

    // MARK: run

    @Test func runTodayReplacesAndKeepsOthers() async {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldA = DiaryEntry(date: today, resident: .a, text: "旧", method: .llm)
        let oldB = DiaryEntry(date: today, resident: .b, text: "嘟嘟的今天", method: .template)
        #expect(store.append(oldA) && store.append(oldB))

        let written = await DiaryBatch.run(
            .today, events: events, store: store, writer: DiaryWriter(client: nil, maxLength: 300),
            config: nil, now: at(today, 9_000), timeZone: tz)
        let newA = DiaryEntry(date: today, resident: .a, text: "我在椅子上坐了一会儿。我在台灯旁睡了一觉。", method: .template)
        #expect(written == [newA])
        #expect(store.entries() == [newA.key: newA, oldB.key: oldB])
    }

    @Test func runCatchUpIsIdempotent() async {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = DiaryWriter(client: nil, maxLength: 300)
        let first = await DiaryBatch.run(
            .catchUp, events: events, store: store, writer: writer, config: nil, now: at(today, 1), timeZone: tz)
        let second = await DiaryBatch.run(
            .catchUp, events: events, store: store, writer: writer, config: nil, now: at(today, 2), timeZone: tz)
        #expect(first.count == 3)
        #expect(second.isEmpty)
    }

    /// Requirement 13.11：追加失败的篇目被丢弃，不计入结果。
    @Test func runDropsEntriesWhenAppendFails() async throws {
        let (store, dir) = tempStore()
        // 让目录位置被一个普通文件占住，createDirectory 必然失败。
        try Data().write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let written = await DiaryBatch.run(
            .catchUp, events: events, store: store, writer: DiaryWriter(client: nil, maxLength: 300),
            config: nil, now: at(today, 1), timeZone: tz)
        #expect(written.isEmpty)
        #expect(store.entries().isEmpty)
    }

    // MARK: 显示顺序

    @Test func displayOrderNewestFirstThenResident() {
        let entries = [
            DiaryEntry(date: d1, resident: .b, text: "1", method: .template),
            DiaryEntry(date: today, resident: .b, text: "2", method: .template),
            DiaryEntry(date: today, resident: .a, text: "3", method: .llm),
            DiaryEntry(date: d2, resident: .a, text: "4", method: .template),
        ]
        let dict = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        #expect(DiaryBatch.displayOrder(dict).map(\.text) == ["3", "2", "4", "1"])
    }

    // MARK: 配置

    @Test func configRequiresDiarySwitchAndValidSettings() {
        var s = LLMSettings(diaryEnabled: false, endpoint: "https://example.com/v1", model: "m")
        var reads = 0
        #expect(DiaryBatch.config(s, apiKey: { reads += 1; return .success("k") }) == nil)
        #expect(reads == 0, "开关关闭时不读取 API Key")

        s.diaryEnabled = true
        #expect(DiaryBatch.config(s, apiKey: { .success("k") })?.model == "m")
        #expect(DiaryBatch.config(s, apiKey: { .success(nil) }) == nil)
        #expect(DiaryBatch.config(s, apiKey: { .failure(.operationFailed(status: -1)) }) == nil)
    }
}
