import Foundation
import WindowfolkArtKit
import WindowfolkCore

// `preview` 子命令（任务 11.11，design.md「预览与设定图布局」「Error Handling」）。
// _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7_
//
// `preview [<dir>]`（默认 `Assets`）：目录不存在或不可读时不写图并退出 1；
// 否则校验每个键，按 PreviewLayout 生成深色与浅色两张总览图到 `art/work/preview/`（覆盖旧图），
// 打印两条路径与正常、缺失、不合规的数量和名单，退出 0。被检查目录的内容不变。

public enum PreviewCommand {
    public static let defaultDirectory = PromoteCommand.assetsDirectory
    public static let outputDirectory = "\(GenerationPlanner.workDirectory)/preview"

    public static func run(_ arguments: [String], environment: CommandEnvironment) async -> ExitStatus {
        let console = environment.console
        let store = environment.fileStore
        let usage = CommandRouter.descriptor(["preview"]).map { [$0] }

        let parsed: ParsedArguments
        switch ArgumentParser.parse(arguments) {
        case .success(let value): parsed = value
        case .failure(let error):
            return CommandRouter.usageFailure("错误：\(error.message)", commands: usage, console: console)
        }
        guard parsed.positionals.count <= 1 else {
            return CommandRouter.usageFailure(
                "错误：preview 最多接受 1 个目录参数", commands: usage, console: console)
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

        let present = Set(listing)
        var verdicts: [String: AssetVerdict] = [:]
        var images: [String: RGBAImage] = [:]
        for spec in AssetCatalog.all {
            guard present.contains(spec.fileName) else {
                verdicts[spec.key] = .missing
                continue
            }
            guard let data = try? store.read("\(directory)/\(spec.fileName)"),
                  let decoded = PNGCodec.decode(data) else {
                verdicts[spec.key] = AssetValidator.validate(key: spec.key, decoded: nil)
                continue
            }
            let verdict = AssetValidator.validate(key: spec.key, decoded: decoded)
            verdicts[spec.key] = verdict
            if verdict == .pass { images[spec.key] = decoded.image }
        }

        let rendered = PreviewRenderer.renderAll(verdicts: verdicts, images: images)
        var writtenPaths: [String] = []
        for (theme, png) in rendered {
            let path = "\(outputDirectory)/\(theme.fileName)"
            do {
                try store.overwrite(png, to: path)
                writtenPaths.append(path)
            } catch {
                console.error("错误：写入 \(path) 失败：\(error.reason)")
                return .failure
            }
        }

        printSummary(writtenPaths: writtenPaths, verdicts: verdicts, console: console)
        return .success
    }

    /// 两条总览图路径与三类 Asset_Key 的数量和名单（R7.6）。
    static func printSummary(writtenPaths: [String], verdicts: [String: AssetVerdict], console: Console) {
        console.line("总览图：")
        for path in writtenPaths { console.line("  \(path)") }

        var normal: [String] = []
        var missing: [String] = []
        var invalid: [String] = []
        for spec in AssetCatalog.all {
            switch verdicts[spec.key] {
            case .pass?: normal.append(spec.key)
            case .fail?: invalid.append(spec.key)
            case .missing?, nil: missing.append(spec.key)
            }
        }
        console.line(summaryLine(label: "正常显示", keys: normal))
        console.line(summaryLine(label: "缺失", keys: missing))
        console.line(summaryLine(label: "不合规", keys: invalid))
    }

    private static func summaryLine(label: String, keys: [String]) -> String {
        keys.isEmpty ? "\(label) 0 项" : "\(label) \(keys.count) 项：" + keys.joined(separator: "、")
    }
}
