import Foundation
import WindowfolkArtKit

// `generate` 子命令（任务 11.2，design.md「生成计划与请求构造」「Error Handling」「输出与报告」）。
// _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13_
//
// 预检顺序：参数解析 → 清单解析 → `--count` → 未知键 → 参考图存在 → `OPENAI_API_KEY`。
// 任一预检失败都不发请求。试运行与「无待生成素材」不发请求，因此不要求 Key。
// 所有输出经 `Console`（绑定 Key 的 `Redactor`）写出（R3.10）。

/// 一次生成运行的结果：每个 Asset_Key 新保存的文件路径与失败原因（design.md「输出与报告」）。
public struct GenerationReport: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var key: String
        /// 本次新保存的 Raw_Candidate 路径，按序号顺序。
        public var savedPaths: [String]
        /// 每个失败请求的原因，按请求顺序（可重复）。
        public var failureReasons: [String]

        public init(key: String, savedPaths: [String] = [], failureReasons: [String] = []) {
            self.key = key
            self.savedPaths = savedPaths
            self.failureReasons = failureReasons
        }

        public var hasFailures: Bool { !failureReasons.isEmpty }

        /// 去重后的失败原因，保持首次出现的顺序。
        public var distinctReasons: [String] {
            var seen = Set<String>()
            return failureReasons.filter { seen.insert($0).inserted }
        }
    }

    /// 按计划中首次出现的顺序排列。
    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public var allSucceeded: Bool { !entries.contains(where: \.hasFailures) }

    /// 报告行。
    /// - 全部成功：每个 Asset_Key 一行，`<key>  <path>  <path>`（R3.11）。
    /// - 有失败：只列出有失败的 Asset_Key，`<key>  成功 <n> 张  失败原因：<reason>`；
    ///   全部失败时成功张数为 0，格式相同（R3.7、R3.13）。
    public var lines: [String] {
        if allSucceeded {
            return entries.map { ([$0.key] + $0.savedPaths).joined(separator: "  ") }
        }
        return entries.filter(\.hasFailures).map { entry in
            "\(entry.key)  成功 \(entry.savedPaths.count) 张  失败原因：\(entry.distinctReasons.joined(separator: "；"))"
        }
    }

    mutating func recordSuccess(key: String, path: String) {
        mutate(key) { $0.savedPaths.append(path) }
    }

    mutating func recordFailure(key: String, reason: String) {
        mutate(key) { $0.failureReasons.append(reason) }
    }

    private mutating func mutate(_ key: String, _ body: (inout Entry) -> Void) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            body(&entries[index])
        } else {
            var entry = Entry(key: key)
            body(&entry)
            entries.append(entry)
        }
    }
}

/// 一个准备发送的请求：生成任务与对应的图像请求。
public struct PreparedGeneration: Hashable, Sendable {
    public var job: GenerationJob
    public var request: ImageRequest

    public init(job: GenerationJob, request: ImageRequest) {
        self.job = job
        self.request = request
    }
}

public enum GenerateCommand {
    /// 清单路径，相对仓库根目录。
    public static let manifestPath = "art/prompt-manifest.json"
    static let countOption = "--count"
    static let dryRunFlag = "--dry-run"

    public static let noPendingMessage = "没有待生成的素材：清单中每个 Asset_Key 在 art/work/ 下都已有至少 1 张 PNG。"
    public static let missingKeyMessage =
        "错误：未设置 \(GenerationPlanner.apiKeyVariable)，或其值为空白。请先设置该环境变量再运行 generate。"

