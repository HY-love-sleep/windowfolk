import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// MARK: - 生成器

/// 正文中容易出错的字符：引号、反斜杠、换行、回车、制表、控制字符、U+2028/2029、BOM、
/// 中文、组合字符、emoji。
fileprivate let diaryTrickyCharacters: [Character] = [
    "\"", "\\", "\n", "\r", "\t", "\r\n", "\u{0}", "\u{1F}", "\u{7F}", "\u{2028}", "\u{2029}", "\u{FEFF}",
    "/", ":", "{", "}", ",", " ", "今", "天", "嘟", "睡", "あ", "é", "e\u{301}",
    "🐹", "🌸", "👨‍👩‍👧", "🇨🇳", "👍🏽",
]

/// 一半取自易错字符表，一半是任意合法 Unicode 标量（跳过代理区）。
fileprivate var diaryCharacter: Generator<Character, some SendableSequenceType> {
    zip(
        Gen<Bool>.bool,
        Gen<Character?>.element(of: diaryTrickyCharacters).map { $0! },
        Gen<UInt32>.value(in: 0...(0x10FFFF - 0x800))
    ).map { useTricky, tricky, raw -> Character in
        if useTricky { return tricky }
        let v = raw >= 0xD800 ? raw + 0x800 : raw
        return Character(UnicodeScalar(v)!)
    }
}

fileprivate var diaryText: Generator<String, some SendableSequenceType> { diaryCharacter.string(of: 0...40) }

/// 公历某月的天数。
fileprivate func daysInMonth(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 2:
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        return leap ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
}

/// 1...9999 年中任意真实存在的日期。
fileprivate var anyLocalDate: Generator<LocalDate, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 1...9999),
        Gen<Int>.int(in: 1...12),
        Gen<Int>.int(in: 1...31)
    ).map { y, m, d in LocalDate(year: y, month: m, day: min(d, daysInMonth(y, m))) }
}

/// DiaryMethod 不是 CaseIterable，用布尔值选取。
fileprivate var diaryMethod: Generator<DiaryMethod, some SendableSequenceType> {
    Gen<Bool>.bool.map { $0 ? .template : .llm }
}

fileprivate var diaryEntry: Generator<DiaryEntry, some SendableSequenceType> {
    zip(
        anyLocalDate,
        Gen<ResidentID>.case,
        diaryText,
        diaryMethod
    ).map { date, resident, text, method in
        DiaryEntry(date: date, resident: resident, text: text, method: method)
    }
}

/// 读取测试用的小日期池，使同一（日期，居民）多次出现。
fileprivate let datePool: [LocalDate] = [
    LocalDate(year: 2026, month: 10, day: 20),
    LocalDate(year: 2026, month: 10, day: 21),
    LocalDate(year: 2024, month: 2, day: 29),
]

fileprivate var pooledEntry: Generator<DiaryEntry, some SendableSequenceType> {
    zip(
        Gen<LocalDate?>.element(of: datePool).map { $0! },
        Gen<ResidentID>.case,
        diaryText,
        diaryMethod
    ).map { date, resident, text, method in
        DiaryEntry(date: date, resident: resident, text: text, method: method)
    }
}

/// 文件中的一行：合法行带上它的 Diary_Entry，坏行为 nil。
fileprivate struct DiaryLine: Sendable {
    var bytes: Data  // 不含行尾 `\n`
    var entry: DiaryEntry?
}

extension DiaryEntry {
    /// 编码后去掉行尾 `\n` 的 JSON。
    fileprivate var jsonBody: String {
        String(decoding: DiaryCodec.encodeLine(self).dropLast(), as: UTF8.self)
    }
}

