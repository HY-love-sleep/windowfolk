import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// MARK: - 生成器

/// 一条事件记录和编码时使用的时区。
struct EventCase: Sendable {
    var record: EventRecord
    var timeZone: TimeZone
}

/// 容易出错的字符：引号、反斜杠、换行、回车、制表、其他控制字符、U+2028/2029、
/// 中文、组合字符、emoji（含 ZWJ 序列、国旗和肤色修饰）。
private let trickyCharacters: [Character] = [
    "\"", "\\", "\n", "\r", "\t", "\r\n", "\u{0}", "\u{1}", "\u{8}", "\u{C}", "\u{1B}", "\u{1F}", "\u{7F}",
    "\u{2028}", "\u{2029}", "\u{FEFF}", "/", ":", "{", "}", "[", "]", ",",
    "备", "忘", "录", "窗", "间", "都", "嘟", "猫", "熊", "あ", "한",
    "é", "e\u{301}", "\u{301}", "🐹", "🐱", "🌸", "👨‍👩‍👧", "🇨🇳", "👍🏽", "💐",
]

extension Gen where Value == Character {
    /// 一半取自易错字符表，一半是任意合法 Unicode 标量（跳过代理区）。
    static var eventCharacter: Generator<Character, some SendableSequenceType> {
        zip(
            Gen<Bool>.bool,
            Gen<Character?>.element(of: trickyCharacters).map { $0! },
            Gen<UInt32>.value(in: 0...(0x10FFFF - 0x800))
        ).map { useTricky, tricky, raw in
            if useTricky { return tricky }
            let v = raw >= 0xD800 ? raw + 0x800 : raw
            return Character(UnicodeScalar(v)!)
        }
    }
}

extension Gen where Value == EventCase {
    static var eventCase: Generator<EventCase, some SendableSequenceType> {
        let text = Gen<Character>.eventCharacter.string(of: 0...12)
        return zip(
            Gen<EventType>.case,
            text.optional(),
            text.optional(),
            zip(text, text).dictionary(ofAtMost: 0...4),
            Gen<Bool>.bool,
            Gen<Int>.int(in: -30_610_224_000...221_845_392_000),  // 公元 1000 年到 9000 年
            Gen<Double>.double(in: 0..<1),
            zip(
                Gen<Int>.int(in: -48...56),  // 固定偏移：-12:00 到 +14:00，以 15 分钟为单位
                Gen<String?>.element(of: TimeZone.knownTimeZoneIdentifiers.sorted()).map { $0! },
                Gen<Int>.int(in: 315_532_800...4_102_444_800)  // 命名时区只用 1980 到 2100 年
            )
        ).map { type, actor, target, detail, named, seconds, fraction, zone in
            let (quarters, identifier, modernSeconds) = zone
            let timeZone: TimeZone
            let whole: Int
            if named, let tz = TimeZone(identifier: identifier) {
                // 历史上的地方平时（LMT）偏移带秒数，ISO 8601 偏移只到分钟，因此限制在现代时间
                timeZone = tz
                whole = modernSeconds
            } else {
                timeZone = TimeZone(secondsFromGMT: quarters * 15 * 60)!
                whole = seconds
            }
            let record = EventRecord(
                time: Date(timeIntervalSince1970: Double(whole) + fraction), type: type,
                actor: actor, target: target, detail: detail)
            return EventCase(record: record, timeZone: timeZone)
        }
    }
}

// MARK: - 属性测试

struct EventLogTests {
    /// 带时区偏移、精确到秒的 ISO 8601：`yyyy-MM-ddTHH:mm:ss±HH:mm`。
    static var timePattern: Regex<Substring> { /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/ }

    /// 按时区在该时刻的偏移写出的 `±HH:mm`。
    static func offsetSuffix(_ tz: TimeZone, at date: Date) -> String {
        let s = tz.secondsFromGMT(for: date)
        let a = abs(s)
        return (s < 0 ? "-" : "+") + String(format: "%02d:%02d", a / 3600, (a % 3600) / 60)
    }

    // Feature: v1, Property 35: 事件编码往返
    // **Validates: Requirements 21.1, 21.3, 21.4, 21.5, 21.6, 21.7, 21.9**
    @Test func eventCodecRoundTrip() async {
        await propertyCheck(count: 100, input: Gen.eventCase) { c in
            let r = c.record
            let line = EventCodec.encodeLine(r, timeZone: c.timeZone)

            // 恰好一行：结尾一个 \n，中间没有 \n 或 \r 字节
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A))
            #expect(!line.dropLast().contains(0x0D))
            #expect(String(data: line, encoding: .utf8) != nil)

