import Foundation
import WindowfolkArtKit

// 子命令分发（任务 11.1）。各子命令的处理函数在任务 11.2 至 11.13 中逐一接入。
// _Requirements: 9.6, 9.7_

/// 一个子命令：名称路径（如 `["sheet", "compose"]`）、用法行和处理函数。
public struct CommandDescriptor: Sendable {
    /// 子命令名称路径，`sheet generate` 为两段。
    public var path: [String]
    /// 用法行中程序名之后的部分。
    public var usage: String
    /// 处理函数：收到名称路径之后的参数。
    public var handler: @Sendable (_ arguments: [String], _ environment: CommandEnvironment) async -> ExitStatus

    public init(
        path: [String],
        usage: String,
        handler: @escaping @Sendable (_ arguments: [String], _ environment: CommandEnvironment) async -> ExitStatus
    ) {
        self.path = path
        self.usage = usage
        self.handler = handler
    }

    public var name: String { path.joined(separator: " ") }
}

public enum CommandRouter {
    public static let programName = "windowfolk-art"

    /// 全部子命令，按用法输出顺序排列。
    public static let commands: [CommandDescriptor] = [
        CommandDescriptor(path: ["generate"], usage: "generate [<key>...] [--count N] [--dry-run]") { arguments, environment in
            await GenerateCommand.run(arguments, environment: environment)
        },
        CommandDescriptor(path: ["process"], usage: "process <key> <raw.png>") { arguments, environment in
            await ProcessCommand.run(arguments, environment: environment)
        },
        CommandDescriptor(path: ["promote"], usage: "promote <key> <candidate.png>") { arguments, environment in
            await PromoteCommand.run(arguments, environment: environment)
        },
        CommandDescriptor(path: ["validate"], usage: "validate [<dir>]          默认 Assets") { arguments, environment in
            await ValidateCommand.run(arguments, environment: environment)
        },
        CommandDescriptor(path: ["preview"], usage: "preview [<dir>]           默认 Assets") { arguments, environment in
            await PreviewCommand.run(arguments, environment: environment)
        },
        CommandDescriptor(
            path: ["sheet", "generate"],
            usage: "sheet generate <resident_a|resident_b> [--count N] [--dry-run]"
        ) { arguments, environment in
            await SheetCommand.generate(arguments, environment: environment)
        },
        CommandDescriptor(
            path: ["sheet", "compose"],
            usage: "sheet compose <resident_a|resident_b> <raw.png>"
        ) { arguments, environment in
            await SheetCommand.compose(arguments, environment: environment)
        },
    ]

    /// 运行一次命令行调用。`arguments` 不含程序名。
    ///
    /// - 无参数、未知子命令：向标准错误打印用法，返回 64。
    /// - `help`、`--help`、`-h`：向标准输出打印用法，返回 0（不要求在仓库根目录）。
    /// - 已知子命令但当前目录不是仓库根目录：返回 64。
    /// - 其余交给子命令处理函数，返回其结果。
    public static func run(arguments: [String], environment: CommandEnvironment) async -> ExitStatus {
        let console = environment.console
        guard let first = arguments.first else {
            return usageFailure("错误：缺少子命令", console: console)
        }
        if ["help", "--help", "-h"].contains(first), arguments.count == 1 {
            console.line(usageText())
            return .success
        }
        guard let command = match(arguments) else {
            let group = commands.filter { $0.path.first == first }
            if group.isEmpty {
                return usageFailure("错误：未知子命令 \(first)", console: console)
            }
            let message = arguments.count > 1
                ? "错误：未知子命令 \(first) \(arguments[1])"
                : "错误：\(first) 缺少子命令"
            return usageFailure(message, commands: group, console: console)
        }
        guard RepositoryRoot.isRepositoryRoot(environment.fileStore) else {
            console.error(RepositoryRoot.errorMessage)
            return .usage
        }
        let rest = Array(arguments.dropFirst(command.path.count))
        return await command.handler(rest, environment)
    }

    /// 名称路径与参数开头完全一致的子命令（取最长的匹配）。
    public static func match(_ arguments: [String]) -> CommandDescriptor? {
        commands
            .filter { arguments.count >= $0.path.count && Array(arguments.prefix($0.path.count)) == $0.path }
            .max { $0.path.count < $1.path.count }
    }

    /// 用法文本。`selected` 为 nil 时列出全部子命令。
    public static func usageText(for selected: [CommandDescriptor]? = nil) -> String {
        let list = selected ?? commands
        var lines = ["用法："]
        lines += list.map { "  \(programName) \($0.usage)" }
        lines.append("")
        lines.append("退出码：0 成功；1 操作失败；64 用法错误。")
        lines.append("须在仓库根目录（含 Package.swift 和 art/）运行。")
        return lines.joined(separator: "\n")
    }

    /// 打印错误与用法到标准错误并返回 64。子命令遇到缺参数或选项非法时调用。
    public static func usageFailure(
        _ message: String,
        commands selected: [CommandDescriptor]? = nil,
        console: Console
    ) -> ExitStatus {
        console.error(message)
        console.error(usageText(for: selected))
        return .usage
    }

    /// 按名称路径查子命令的用法描述，供子命令在用法错误时引用。
    public static func descriptor(_ path: [String]) -> CommandDescriptor? {
        commands.first { $0.path == path }
    }
}