/// 构造一行：合法行，或以下几种坏行之一：
/// 非 JSON 文本、截断的合法行、不存在的日期、未知 method、未知居民、缺字段、空行。
fileprivate var diaryLine: Generator<DiaryLine, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...7),
        pooledEntry,
        diaryText,
        Gen<Int>.int(in: 0...10_000)
    ).map { kind, e, garbage, cut -> DiaryLine in
        func json(date: String, method: String, resident: String) -> Data {
            // 用 JSONEncoder 编码正文，保证坏行只坏在指定字段上。
            let text = String(decoding: try! JSONEncoder().encode(e.text), as: UTF8.self)
            return Data(#"{"date":"\#(date)","method":"\#(method)","resident":"\#(resident)","text":\#(text)}"#.utf8)
        }
        let date = e.date.description
        switch kind {
        case 0, 1, 2:
            return DiaryLine(bytes: Data(e.jsonBody.utf8), entry: e)
        case 3:
            // 以 `#` 开头的任意文本不是 JSON；去掉换行以保持一行。
            let text = "#" + garbage.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            return DiaryLine(bytes: Data(text.utf8), entry: nil)
        case 4:
            // 合法行的真前缀：对象没有闭合。
            let body = Data(e.jsonBody.utf8)
            return DiaryLine(bytes: body.prefix(cut % body.count), entry: nil)
        case 5:
            let bad = ["2026-02-30", "2026-13-01", "2026-1-01", "0000-01-01", "yesterday"][cut % 5]
            return DiaryLine(bytes: json(date: bad, method: e.method.rawValue, resident: e.resident.rawValue), entry: nil)
        case 6:
            if cut % 2 == 0 {
                return DiaryLine(bytes: json(date: date, method: "robot", resident: e.resident.rawValue), entry: nil)
            }
            return DiaryLine(bytes: json(date: date, method: e.method.rawValue, resident: "resident_c"), entry: nil)
        default:
            if cut % 2 == 0 {
                return DiaryLine(bytes: Data(), entry: nil)
            }
            return DiaryLine(bytes: Data(#"{"date":"\#(date)","resident":"\#(e.resident.rawValue)"}"#.utf8), entry: nil)
        }
    }
}

/// 一份文件内容：若干行，最后一行是否带 `\n`，是否用 `\r\n` 作行尾。
fileprivate struct DiaryFile: Sendable {
    var lines: [DiaryLine]
    var trailingNewline: Bool
    var crlf: Bool

    var data: Data {
        var out = Data()
        for (i, line) in lines.enumerated() {
            out += line.bytes
            if i < lines.count - 1 || trailingNewline {
                if crlf { out.append(0x0D) }
                out.append(0x0A)
            }
        }
        return out
    }
}

fileprivate var diaryFile: Generator<DiaryFile, some SendableSequenceType> {
    zip(diaryLine.array(of: 0...12), Gen<Bool>.bool, Gen<Bool>.bool)
        .map { lines, trailing, crlf in DiaryFile(lines: lines, trailingNewline: trailing, crlf: crlf) }
}

/// 只读的内存 DiaryStorage。
fileprivate struct FixedDiaryStorage: DiaryStorage {
    var data: Data?
    func readAll() -> Data? { data }
    func append(_ line: Data) -> Bool { false }
}

// MARK: - 属性测试

struct DiaryStoreTests {
    // Feature: V2, Property 43: Diary_Store 编解码与读取（编解码部分）
    // **Validates: Requirements 13.9**
    @Test func diaryCodecRoundTripIsSingleLine() async {
        await propertyCheck(count: 200, input: diaryEntry) { e in
            let line = DiaryCodec.encodeLine(e)

            // 恰好一行：结尾一个 \n，中间没有 \n 或 \r 字节
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A))
            #expect(!line.dropLast().contains(0x0D))

            #expect((try? DiaryCodec.decodeLine(line)) == e)
        }
    }

    // Feature: V2, Property 43: Diary_Store 编解码与读取（读取部分）
    // **Validates: Requirements 13.10**
    @Test func entriesSkipBadLinesAndKeepLastPerKey() async {
        await propertyCheck(count: 200, input: diaryFile) { file in
            var expected: [DiaryKey: DiaryEntry] = [:]
            for line in file.lines {
                if let e = line.entry { expected[e.key] = e }
            }
            let store = DiaryStore(storage: FixedDiaryStorage(data: file.data))
            #expect(store.entries() == expected)
        }
    }
}
