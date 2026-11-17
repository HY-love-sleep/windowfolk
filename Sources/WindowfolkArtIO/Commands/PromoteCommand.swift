import Foundation
import WindowfolkArtKit
import WindowfolkCore

// `promote` 子命令（任务 11.7，design.md「WindowfolkArtIO」与「Error Handling」）。
// _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_
//
// `promote <key> <candidate.png>`：键未知、候选不存在或不可读时在校验前退出 1；
// 以指定 Asset_Key 校验候选图，不合规时逐条列出规则且不改动 `Assets/`；
// 合规时先备份同名文件（备份失败则不写入），再原子写入与候选逐字节相同的文件。

public enum PromoteCommand {
    /// Final_Asset 所在目录。
    public static let assetsDirectory = "Assets"

    public static func run(_ arguments: [String], environment: CommandEnvironment) async -> ExitStatus {
        let console = environment.console
        let store = environment.fileStore
        let usage = CommandRouter.descriptor(["promote"]).map { [$0] }

        let parsed: ParsedArguments
        switch ArgumentParser.parse(arguments) {
        case .success(let value): parsed = value
        case .failure(let error):
            return CommandRouter.usageFailure("错误：\(error.message)", commands: usage, console: console)
        }
        guard parsed.positionals.count == 2 else {
            return CommandRouter.usageFailure(
                "错误：promote 需要 2 个参数：<key> <candidate.png>", commands: usage, console: console)
        }
        let key = parsed.positionals[0]
        let candidatePath = parsed.positionals[1]

        guard AssetCatalog.spec(key) != nil, AssetRules.rules(for: key) != nil else {
            console.error("错误：未知的 Asset_Key：\(key)")
            return .failure
        }

        let data: Data
        do {
            data = try store.read(candidatePath)
        } catch {
            console.error("错误：无法读取候选图 \(candidatePath)：\(error.reason)")
            return .failure
        }

        switch AssetValidator.validate(key: key, decoded: PNGCodec.decode(data)) {
        case .pass:
            break
        case .fail(let rules, let emptyFrames):
            console.error("错误：\(key) 未通过校验：")
            for rule in rules { console.error("  \(rule.rawValue)") }
            if !emptyFrames.isEmpty {
                console.error("  空帧：第 " + emptyFrames.map(String.init).joined(separator: "、") + " 帧")
            }
            return .failure
        case .missing:
            console.error("错误：\(key) 未通过校验：文件格式")
            return .failure
        }

        let path = "\(assetsDirectory)/\(key).png"
        do {
            let backup = try store.replace(path, with: data, backupKey: key)
            console.line("\(key)  \(path)")
            if let backup {
                console.line("已备份原文件：\(backup)")
            }
            return .success
        } catch {
            console.error("错误：\(key)  \(path)  \(error.description)")
            return .failure
        }
    }
}
