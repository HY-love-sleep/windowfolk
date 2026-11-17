import Foundation
import WindowfolkArtKit

// 命令行基础设施（任务 11.1）：退出码、输出通道、运行环境与手工参数解析。
// 子命令实现放在本目录，测试直接调用；`windowfolk-art/main.swift` 只把 `ExitStatus` 转成进程退出码。
// _Requirements: 3.10, 9.6, 9.7_

// MARK: - 退出码

/// 子命令的结果。退出码 0 只表示输入合法且操作成功（R9.7）。
public enum ExitStatus: Int32, Sendable, Equatable, CustomStringConvertible {
    /// 输入合法且操作成功。
    case success = 0
    /// 操作失败：校验未通过、部分请求失败、文件读写失败等。
    case failure = 1
    /// 用法错误：未知子命令、缺参数、选项值非法、不在仓库根目录运行。
    case usage = 64

    public var description: String { String(rawValue) }
}

// MARK: - 输出通道

/// 可注入的文本输出。正式运行写到标准输出或标准错误，测试使用 `CapturedOutput` 捕获。
public protocol TextOutput: Sendable {
    func write(_ text: String)
}

/// 写到进程的标准输出或标准错误。
public struct StandardStreamOutput: TextOutput {
    public enum Stream: Sendable { case standardOutput, standardError }
    public let stream: Stream

    public init(_ stream: Stream) { self.stream = stream }

    public static let standardOutput = StandardStreamOutput(.standardOutput)
    public static let standardError = StandardStreamOutput(.standardError)

    public func write(_ text: String) {
        let handle = stream == .standardOutput ? FileHandle.standardOutput : FileHandle.standardError
        handle.write(Data(text.utf8))
    }
}

/// 把写入的文本保存在内存中，供测试读取。线程安全。
public final class CapturedOutput: TextOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    public init() {}

    public func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer += text
    }

    /// 到目前为止写入的全部文本。
    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// 按行拆分的文本（不含末尾换行产生的空行）。
    public var lines: [String] {
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }
}

/// 子命令唯一的输出入口：标准输出与标准错误都经过 `Redactor` 脱敏（R3.10）。
///
/// `secret` 为空时仍会替换 `sk-…` 形式的令牌。写到文件的文字也应先调用 `redact(_:)`。
public struct Console: Sendable {
    public let standardOutput: any TextOutput
    public let standardError: any TextOutput
    /// 需要从输出中移除的 API Key；没有 Key 时为空串。
    public let secret: String

    public init(standardOutput: any TextOutput, standardError: any TextOutput, secret: String) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.secret = secret
    }

    /// 脱敏后的文本。
    public func redact(_ text: String) -> String {
        Redactor.redact(text, secret: secret)
    }

    /// 向标准输出写一行。
    public func line(_ text: String = "") {
        standardOutput.write(redact(text) + "\n")
    }

    /// 向标准错误写一行。
    public func error(_ text: String) {
        standardError.write(redact(text) + "\n")
    }
}

// MARK: - 运行环境

/// 子命令运行所需的全部外部依赖。正式运行用 `live`，测试注入临时目录、捕获的输出和假 Transport。
public struct CommandEnvironment: Sendable {
    /// 进程环境变量（`OPENAI_API_KEY`、`WINDOWFOLK_IMAGE_MODEL` 等）。
    public var variables: [String: String]
    /// 以仓库根目录为基准的文件操作。
    public var fileStore: any FileStore
    /// 图像 API 的传输层。
    public var transport: any ImageTransport
    /// 已绑定脱敏 Key 的输出通道。
    public var console: Console

    public init(
        variables: [String: String],
        fileStore: any FileStore,
        transport: any ImageTransport,
        standardOutput: any TextOutput,
        standardError: any TextOutput
    ) {
        self.variables = variables
        self.fileStore = fileStore
        self.transport = transport
        self.console = Console(
            standardOutput: standardOutput,
            standardError: standardError,
            secret: GenerationPlanner.apiKey(from: variables) ?? "")
    }