    /// `generate [<key>...] [--count N] [--dry-run]`。`arguments` 不含子命令名。
    public static func run(_ arguments: [String], environment: CommandEnvironment) async -> ExitStatus {
        let console = environment.console
        let store = environment.fileStore
        let usage = CommandRouter.descriptor(["generate"]).map { [$0] }

        // 1. 参数解析（用法错误 64）。
        let parsed: ParsedArguments
        switch ArgumentParser.parse(arguments, valueOptions: [countOption], flags: [dryRunFlag]) {
        case .success(let value): parsed = value
        case .failure(let error):
            return CommandRouter.usageFailure("错误：\(error.message)", commands: usage, console: console)
        }

        // 2. 清单解析。参考图是否存在只对待处理条目检查（第 5 步，R3.8），这里视为存在。
        let manifest: PromptManifest
        let manifestData: Data
        do {
            manifestData = try store.read(manifestPath)
        } catch {
            console.error("错误：无法读取清单 \(manifestPath)：\(error.reason)")
            return .failure
        }
        switch ManifestParser.parse(manifestData, fileExists: { _ in true }) {
        case .success(let value): manifest = value
        case .failure(let issues):
            console.error("错误：清单 \(manifestPath) 未通过解析：")
            for issue in issues { console.error("  \(issue)") }
            return .failure
        }

        // 3. `--count`（非法为用法错误 64）。
        let count: Int
        switch ArgumentParser.count(parsed.options[countOption]) {
        case .success(let value): count = value
        case .failure(let error):
            return CommandRouter.usageFailure("错误：\(error.message)", commands: usage, console: console)
        }

        // 4. 生成计划（未知键）。
        let requested = parsed.positionals
        let candidateKeys = requested.isEmpty ? manifest.entries.map(\.key) : requested
        var existing: [String: [String]] = [:]
        for key in Set(candidateKeys) {
            existing[key] = store.pngFiles(in: "\(GenerationPlanner.workDirectory)/\(key)")
        }
        let jobs: [GenerationJob]
        switch GenerationPlanner.plan(manifest: manifest, requested: requested, count: count, existingPNGs: existing) {
        case .success(let value): jobs = value
        case .failure(let errors):
            for message in errors { console.error("错误：\(message)") }
            return .failure
        }

        // 5. 待处理条目的参考图必须存在。
        let missing = GenerationPlanner.missingReferences(for: jobs, manifest: manifest, fileExists: store.fileExists)
        if !missing.isEmpty {
            for path in missing { console.error("错误：参考图不存在：\(path)") }
            return .failure
        }

        if jobs.isEmpty {
            console.line(noPendingMessage)
            return .success
        }

        let model = ModelName.resolve(environment.variables)
        let prepared = jobs.compactMap { job -> PreparedGeneration? in
            guard let entry = manifest.entry(for: job.key),
                  let prompt = PromptComposer.compose(manifest, key: job.key) else { return nil }
            return PreparedGeneration(job: job, request: RequestBuilder.request(for: entry, prompt: prompt, model: model))
        }

        if parsed.has(dryRunFlag) {
            printDryRun(prepared, console: console)
            return .success
        }

        // 6. API Key（R3.6）。
        guard let apiKey = environment.apiKey else {
            console.error(missingKeyMessage)
            return .failure
        }

        let report = await execute(prepared, apiKey: apiKey, environment: environment)
        return finish(report, console: console)
    }

    // MARK: - 试运行

    /// 逐个打印将要发送的请求（R3.9）。不写文件、不发请求。
    static func printDryRun(_ prepared: [PreparedGeneration], console: Console) {
        console.line("试运行：共 \(prepared.count) 个请求，不发送、不写文件。")
        for (offset, item) in prepared.enumerated() {
            let request = item.request
            console.line("")
            console.line("[\(offset + 1)/\(prepared.count)] \(item.job.key) #\(item.job.candidateIndex)")
            console.line("  Asset_Key：\(item.job.key)")
            console.line("  模型：\(request.model)")
            console.line("  画布：\(request.size.canvasString)")
            if request.references.isEmpty {
                console.line("  参考图：无")
            } else {
                console.line("  参考图：")
                for path in request.references { console.line("    \(path)") }
            }
            console.line("  输出：\(item.job.outputPath)")
            console.line("  提示词：")
            console.line(request.prompt)
        }
    }

    // MARK: - 发送