            // 是一个 JSON 对象，键恰好为五个字段
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                Issue.record("not a JSON object: \(String(decoding: line, as: UTF8.self))")
                return
            }
            #expect(Set(obj.keys) == ["time", "type", "actor", "target", "detail"])

            // type 为合法事件名且与记录一致
            #expect(obj["type"] as? String == r.type.rawValue)

            // actor、target：nil 编码为 JSON null，否则为 JSON 字符串；detail 为 JSON 对象，空时为 {}。
            // 字符串内容的相等由下面的 decodeLine 往返检查：JSONSerialization 会吞掉字符串开头的
            // U+FEFF，不能用来比较内容（线上字节里它是在的，JSONDecoder 也能原样读回）。
            for (key, value) in [("actor", r.actor), ("target", r.target)] {
                if value == nil {
                    #expect(obj[key] is NSNull)
                } else {
                    #expect(obj[key] is String)
                }
            }
            let detail = obj["detail"] as? [String: String]
            #expect(detail != nil)
            #expect(detail?.isEmpty == r.detail.isEmpty)

            // time 为带偏移的秒级 ISO 8601，偏移等于该时区在该时刻的偏移
            if let time = obj["time"] as? String {
                #expect(time.wholeMatch(of: Self.timePattern) != nil)
                #expect(time.hasSuffix(Self.offsetSuffix(c.timeZone, at: r.time)))
            } else {
                Issue.record("time is not a string")
            }

            // 记录本身已截断到整秒
            #expect(r.time.timeIntervalSince1970 == r.time.timeIntervalSince1970.rounded(.down))

            // 往返相等
            #expect((try? EventCodec.decodeLine(line)) == r)
        }
    }

    /// 追加前的文件状态。
    enum AppendStart: CaseIterable, Sendable {
        case noDirectory   // 目录（含一级父目录）都不存在
        case noFile        // 目录存在，文件不存在
        case existingFile  // 文件已存在，内容为若干随机行（可以是 0 行，即空文件）
    }

    // Feature: v1, Property 36: 事件追加保序
    // **Validates: Requirements 21.2**
    @Test func eventAppendPreservesOrder() async {
        // 已有行：任意文本（去掉换行符），每行以 \n 结尾
        let existingLine = Gen<Character>.eventCharacter.string(of: 0...20)
            .map { $0.filter { $0 != "\n" && $0 != "\r" && $0 != "\r\n" } + "\n" }
        await propertyCheck(
            count: 100,
            input: Gen<AppendStart>.case, existingLine.array(of: 0...6), Gen.eventCase.array(of: 0...8)
        ) { start, existing, cases in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("windowfolk-tests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("Windowfolk", isDirectory: true)
            let sink = FileEventSink(directory: directory)

            var original = Data()
            switch start {
            case .noDirectory:
                break
            case .noFile:
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            case .existingFile:
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                original = Data(existing.joined().utf8)
                #expect((try? original.write(to: sink.fileURL)) != nil)
            }

            let lines = cases.map { EventCodec.encodeLine($0.record, timeZone: $0.timeZone) }
            for line in lines {
                #expect(sink.tryAppend(line))
            }

            let after = (try? Data(contentsOf: sink.fileURL)) ?? Data()
            if start != .existingFile && lines.isEmpty {
                // 没有任何追加时不要求创建文件
                #expect(after.isEmpty)
                return
            }
            // 原内容逐字节保留在开头，其后按顺序紧跟每一条编码行
            #expect(after == original + lines.reduce(Data(), +))

            // 新增部分恰好 N 行，每行都能解码回对应记录
            let appended = after.dropFirst(original.count)
            let parts = appended.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
            #expect(parts.count == cases.count)
            for (part, c) in zip(parts, cases) {
                #expect((try? EventCodec.decodeLine(Data(part) + [0x0A])) == c.record)
            }
        }
    }
}

// MARK: - 事件文件单元测试（任务 14.6）

