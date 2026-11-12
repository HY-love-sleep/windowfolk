import Foundation

/// 把事件行追加到 `events.jsonl` 的输出端（Requirement 21.2、21.10、21.11）。
///
/// - 目录在构造时传入：应用层传 `~/Library/Application Support/Windowfolk/`，
///   测试传临时目录，因此 `swift test` 不碰用户数据（Requirement 27.6）。
/// - 只追加，从不读取或截断已有内容（Requirement 21.2、21.12）。
/// - 目录或文件不存在时先创建（Requirement 21.10）。
/// - 任何失败都丢弃该条记录，不重试、不抛出（Requirement 21.11）。
///
/// 实例只有不可变属性，可以交给后台串行队列使用；同一文件的追加应由调用方串行化。
public final class FileEventSink: EventSink, Sendable {
    public static let defaultFileName = "events.jsonl"

    public let directory: URL
    public let fileURL: URL

    public init(directory: URL, fileName: String = FileEventSink.defaultFileName) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// 默认目录 `~/Library/Application Support/Windowfolk/`。只计算路径，不创建目录。
    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Windowfolk", isDirectory: true)
    }

    public func append(_ line: Data) {
        _ = tryAppend(line)
    }

    /// 追加一行，返回是否成功。失败时文件保持原样（最多缺这一行）。
    @discardableResult
    public func tryAppend(_ line: Data) -> Bool {
        guard !line.isEmpty else { return true }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                // 只在文件不存在时创建；createFile 会覆盖已有文件，所以先检查。
                guard fm.createFile(atPath: fileURL.path, contents: nil) else { return false }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }
}
