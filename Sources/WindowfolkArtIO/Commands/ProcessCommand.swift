import Foundation
import WindowfolkArtKit
import WindowfolkCore

// `process` 子命令（任务 11.5，design.md「后处理算法」末段与「Error Handling」）。
// _Requirements: 4.1, 4.7, 4.12_
//
// `process <key> <raw.png>`：读原始图 → 构造 ProcessContext（读 Assets/resident_<a|b>_idle.png
// 第 1 帧边界框高度）→ `PostProcessor.process` → 写 `art/work/<key>/processed_<n>.png`。
// 任一错误都不写文件，输出 Asset_Key、文件路径和原因（空帧带序号），退出码 1。

public enum ProcessCommand {
    /// Processed_Candidate 的文件名前缀。
    public static let candidatePrefix = "processed"

    public static func run(_ arguments: [String], environment: CommandEnvironment) async -> ExitStatus {
        let console = environment.console
        let store = environment.fileStore
        let usage = CommandRouter.descriptor(["process"]).map { [$0] }

        let parsed: ParsedArguments
        switch ArgumentParser.parse(arguments) {
        case .success(let value): parsed = value
        case .failure(let error):
            return CommandRouter.usageFailure("错误：\(error.message)", commands: usage, console: console)
        }
        guard parsed.positionals.count == 2 else {
            return CommandRouter.usageFailure(
                "错误：process 需要 2 个参数：<key> <raw.png>", commands: usage, console: console)
        }
        let key = parsed.positionals[0]
        let rawPath = parsed.positionals[1]

        let data: Data
        do {
            data = try store.read(rawPath)
        } catch {
            console.error("错误：无法读取 \(key) 的原始图 \(rawPath)：\(error.reason)")
            return .failure
        }
        guard let decoded = PNGCodec.decode(data) else {
            console.error("错误：\(key)  \(rawPath)  无法解码为 PNG")
            return .failure
        }

        let context = ProcessContext(idleReferenceHeight: idleReferenceHeight(for: key, store: store))
        let outcome: ProcessOutcome
        switch PostProcessor.process(decoded.image, key: key, context: context, resampler: CGResampler()) {
        case .success(let value):
            outcome = value
        case .failure(let error):
            console.error("错误：\(key)  \(rawPath)  \(error.description)")
            return .failure
        }

        let directory = "\(GenerationPlanner.workDirectory)/\(key)"
        let index = store.nextCandidateNumber(in: directory, prefix: candidatePrefix)
        let path = "\(directory)/\(CandidateNaming.fileName(prefix: candidatePrefix, number: index))"
        do {
            try store.writeNew(PNGCodec.encode(outcome.image), to: path)
        } catch {
            console.error("错误：\(key)  \(rawPath)  写入 \(path) 失败：\(error.reason)")
            return .failure
        }

        console.line(path)
        for warning in outcome.warnings { console.line("提示：\(warning)") }
        return .success
    }

    /// `Assets/` 中该居民 `idle` Final_Asset 第 1 帧不透明边界框的高度（R4.7）；
    /// 非居民素材、文件不存在或无法解码时为 nil。
    public static func idleReferenceHeight(for key: String, store: any FileStore) -> Int? {
        guard let owner = AssetRules.rules(for: key)?.owner, AssetRules.rules(for: key)?.isGrounded == true else {
            return nil
        }
        let path = "Assets/\(AssetCatalog.residentKey(owner.residentID, .idle)).png"
        guard let data = try? store.read(path), let decoded = PNGCodec.decode(data) else { return nil }
        let frames = AssetCatalog.frameCount(for: .idle)
        guard decoded.image.width >= frames, decoded.image.height > 0 else { return nil }
        let first = FrameSlicer.frameRects(
            width: decoded.image.width, height: decoded.image.height, frames: frames)[0]
        return decoded.image.opaqueBounds(in: first)?.height
    }
}
