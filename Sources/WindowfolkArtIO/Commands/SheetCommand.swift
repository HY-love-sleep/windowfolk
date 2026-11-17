import Foundation
import WindowfolkArtKit
import WindowfolkCore

// `sheet generate` / `sheet compose` 子命令（任务 11.13，design.md「Character_Sheet 布局」）。
// _Requirements: 1.1, 1.4, 1.5_
//
// 解析清单时把两张设定图路径视为存在（设定图尚未生成时清单也能通过），只取前缀与 Palette。
// `sheet generate` 用 `CharacterSheetPrompts` 调用 generations 接口，输出到
// `art/work/sheets/<resident>/raw_<n>.png`；`sheet compose` 把原始图三等分、去背景，
// 按 `SheetLayout` 排版后写入 `art/character_sheets/<resident>.png`。

public enum SheetCommand {
    static let countOption = "--count"
    static let dryRunFlag = "--dry-run"
    static let candidatePrefix = "raw"

    /// `art/work/sheets`，相对仓库根目录。
    public static let workDirectory = "\(GenerationPlanner.workDirectory)/sheets"

    // MARK: - sheet generate

    public static func generate(_ arguments: [String], environment: CommandEnvironment) async -> ExitStatus {
        let console = environment.console
        let usage = CommandRouter.descriptor(["sheet", "generate"]).map { [$0] }

        let parsed: ParsedArguments
        switch ArgumentParser.parse(arguments, valueOptions: [countOption], flags: [dryRunFlag]) {
        case .success(let value): parsed = value
        case .failure(let error):
            return CommandRouter.usageFailure("错误：\(error.message)", commands: usage, console: console)
        }
        guard parsed.positionals.count == 1, let owner = resident(parsed.positionals[0]) else {
            let message = parsed.positionals.count == 1
                ? "错误：未知的居民 \(parsed.positionals[0])（可用 resident_a 或 resident_b）"
                : "错误：sheet generate 需要 1 个参数：<resident_a|resident_b>"
            return CommandRouter.usageFailure(message, commands: usage, console: console)
        }
        guard let manifest = loadManifest(environment: environment) else { return .failure }

        let count: Int
        switch ArgumentParser.count(parsed.options[countOption]) {
        case .success(let value): count = value
        case .failure(let error):
            return CommandRouter.usageFailure("错误：\(error.message)", commands: usage, console: console)
        }

        let name = owner.residentID.rawValue
        let directory = "\(workDirectory)/\(name)"
        let start = environment.fileStore.nextCandidateNumber(in: directory, prefix: candidatePrefix)
        let model = ModelName.resolve(environment.variables)
        let prompt = CharacterSheetPrompts.compose(manifest, owner: owner)
        let entry = PromptEntry(
            key: name,
            description: CharacterSheetPrompts.description(for: owner),
            frames: 1,
            canvas: CharacterSheetPrompts.requestCanvas,
            references: [])
        let request = RequestBuilder.request(for: entry, prompt: prompt, model: model)

        let prepared = (start..<(start + count)).map { index in
            PreparedGeneration(
                job: GenerationJob(
                    key: name,
                    candidateIndex: index,
                    outputPath: "\(directory)/\(CandidateNaming.fileName(prefix: candidatePrefix, number: index))"),
                request: request)
        }

        if parsed.has(dryRunFlag) {
            GenerateCommand.printDryRun(prepared, console: console)
            return .success
        }

        guard let apiKey = environment.apiKey else {
            console.error(GenerateCommand.missingKeyMessage)
            return .failure
        }
        let report = await GenerateCommand.execute(prepared, apiKey: apiKey, environment: environment)
        return GenerateCommand.finish(report, console: console)
    }

    // MARK: - sheet compose

    public static func compose(_ arguments: [String], environment: CommandEnvironment) async -> ExitStatus {
        let console = environment.console
        let store = environment.fileStore
        let usage = CommandRouter.descriptor(["sheet", "compose"]).map { [$0] }

        let parsed: ParsedArguments
        switch ArgumentParser.parse(arguments) {
        case .success(let value): parsed = value
        case .failure(let error):
            return CommandRouter.usageFailure("错误：\(error.message)", commands: usage, console: console)
        }
        guard parsed.positionals.count == 2, let owner = resident(parsed.positionals[0]) else {
            let message = parsed.positionals.count == 2
                ? "错误：未知的居民 \(parsed.positionals[0])（可用 resident_a 或 resident_b）"
                : "错误：sheet compose 需要 2 个参数：<resident_a|resident_b> <raw.png>"
            return CommandRouter.usageFailure(message, commands: usage, console: console)
        }
        let rawPath = parsed.positionals[1]

        guard let manifest = loadManifest(environment: environment) else { return .failure }
        let group = CharacterSheetPrompts.paletteGroup(for: owner)
        guard let colors = SheetLayout.swatchColors(manifest.palettes[group] ?? [:]) else {
            console.error("错误：清单中 Palette \(group.rawValue) 缺少设定图需要的颜色")
            return .failure
        }

        let data: Data
        do {
            data = try store.read(rawPath)
        } catch {
            console.error("错误：无法读取 \(rawPath)：\(error.reason)")
            return .failure
        }
        guard let decoded = PNGCodec.decode(data) else {
            console.error("错误：\(rawPath) 无法解码为 PNG")
            return .failure
        }
        guard decoded.image.width >= SheetLayout.viewCount, decoded.image.height > 0 else {
            console.error("错误：\(rawPath) 的宽度不足以三等分（\(decoded.image.width) 像素）")
            return .failure
        }

        // 三等分并逐视图去背景，再按固定布局排版。
        let views = FrameSlicer.slice(decoded.image, frames: SheetLayout.viewCount)
            .map { BackgroundRemover.remove($0) }
        let sheet = SheetLayout.compose(views: views, palette: colors, resampler: CGResampler())

        let path = CharacterSheetPrompts.sheetPath(for: owner)
        do {
            try store.overwrite(PNGCodec.encode(sheet), to: path)
        } catch {
            console.error("错误：写入 \(path) 失败：\(error.reason)")
            return .failure
        }
        console.line(path)
        return .success
    }

    // MARK: - 内部

    /// `resident_a` / `resident_b` → 居民。其他取值返回 nil。
    static func resident(_ text: String) -> ResidentOwner? {
        ResidentOwner.allCases.first { $0.residentID.rawValue == text }
    }

    /// 读清单并把两张设定图视为存在（只用于取前缀与 Palette）。
    static func loadManifest(environment: CommandEnvironment) -> PromptManifest? {
        let console = environment.console
        let path = GenerateCommand.manifestPath
        let data: Data
        do {
            data = try environment.fileStore.read(path)
        } catch {
            console.error("错误：无法读取清单 \(path)：\(error.reason)")
            return nil
        }
        switch ManifestParser.parse(data, fileExists: { _ in true }) {
        case .success(let manifest):
            return manifest
        case .failure(let issues):
            console.error("错误：清单 \(path) 未通过解析：")
            for issue in issues { console.error("  \(issue)") }
            return nil
        }
    }
}
