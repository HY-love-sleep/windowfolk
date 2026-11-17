import Foundation
import WindowfolkArtKit
import WindowfolkCore

// `validate` 子命令（任务 11.9，design.md「Asset_Validator 规则」「Error Handling」）。
// _Requirements: 6.1, 6.8, 6.9, 6.13_
//
// `validate [<dir>]`（默认 `Assets`）：目录不存在或不可读时只打印路径并退出 1；
// 否则按 Asset_Catalog 顺序输出 45 行，再逐个列出未知 `.png` 文件；全部通过时退出 0。

public enum ValidateCommand {
    /// 未指定目录时检查的目录。
    public static let defaultDirectory = PromoteCommand.assetsDirectory

    public static func run(_ arguments: [String], environment: CommandEnvironment) async -> ExitStatus {
        let console = environment.console
        let store = environment.fileStore
        let usage = CommandRouter.descriptor(["validate"]).map { [$0] }

        let parsed: ParsedArguments
        switch ArgumentParser.parse(arguments) {
        case .success(let value): parsed = value
        case .failure(let error):
            return CommandRouter.usageFailure("错误：\(error.message)", commands: usage, console: console)
        }
        guard parsed.positionals.count <= 1 else {
            return CommandRouter.usageFailure(
                "错误：validate 最多接受 1 个目录参数", commands: usage, console: console)
        }
        let directory = parsed.positionals.first ?? defaultDirectory

        guard store.directoryExists(directory) else {
            console.error("错误：目录不存在或不可读：\(directory)")
            return .failure
        }
        let listing: [String]
        do {
            listing = try store.listDirectory(directory)
        } catch {
            console.error("错误：目录不存在或不可读：\(directory)")
            return .failure
        }

        let report = AssetValidator.report(
            directoryListing: listing,
            verdicts: verdicts(in: directory, listing: listing, store: store))
        for line in report.outputLines { console.line(line) }
        return report.allPassed ? .success : .failure
    }

    /// 目录中存在的 Asset_Key 文件的校验结论。
    static func verdicts(
        in directory: String, listing: [String], store: any FileStore
    ) -> [String: AssetVerdict] {
        let present = Set(listing)
        var verdicts: [String: AssetVerdict] = [:]
        for spec in AssetCatalog.all where present.contains(spec.fileName) {
            var decoded: DecodedPNG?
            if let data = try? store.read("\(directory)/\(spec.fileName)") {
                decoded = PNGCodec.decode(data)
            }
            verdicts[spec.key] = AssetValidator.validate(key: spec.key, decoded: decoded)
        }
        return verdicts
    }
}
