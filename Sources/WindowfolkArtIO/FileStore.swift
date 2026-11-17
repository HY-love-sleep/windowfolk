import Foundation

/// 文件操作的步骤，用于错误报告（R5.6 要求输出失败的步骤）。
public enum FileStoreStep: String, Sendable, Equatable {
    case list = "列举"
    case read = "读取"
    case write = "写入"
    case backup = "备份"
}

/// 文件操作失败：步骤、涉及的路径和原因。
public struct FileStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    public var step: FileStoreStep
    public var path: String
    public var reason: String

    public init(step: FileStoreStep, path: String, reason: String) {
        self.step = step
        self.path = path
        self.reason = reason
    }

    public var description: String { "\(step.rawValue)失败：\(path)：\(reason)" }
}

/// 流水线使用的文件操作。以协议提供，测试可注入写入或备份失败。
///
/// 所有 `path` 参数为相对仓库根目录的路径；以 `/` 开头时按绝对路径处理。
public protocol FileStore: Sendable {
    /// 把路径解析为文件 URL。
    func url(for path: String) -> URL
    /// 路径存在且是普通文件（非目录）。
    func fileExists(_ path: String) -> Bool
    /// 路径存在且是目录。
    func directoryExists(_ path: String) -> Bool
    /// 列出目录中的条目名（不含子路径），按名称排序。
    func listDirectory(_ path: String) throws(FileStoreError) -> [String]
    /// 读取文件全部字节。
    func read(_ path: String) throws(FileStoreError) -> Data
    /// 写入新文件：原子写入且目标已存在时失败，必要时创建父目录。
    func writeNew(_ data: Data, to path: String) throws(FileStoreError)
    /// 覆盖写入：原子写入（失败时不留下部分文件，原文件保持完整），必要时创建父目录。
    func overwrite(_ data: Data, to path: String) throws(FileStoreError)
    /// 把 `path` 逐字节复制到 `art/work/backups/<key>-<yyyyMMdd-HHmmss>-<n>.png`，
    /// `n` 从 1 起取第一个未被占用的值，不覆盖已有备份。返回备份文件的路径。
    func backup(_ path: String, key: String) throws(FileStoreError) -> String
}

extension FileStore {
    /// 目录中形如 `<prefix>_<n>.png` 的文件序号，升序。目录不存在时为空（R3.5、R4.1）。
    public func candidateNumbers(in directory: String, prefix: String) -> [Int] {
        guard let names = try? listDirectory(directory) else { return [] }
        return CandidateNaming.numbers(in: names, prefix: prefix)
    }

    /// 下一个可用序号：已有最大序号加 1，没有时为 1。
    public func nextCandidateNumber(in directory: String, prefix: String) -> Int {
        (candidateNumbers(in: directory, prefix: prefix).max() ?? 0) + 1
    }

    /// 目录中的 `.png` 文件名，按名称排序；目录不存在时为空。
    public func pngFiles(in directory: String) -> [String] {
        guard let names = try? listDirectory(directory) else { return [] }
        return names.filter { $0.lowercased().hasSuffix(".png") }
    }

    /// 用 `data` 替换 `path`：已有文件时先备份（备份失败则不写入），再原子覆盖写入。
    /// 返回备份路径（原本没有文件时为 nil）。任一步失败时原文件保持完整（R5.2、R5.4、R5.6）。
    @discardableResult
    public func replace(_ path: String, with data: Data, backupKey key: String) throws(FileStoreError) -> String? {
        var backupPath: String?
        if fileExists(path) {
            backupPath = try backup(path, key: key)
        }
        try overwrite(data, to: path)
        return backupPath
    }
}

/// 候选与备份文件的命名规则。
public enum CandidateNaming {
    /// 候选文件名 `<prefix>_<n>.png`。
    public static func fileName(prefix: String, number: Int) -> String {
        "\(prefix)_\(number).png"
    }