    /// 正式运行：当前工作目录为根，写到标准输出和标准错误，使用 `URLSessionTransport`。
    public static func live(
        variables: [String: String] = ProcessInfo.processInfo.environment
    ) -> CommandEnvironment {
        CommandEnvironment(
            variables: variables,
            fileStore: LocalFileStore.currentDirectory(),
            transport: URLSessionTransport(),
            standardOutput: StandardStreamOutput.standardOutput,
            standardError: StandardStreamOutput.standardError)
    }

    /// API Key：未设置、为空或只含空白时为 nil（R3.6）。
    public var apiKey: String? { GenerationPlanner.apiKey(from: variables) }
}

// MARK: - 仓库根目录

public enum RepositoryRoot {
    /// 当前根目录含 `Package.swift` 文件和 `art/` 目录时视为仓库根目录。
    public static func isRepositoryRoot(_ store: any FileStore) -> Bool {
        store.fileExists("Package.swift") && store.directoryExists("art")
    }

    public static let errorMessage = "错误：请在仓库根目录（含 Package.swift 和 art/ 的目录）运行 windowfolk-art"
}

// MARK: - 参数解析

/// 用法错误，对应退出码 64。
public struct UsageError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// 解析后的参数：位置参数按原顺序保留，带值选项与开关按名称（含 `--` 前缀）保存。
public struct ParsedArguments: Equatable, Sendable {
    public var positionals: [String]
    public var options: [String: String]
    public var flags: Set<String>

    public init(positionals: [String] = [], options: [String: String] = [:], flags: Set<String> = []) {
        self.positionals = positionals
        self.options = options
        self.flags = flags
    }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }
}

/// 手工参数解析（不引入第三方包，R9.6）。
public enum ArgumentParser {
    /// - `valueOptions`：需要一个值的选项，写作 `--count 3` 或 `--count=3`。
    /// - `flags`：不带值的开关，如 `--dry-run`。
    /// - `--` 之后的参数全部视为位置参数；单独的 `-` 也是位置参数。
    /// - 未知选项、选项缺值、开关带值、同一选项重复出现都是用法错误。
    public static func parse(
        _ arguments: [String],
        valueOptions: Set<String> = [],
        flags: Set<String> = []
    ) -> Result<ParsedArguments, UsageError> {
        var result = ParsedArguments()
        var seen = Set<String>()
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                result.positionals.append(argument)
                continue
            }
            if argument == "--" {
                optionsEnded = true
                continue
            }
            var name = argument
            var inlineValue: String?
            if let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
            }
            if seen.contains(name) {
                return .failure(UsageError("选项 \(name) 重复出现"))
            }
            if valueOptions.contains(name) {
                if let inlineValue {
                    result.options[name] = inlineValue
                } else if index < arguments.count {
                    result.options[name] = arguments[index]
                    index += 1
                } else {
                    return .failure(UsageError("选项 \(name) 缺少取值"))
                }
            } else if flags.contains(name) {
                if inlineValue != nil {
                    return .failure(UsageError("选项 \(name) 不接受取值"))
                }
                result.flags.insert(name)
            } else {
                return .failure(UsageError("未知选项 \(name)"))
            }
            seen.insert(name)
        }
        return .success(result)
    }

    /// `--count` 的取值：未给出时为 `defaultValue`；须为 1 到 8 的十进制整数（R3.8）。
    public static func count(
        _ raw: String?,
        defaultValue: Int = GenerationPlanner.defaultCount
    ) -> Result<Int, UsageError> {
        guard let raw else { return .success(defaultValue) }
        let range = GenerationPlanner.countRange
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(raw), range.contains(value) else {
            return .failure(UsageError(
                "--count 的值 \(raw) 不合法：须为 \(range.lowerBound) 到 \(range.upperBound) 的整数"))
        }
        return .success(value)
    }
}