extension EventLogTests {
    /// 每个测试一个唯一的临时根目录；从不使用 `~/Library/Application Support/Windowfolk/`（Requirement 27.6）。
    static func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-tests-\(UUID().uuidString)", isDirectory: true)
    }

    static func line(_ type: EventType, actor: String? = nil, target: String? = nil) -> Data {
        EventCodec.encodeLine(
            EventRecord(time: Date(timeIntervalSince1970: 1_792_500_000), type: type, actor: actor, target: target),
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
    }

    /// 目录（含多级父目录）和文件都不存在时，第一次追加先创建它们再写入（Requirement 21.10）。
    @Test func appendCreatesMissingDirectoriesAndFile() throws {
        let root = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("a/b/Windowfolk", isDirectory: true)
        let sink = FileEventSink(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let first = Self.line(.fell, actor: "resident_a", target: "app:Notes")
        #expect(sink.tryAppend(first))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(sink.fileURL.lastPathComponent == "events.jsonl")
        #expect(try Data(contentsOf: sink.fileURL) == first)

        // 文件被删掉后再写，会重新创建。
        try FileManager.default.removeItem(at: sink.fileURL)
        let second = Self.line(.landed, actor: "resident_a", target: "ground")
        sink.append(second)
        #expect(try Data(contentsOf: sink.fileURL) == second)
    }

    /// 目录路径被一个普通文件占用：写入失败时丢弃该条、不抛出、不改动该文件；
    /// 障碍移除后下一条照常写入（Requirement 21.11）。
    @Test func appendFailureWhenDirectoryPathIsAFileIsSwallowed() throws {
        let root = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("Windowfolk", isDirectory: true)
        let blocker = Data("not a directory".utf8)
        try blocker.write(to: directory)
        let sink = FileEventSink(directory: directory)

        #expect(!sink.tryAppend(Self.line(.plankPlaced, actor: "player")))
        sink.append(Self.line(.plankDropped, actor: "player"))  // 不崩溃、不抛出
        #expect(try Data(contentsOf: directory) == blocker)

        try FileManager.default.removeItem(at: directory)
        let next = Self.line(.ladderPlaced, actor: "player")
        #expect(sink.tryAppend(next))
        // 失败的两条被丢弃，没有重试补写。
        #expect(try Data(contentsOf: sink.fileURL) == next)
    }

    /// 目录只读：新建文件失败、已有文件不可写时都返回 false 且不抛出；
    /// 权限恢复后之后的事件照常写入（Requirement 21.11）。
    @Test func appendFailureInReadOnlyDirectoryIsSwallowedAndLaterAppendsRetry() throws {
        let fm = FileManager.default
        let root = Self.makeTempRoot()
        let directory = root.appendingPathComponent("Windowfolk", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? fm.removeItem(at: root)
        }
        let sink = FileEventSink(directory: directory)

        // 1. 目录只读、文件不存在：无法创建文件。
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        #expect(!sink.tryAppend(Self.line(.fell, actor: "resident_a")))
        sink.append(Self.line(.fell, actor: "resident_b"))
        #expect(!fm.fileExists(atPath: sink.fileURL.path))

        // 2. 恢复权限后照常写入。
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let ok1 = Self.line(.landed, actor: "resident_a", target: "ground")
        #expect(sink.tryAppend(ok1))

        // 3. 文件本身只读：追加失败，已有内容不变。
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: sink.fileURL.path)
        #expect(!sink.tryAppend(Self.line(.bloomed)))
        sink.append(Self.line(.sprouted))
        #expect(try Data(contentsOf: sink.fileURL) == ok1)

        // 4. 恢复后下一条接在原内容之后。
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sink.fileURL.path)
        let ok2 = Self.line(.giftDelivered, actor: "resident_b", target: "resident_a")
        #expect(sink.tryAppend(ok2))
        #expect(try Data(contentsOf: sink.fileURL) == ok1 + ok2)
    }

    /// 应用层默认目录只是计算出来的路径，构造 `FileEventSink` 不会创建或读取任何文件。
    @Test func sinkConstructionTouchesNothing() {
        let root = Self.makeTempRoot()
        let sink = FileEventSink(directory: root.appendingPathComponent("Windowfolk", isDirectory: true))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(sink.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(FileEventSink.defaultDirectory()?.lastPathComponent == "Windowfolk")
    }

    /// 涉及窗口的记录只写所属应用名称（`app:<ownerName>`），任何字段都不出现标题（Requirement 21.8）。
    /// 应用名含中文、引号和换行时，写入文件后仍是一行，并能原样读回。
    @Test func windowEventsWriteOnlyAppNameToFile() throws {
        typealias H = BridgeHangTests
        let owner = "备忘录 \"Notes\"\n🐹"
        var snapshot = H.win(1, 100, 300, 300, 300)
        snapshot.ownerName = owner
        let h = H.Harness([snapshot])
        h.engine.place(H.idle(.a, window: 1, offset: 100))
        h.step()
        h.source.close(1)
        let events = h.step().events
        let fell = try #require(events.first { $0.type == .fell })
        #expect(fell.target == EventRecord.appRef(owner))
        #expect(EventRecord.appRef(owner) == "app:" + owner)

        let root = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = FileEventSink(directory: root.appendingPathComponent("Windowfolk", isDirectory: true))
        for e in events { #expect(sink.tryAppend(EventCodec.encodeLine(e))) }

        let data = try Data(contentsOf: sink.fileURL)
        let lines = data.split(separator: 0x0A)
        #expect(lines.count == events.count)
        for (lineData, e) in zip(lines, events) {
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any])
            #expect(Set(obj.keys) == ["time", "type", "actor", "target", "detail"])
            #expect(!String(decoding: lineData, as: UTF8.self).lowercased().contains("title"))
            #expect(try EventCodec.decodeLine(Data(lineData) + [0x0A]) == e)
        }
        let fellLine = try #require(lines.first { String(decoding: $0, as: UTF8.self).contains("\"fell\"") })
        let fellObj = try #require(try JSONSerialization.jsonObject(with: Data(fellLine)) as? [String: Any])
        #expect(fellObj["target"] as? String == "app:" + owner)
    }
}
