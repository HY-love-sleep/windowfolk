import Foundation

// world.json 的文件读写（design.md「Core：SaveFile 与 SaveCodec」、任务 16.3）。
//
// 只用 Foundation，放在 Core 中以便用临时目录测试（Requirement 27.6）。
// 应用层负责传入默认目录、选择后台队列和调用时机。

/// 存档文件底层读取失败的原因。
public enum SaveStoreError: Error, Hashable, Sendable {
    /// 文件不存在。
    case notFound
    /// 文件存在但读取失败。
    case ioError(String)
}

/// 启动时读取存档的结果。
public enum SaveLoadResult: Hashable, Sendable {
    /// 没有 `world.json`：按首次开局处理（Requirement 22.11）。
    case missing
    /// 解析成功。
    case loaded(SaveFile)
    /// 无法读取、无法解析或版本不符：原文件已尝试重命名为备份（重命名失败时忽略），
    /// 调用方按首次开局处理（Requirement 22.12）。`backup` 为备份文件位置，重命名失败时为 nil。
    case corrupt(backup: URL?)
}

/// 存档存储接口（design.md `SaveStore`）。
public protocol SaveStore: Sendable {
    func load() -> Result<Data, SaveStoreError>
    /// 原子写入：失败时原文件不变（Requirement 1.10、22.5）。
    func write(_ d: Data) throws
    /// 把原文件重命名为 `world.corrupt-yyyyMMdd-HHmmss.json`，返回备份位置。
    @discardableResult
    func backupCorrupt(now: Date) throws -> URL
}

extension SaveStore {
    /// 读取并解析存档。解析失败或版本不符时备份原文件后返回 `.corrupt`（Requirement 22.12）。
    public func loadSave(now: Date = Date()) -> SaveLoadResult {
        let data: Data
        switch load() {
        case .failure(.notFound):
            return .missing
        case .failure(.ioError):
            return .corrupt(backup: try? backupCorrupt(now: now))
        case let .success(d):
            data = d
        }
        do {
            return .loaded(try SaveCodec.decode(data))
        } catch {
            return .corrupt(backup: try? backupCorrupt(now: now))
        }
    }

    /// 编码并原子写入，返回是否成功。失败时原文件不变，调用方在下一个周期重试（Requirement 22.5）。
    @discardableResult
    public func save(_ file: SaveFile) -> Bool {
        do {
            try write(try SaveCodec.encode(file))
            return true
        } catch {
            return false
        }
    }
}

/// 把存档写到某个目录下的 `world.json`。
///
/// 实例只有不可变属性，可以交给后台串行队列使用；同一文件的写入应由调用方串行化。
public final class FileSaveStore: SaveStore {
    public static let defaultFileName = "world.json"

    public let directory: URL
    public let fileURL: URL

    public init(directory: URL, fileName: String = FileSaveStore.defaultFileName) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// 默认目录 `~/Library/Application Support/Windowfolk/`。只计算路径，不创建目录。
    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Windowfolk", isDirectory: true)
    }

    public func load() -> Result<Data, SaveStoreError> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .failure(.notFound) }
        do {
            return .success(try Data(contentsOf: fileURL))
        } catch {
            return .failure(.ioError(String(describing: error)))
        }
    }

    /// `.atomic` 先写临时文件再替换，写到一半失败不会留下截断的 `world.json`。
    public func write(_ d: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try d.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    public func backupCorrupt(now: Date) throws -> URL {
        let fm = FileManager.default
        let stamp = Self.timestamp(now)
        var target = directory.appendingPathComponent("world.corrupt-\(stamp).json", isDirectory: false)
        // 同一秒内多次备份时加序号，绝不覆盖已有备份。
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("world.corrupt-\(stamp)-\(n).json", isDirectory: false)
            n += 1
        }
        try fm.moveItem(at: fileURL, to: target)
        return target
    }

    /// `yyyyMMdd-HHmmss`，按本机时区。
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
