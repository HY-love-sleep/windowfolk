import Foundation
import Testing
@testable import WindowfolkCore

/// LocalDate、DiaryCodec、DiaryStore、FileDiaryStorage、EventLogReader 的单元测试
/// （任务 11.1，Requirement 13.1、13.9、13.10、13.11、19.4）。
/// 文件读写只用临时目录，不访问 `~/Library/Application Support/Windowfolk/`。
@Suite struct DiaryUnitTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let utc = TimeZone(identifier: "UTC")!

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-diary-\(UUID().uuidString)", isDirectory: true)
    }

    private final class MemoryStorage: DiaryStorage, @unchecked Sendable {
        var data: Data?
        init(_ s: String?) { data = s.map { Data($0.utf8) } }
        func readAll() -> Data? { data }
        func append(_ line: Data) -> Bool { data = (data ?? Data()) + line; return true }
    }

    // MARK: LocalDate

    @Test func localDateFollowsTimeZone() {
        // 2026-10-20T16:30:00Z = 上海 2026-10-21 00:30
        let t = Date(timeIntervalSince1970: 1_792_513_800)
        #expect(LocalDate.of(t, timeZone: utc) == LocalDate(year: 2026, month: 10, day: 20))
        #expect(LocalDate.of(t, timeZone: shanghai) == LocalDate(year: 2026, month: 10, day: 21))
    }

    @Test func rangeIsHalfOpenDay() {
        let d = LocalDate(year: 2026, month: 10, day: 21)
        let r = d.range(timeZone: shanghai)
        #expect(r.upperBound.timeIntervalSince(r.lowerBound) == 86_400)
        #expect(LocalDate.of(r.lowerBound, timeZone: shanghai) == d)
        #expect(LocalDate.of(r.upperBound, timeZone: shanghai) == LocalDate(year: 2026, month: 10, day: 22))
        #expect(LocalDate.of(r.upperBound.addingTimeInterval(-1), timeZone: shanghai) == d)
    }

    @Test func localDateEncodesAsString() throws {
        let d = LocalDate(year: 2026, month: 3, day: 7)
        #expect(String(decoding: try JSONEncoder().encode([d]), as: UTF8.self) == #"["2026-03-07"]"#)
        #expect(LocalDate(string: "2026-02-30") == nil)
        #expect(LocalDate(string: "2026-2-03") == nil)
        #expect(LocalDate(string: "2024-02-29") == LocalDate(year: 2024, month: 2, day: 29))
        #expect(LocalDate(year: 2026, month: 1, day: 31) < LocalDate(year: 2026, month: 2, day: 1))
    }

    // MARK: DiaryCodec

    @Test func encodeLineIsSortedSingleLine() throws {
        let e = DiaryEntry(date: LocalDate(year: 2026, month: 10, day: 20), resident: .a,
                           text: "第一行\n\"引号\" \\ /", method: .template)
        let line = DiaryCodec.encodeLine(e)
        let s = String(decoding: line, as: UTF8.self)
        #expect(s.hasPrefix(#"{"date":"2026-10-20","method":"template","resident":"resident_a","text":"#))
        #expect(s.filter { $0 == "\n" }.count == 1 && s.hasSuffix("\n"))
        #expect(try DiaryCodec.decodeLine(line) == e)
    }

    // MARK: DiaryStore

    @Test func entriesSkipBadLinesAndKeepLast() {
        let storage = MemoryStorage("""
        {"date":"2026-10-20","method":"template","resident":"resident_a","text":"旧"}
        not json
        {"date":"2026-02-30","method":"template","resident":"resident_a","text":"坏日期"}
        {"date":"2026-10-20","method":"robot","resident":"resident_b","text":"坏方式"}
        {"date":"2026-10-20","method":"llm","resident":"resident_a","text":"新"}
        {"date":"2026-10-20","method":"template","resident":"resident_b","text":"嘟嘟"}
        {"date":"2026-10-21","method":"template","resident":"res
        """)
        let entries = DiaryStore(storage: storage).entries()
        let d = LocalDate(year: 2026, month: 10, day: 20)
        #expect(entries.count == 2)
        #expect(entries[DiaryKey(date: d, resident: .a)]?.text == "新")
        #expect(entries[DiaryKey(date: d, resident: .a)]?.method == .llm)
        #expect(entries[DiaryKey(date: d, resident: .b)]?.text == "嘟嘟")
    }

    @Test func missingFileYieldsNoEntries() {
        #expect(DiaryStore(storage: FileDiaryStorage(directory: tempDir())).entries().isEmpty)
    }

    @Test func fileStorageAppendsAndKeepsExistingLines() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FileDiaryStorage(directory: dir)
        let store = DiaryStore(storage: storage)
        let d = LocalDate(year: 2026, month: 10, day: 20)
        let first = DiaryEntry(date: d, resident: .a, text: "一", method: .template)
        let second = DiaryEntry(date: d, resident: .a, text: "二", method: .llm)
        #expect(store.append(first))
        #expect(store.append(second))
        let text = String(decoding: try Data(contentsOf: storage.fileURL), as: UTF8.self)
        #expect(text == String(decoding: DiaryCodec.encodeLine(first) + DiaryCodec.encodeLine(second), as: UTF8.self))
        #expect(store.entries() == [first.key: second])
    }

    @Test func appendAfterTruncatedLineStartsNewLine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FileDiaryStorage(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"date":"2026-10-20","meth"#.utf8).write(to: storage.fileURL)
        let e = DiaryEntry(date: LocalDate(year: 2026, month: 10, day: 21), resident: .b, text: "嗨", method: .template)
        #expect(DiaryStore(storage: storage).append(e))
        #expect(DiaryStore(storage: storage).entries() == [e.key: e])
    }

    @Test func appendFailureReturnsFalse() throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 目录路径被一个普通文件占用，无法创建目录。
        let blocker = base.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let store = DiaryStore(storage: FileDiaryStorage(directory: blocker))
        let e = DiaryEntry(date: LocalDate(year: 2026, month: 10, day: 20), resident: .a, text: "t", method: .template)
        #expect(store.append(e) == false)
        #expect(try Data(contentsOf: blocker) == Data("x".utf8))
    }

    // MARK: EventLogReader

    @Test func parseSkipsBadAndIncompleteLines() {
        let t = Date(timeIntervalSince1970: 1_792_513_800)
        let r1 = EventRecord(time: t, type: .sat, actor: "resident_a")
        let r2 = EventRecord(time: t.addingTimeInterval(60), type: .woke, actor: "resident_b", detail: ["k": "v"])
        var data = EventCodec.encodeLine(r1, timeZone: shanghai)
        data += Data("garbage\n".utf8)
        data += Data(#"{"time":"2026-10-20T21:05:33+08:00","type":"sat","actor":null,"target":null}"#.utf8 + [0x0A])
        data += Data(#"{"time":"yesterday","type":"sat","actor":null,"target":null,"detail":{}}"#.utf8 + [0x0A])
        data += Data(#"{"time":"2026-10-20T21:05:33+08:00","type":"nope","actor":null,"target":null,"detail":{}}"#.utf8 + [0x0A])
        data += EventCodec.encodeLine(r2, timeZone: utc)
        data += EventCodec.encodeLine(r1, timeZone: utc).prefix(20)
        #expect(EventLogReader.parse(data) == [r1, r2])
        #expect(EventLogReader.parse(Data()) == [])
    }
}
