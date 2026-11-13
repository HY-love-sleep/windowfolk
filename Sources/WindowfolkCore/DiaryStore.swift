import Foundation

// MARK: - 编解码

/// Diary_Entry 与一行 JSON 之间的编解码（Requirement 13.9）。
public enum DiaryCodec {
    /// 编码为一行 UTF-8 JSON，键按字典序，行尾恰好一个 `\n`。
    /// 正文中的换行、引号、反斜杠由 JSONEncoder 转义，因此一篇总是一行。
    public static func encodeLine(_ e: DiaryEntry) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // DiaryEntry 只含字符串和字符串枚举，编码不会失败。
        var data = (try? encoder.encode(e)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// 解码一行 JSON（允许带行尾 `\n` 或 `\r\n`）。
    public static func decodeLine(_ d: Data) throws -> DiaryEntry {
        var body = d
        while let last = body.last, last == 0x0A || last == 0x0D { body.removeLast() }
        return try JSONDecoder().decode(DiaryEntry.self, from: body)
    }
}

// MARK: - 存储

/// `diary.jsonl` 的底层读写。应用层与测试用不同目录，测试也可用内存实现（Requirement 19.4）。
public protocol DiaryStorage: Sendable {
    /// 文件全部内容；文件不存在或无法读取时为 nil。
    func readAll() -> Data?
    /// 在末尾追加一行。失败返回 false，不抛出、不重试（Requirement 13.11）。
    func append(_ line: Data) -> Bool
}

/// 把日记写到 `directory/diary.jsonl`。
///
/// 应用层传 `~/Library/Application Support/Windowfolk/`，测试传临时目录（Requirement 19.4）。
/// 只追加，不截断或改写已有行（Requirement 13.9）。
public struct FileDiaryStorage: DiaryStorage {
    public static let defaultFileName = "diary.jsonl"

    public let directory: URL
    public let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(FileDiaryStorage.defaultFileName, isDirectory: false)
    }

    public func readAll() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    public func append(_ line: Data) -> Bool {
        guard !line.isEmpty else { return true }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                // createFile 会覆盖已有文件，所以只在不存在时调用。
                guard fm.createFile(atPath: fileURL.path, contents: nil) else { return false }
            }
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            var payload = line
            // 已有内容末尾缺换行（例如上次写到一半）时先补一个，
            // 否则新行会接在坏行后面，一起被读取跳过。
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if let last = try handle.read(upToCount: 1), last != Data([0x0A]) {
                    payload.insert(0x0A, at: payload.startIndex)
                }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: payload)
            return true
        } catch {
            return false
        }
    }
}

/// Diary_Store：按 JSONL 追加与读取 Diary_Entry（Requirement 13.9 至 13.11）。
public struct DiaryStore: Sendable {
    public let storage: DiaryStorage

    public init(storage: DiaryStorage) {
        self.storage = storage
    }

    /// 读出全部日记。无法解析的行跳过；同一（日期，居民）有多行时取文件中最后一行（Requirement 13.10）。
    public func entries() -> [DiaryKey: DiaryEntry] {
        guard let data = storage.readAll() else { return [:] }
        var result: [DiaryKey: DiaryEntry] = [:]
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let e = try? DiaryCodec.decodeLine(Data(line)) else { continue }
            result[e.key] = e
        }
        return result
    }

    /// 追加一篇。写入失败返回 false，调用方丢弃该篇（Requirement 13.11）。
    @discardableResult
    public func append(_ e: DiaryEntry) -> Bool {
        storage.append(DiaryCodec.encodeLine(e))
    }
}