    /// 从文件名列表中取出 `<prefix>_<n>.png` 的序号（n 为正整数，仅十进制数字），升序去重。
    /// 前缀与后缀都不区分大小写：macOS 默认文件系统上 `Raw_7.png` 与 `raw_7.png` 是同一个文件。
    public static func numbers(in names: [String], prefix: String) -> [Int] {
        let head = (prefix + "_").lowercased()
        let tail = ".png"
        var result = Set<Int>()
        for name in names {
            let lower = name.lowercased()
            guard lower.hasPrefix(head), lower.hasSuffix(tail), lower.count > head.count + tail.count else { continue }
            let digits = lower.dropFirst(head.count).dropLast(tail.count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(digits), n > 0 else { continue }
            result.insert(n)
        }
        return result.sorted()
    }

    /// 备份文件名 `<key>-<yyyyMMdd-HHmmss>-<n>.png`。
    public static func backupFileName(key: String, timestamp: String, number: Int) -> String {
        "\(key)-\(timestamp)-\(number).png"
    }

    /// `yyyyMMdd-HHmmss` 格式的时间戳。
    public static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ width: Int) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2) + "-"
            + pad(c.hour, 2) + pad(c.minute, 2) + pad(c.second, 2)
    }
}

/// 基于本地文件系统的实现。根目录可注入，测试使用临时目录。
public struct LocalFileStore: FileStore {
    /// 相对路径的基准目录（通常是仓库根目录）。
    public let root: URL
    /// 备份目录（相对 `root`）。
    public let backupDirectory: String
    /// 生成备份时间戳用的时钟与时区。
    public let now: @Sendable () -> Date
    public let timeZone: TimeZone

    public init(
        root: URL,
        backupDirectory: String = "art/work/backups",
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root.standardizedFileURL
        self.backupDirectory = backupDirectory
        self.timeZone = timeZone
        self.now = now
    }

    /// 以当前工作目录为根。
    public static func currentDirectory() -> LocalFileStore {
        LocalFileStore(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    }

    public func url(for path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return root.appendingPathComponent(path).standardizedFileURL
    }

    public func fileExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(for: path).path, isDirectory: &isDir) && !isDir.boolValue
    }

    public func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(for: path).path, isDirectory: &isDir) && isDir.boolValue
    }

    public func listDirectory(_ path: String) throws(FileStoreError) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: url(for: path).path).sorted()
        } catch {
            throw FileStoreError(step: .list, path: path, reason: Self.reason(error))
        }
    }

    public func read(_ path: String) throws(FileStoreError) -> Data {
        do {
            return try Data(contentsOf: url(for: path))
        } catch {
            throw FileStoreError(step: .read, path: path, reason: Self.reason(error))
        }
    }

    public func writeNew(_ data: Data, to path: String) throws(FileStoreError) {
        try writeExclusive(data, to: path, step: .write)
    }

    public func overwrite(_ data: Data, to path: String) throws(FileStoreError) {
        try write(data, to: path, options: [.atomic], step: .write)
    }

    public func backup(_ path: String, key: String) throws(FileStoreError) -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url(for: path))
        } catch {
            throw FileStoreError(step: .backup, path: path, reason: Self.reason(error))
        }
        let stamp = CandidateNaming.timestamp(now(), timeZone: timeZone)
        var number = 1
        while true {
            let name = CandidateNaming.backupFileName(key: key, timestamp: stamp, number: number)
            let target = (backupDirectory as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url(for: target).path) {
                number += 1
                continue
            }
            do {
                try writeExclusive(data, to: target, step: .backup)
                return target
            } catch {
                // 并发出现同名备份时换下一个序号；其他错误直接报告。
                if FileManager.default.fileExists(atPath: url(for: target).path) {
                    number += 1
                    continue
                }
                throw error
            }
        }
    }

    /// 原子且不覆盖地写入：先写同目录临时文件，再以 `RENAME_EXCL` 改名到目标。
    /// Foundation 不支持 `.atomic` 与 `.withoutOverwriting` 同时使用，因此手工实现。
    /// 任何一步失败都删除临时文件，目标路径不会出现部分内容。
    private func writeExclusive(_ data: Data, to path: String, step: FileStoreStep) throws(FileStoreError) {
        let target = url(for: path)
        let directory = target.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp, options: [.withoutOverwriting])
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw FileStoreError(step: step, path: path, reason: Self.reason(error))
        }
        let result = temp.withUnsafeFileSystemRepresentation { src in
            target.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return EINVAL }
                return renamex_np(src, dst, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        if result != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw FileStoreError(step: step, path: path, reason: String(cString: strerror(result)))
        }
    }

    private func write(_ data: Data, to path: String, options: Data.WritingOptions,
                       step: FileStoreStep) throws(FileStoreError) {
        let target = url(for: path)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: options)
        } catch {
            throw FileStoreError(step: step, path: path, reason: Self.reason(error))
        }
    }

    private static func reason(_ error: any Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
            return "\(ns.localizedDescription)（\(String(cString: strerror(code.rawValue)))）"
        }
        return ns.localizedDescription
    }
}