    /// 顺序发送请求，每个请求 `n=1`。成功且返回内容可解码为 PNG 时写 `outputPath`（不覆盖）；
    /// 失败时不写文件、记录原因并继续（R3.7）。模型不可用或鉴权失败时，剩余请求不再发送，
    /// 直接记为同一原因的失败。进度行写到标准输出（R3.12）。
    public static func execute(
        _ prepared: [PreparedGeneration], apiKey: String, environment: CommandEnvironment
    ) async -> GenerationReport {
        let console = environment.console
        let store = environment.fileStore
        let total = prepared.count
        let boundary = "windowfolk-\(UUID().uuidString)"
        var report = GenerationReport()
        var referenceCache: [String: Result<[Data], FileStoreError>] = [:]
        var stopReason: String?

        for (offset, item) in prepared.enumerated() {
            let job = item.job
            let label = "\(job.key) #\(job.candidateIndex)"
            if let stopReason {
                report.recordFailure(key: job.key, reason: stopReason)
                continue
            }

            let references: [Data]
            let cacheKey = item.request.references.joined(separator: "\n")
            let loaded = referenceCache[cacheKey] ?? loadReferences(item.request.references, store: store)
            referenceCache[cacheKey] = loaded
            switch loaded {
            case .success(let data): references = data
            case .failure(let error):
                let reason = "无法读取参考图 \(error.path)：\(error.reason)"
                console.line("[\(offset + 1)/\(total)] 跳过 \(label)  失败：\(reason)")
                report.recordFailure(key: job.key, reason: reason)
                continue
            }

            console.line("[\(offset + 1)/\(total)] 发送 \(label)")
            let body = RequestBuilder.body(item.request, referenceData: references, boundary: boundary)
            let contentType = RequestBuilder.contentType(item.request, boundary: boundary)
            let result = await environment.transport.send(
                item.request, body: body, contentType: contentType, apiKey: apiKey)

            // 成功时为写出的路径，失败时为原因。
            var savedPath: String?
            var failureReason: String?
            switch result {
            case .failure(let failure):
                failureReason = failure.reason
                if failure.stopsRemainingRequests { stopReason = failure.reason }
            case .success(let data):
                if PNGCodec.decode(data) == nil {
                    failureReason = GenerationFailure.undecodable.reason
                } else {
                    do {
                        try store.writeNew(data, to: job.outputPath)
                        savedPath = job.outputPath
                    } catch {
                        failureReason = "写入 \(job.outputPath) 失败：\(error.reason)"
                    }
                }
            }

            if let savedPath {
                console.line("[\(offset + 1)/\(total)] 完成 \(label)")
                report.recordSuccess(key: job.key, path: savedPath)
            } else {
                let reason = failureReason ?? GenerationFailure.undecodable.reason
                console.line("[\(offset + 1)/\(total)] 完成 \(label)  失败：\(reason)")
                report.recordFailure(key: job.key, reason: reason)
            }

            let remaining = total - offset - 1
            if let stopReason, remaining > 0 {
                console.line("已停止发送其余 \(remaining) 个请求，均记为失败：\(stopReason)")
            }
        }

        return report
    }

    /// 打印最终报告并给出退出码：全部成功为 0，否则为 1（R3.7、R3.11、R3.13）。
    static func finish(_ report: GenerationReport, console: Console) -> ExitStatus {
        if report.allSucceeded {
            console.line("")
            console.line("全部请求成功：")
            for line in report.lines { console.line(line) }
            return .success
        }
        console.line("")
        console.line("以下素材有请求失败：")
        for line in report.lines { console.line(line) }
        let failed = report.entries.reduce(0) { $0 + $1.failureReasons.count }
        console.error("错误：\(failed) 个请求失败。")
        return .failure
    }

    private static func loadReferences(_ paths: [String], store: any FileStore) -> Result<[Data], FileStoreError> {
        var result: [Data] = []
        for path in paths {
            do {
                result.append(try store.read(path))
            } catch {
                return .failure(error)
            }
        }
        return .success(result)
    }
}
