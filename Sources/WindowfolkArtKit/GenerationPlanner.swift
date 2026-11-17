import Foundation
import WindowfolkCore

// 生成计划（design.md「生成计划与请求构造」，Requirement 3.1、3.2、3.3、3.5、3.6、3.8）。
// 纯逻辑：目录内容、环境变量、文件是否存在都由调用方显式传入，本文件不碰文件系统和网络。

/// 一次生成请求：为 `key` 生成第 `candidateIndex` 张 Raw_Candidate，写到 `outputPath`（相对仓库根目录）。
public struct GenerationJob: Hashable, Sendable {
    public var key: String
    public var candidateIndex: Int
    public var outputPath: String

    public init(key: String, candidateIndex: Int, outputPath: String) {
        self.key = key
        self.candidateIndex = candidateIndex
        self.outputPath = outputPath
    }
}

/// 生成计划失败时的错误信息列表，每项一条可直接输出的说明。
///
/// `Result` 要求 Failure 遵循 `Error`，`[String]` 本身不满足，因此与 `ManifestIssues` 一样用包装类型；
/// 它是随机访问集合，也可以用数组字面量构造。
public struct PlanErrors: Error, Hashable, Sendable, RandomAccessCollection,
    ExpressibleByArrayLiteral, CustomStringConvertible {
    public var messages: [String]

    public init(_ messages: [String]) { self.messages = messages }
    public init(arrayLiteral elements: String...) { self.messages = elements }

    public var startIndex: Int { messages.startIndex }
    public var endIndex: Int { messages.endIndex }
    public subscript(position: Int) -> String { messages[position] }

    /// 每条一行。
    public var description: String { messages.joined(separator: "\n") }
}

public enum GenerationPlanner {
    /// 候选数量选项的合法范围（R3.1）。
    public static let countRange: ClosedRange<Int> = 1...8
    /// 未指定候选数量时的默认值（R3.1）。
    public static let defaultCount = 2
    /// Work_Directory，相对仓库根目录。
    public static let workDirectory = "art/work"
    /// 保存 API Key 的环境变量名（R3.6）。
    public static let apiKeyVariable = "OPENAI_API_KEY"

    /// 生成计划。
    ///
    /// - `requested` 非空：按请求顺序（重复的键只算一次）为每个键安排 `count` 个任务（R3.1）。
    /// - `requested` 为空：按清单顺序，只为 `existingPNGs[key]` 中没有 PNG 文件的键安排（R3.2）；
    ///   全部已有时返回空计划。
    /// - 序号从该键现有最大 `raw_<n>.png` 序号加 1 起连续分配，没有时从 1 开始（R3.5）。
    /// - 未知键、`count` 不在 1 到 8 时返回全部错误信息，不返回任何任务（R3.8）。
    ///
    /// `existingPNGs` 为每个键子目录中的文件名（也接受带目录的路径，只看最后一段）；
    /// 子目录不存在时可缺省该键。
    public static func plan(
        manifest: PromptManifest,
        requested: [String],
        count: Int,
        existingPNGs: [String: [String]]
    ) -> Result<[GenerationJob], PlanErrors> {
        var errors: [String] = []
        if !countRange.contains(count) {
            errors.append("候选数量 \(count) 不合法：须为 \(countRange.lowerBound) 到 \(countRange.upperBound) 的整数")
        }

        var keys: [String] = []
        if requested.isEmpty {
            keys = manifest.entries.map(\.key).filter { key in
                !(existingPNGs[key] ?? []).contains(where: isPNG)
            }
        } else {
            var seen = Set<String>()
            for key in requested where seen.insert(key).inserted {
                if manifest.entry(for: key) == nil {
                    errors.append("未知的 Asset_Key：\(key)")
                } else {
                    keys.append(key)
                }
            }
        }

        guard errors.isEmpty else { return .failure(PlanErrors(errors)) }

        var jobs: [GenerationJob] = []
        jobs.reserveCapacity(keys.count * count)
        for key in keys {
            let start = (existingPNGs[key] ?? []).compactMap(parseRawIndex).max().map { $0 + 1 } ?? 1
            for index in start..<(start + count) {
                jobs.append(GenerationJob(key: key, candidateIndex: index, outputPath: outputPath(key: key, index: index)))
            }
        }
        return .success(jobs)
    }

    /// 计划中各条目列出的、`fileExists` 为假的参考图路径（去重，按出现顺序）。
    /// 调用方在发出任何网络请求前检查，非空则失败（R3.8）。
    public static func missingReferences(
        for jobs: [GenerationJob],
        manifest: PromptManifest,
        fileExists: (String) -> Bool
    ) -> [String] {
        var seenKeys = Set<String>()
        var seenPaths = Set<String>()
        var missing: [String] = []
        for job in jobs where seenKeys.insert(job.key).inserted {
            for path in manifest.entry(for: job.key)?.references ?? []
            where !fileExists(path) && seenPaths.insert(path).inserted {
                missing.append(path)
            }
        }
        return missing
    }

    /// 从环境变量取 API Key；未设置、为空或只含空白时返回 nil（R3.6）。
    /// 返回值是原值（不去空白），保证与用户设置的完全一致。
    public static func apiKey(from env: [String: String]) -> String? {
        guard let value = env[apiKeyVariable],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// `art/work/<key>/raw_<n>.png`。
    public static func outputPath(key: String, index: Int) -> String {
        "\(workDirectory)/\(key)/raw_\(index).png"
    }

    /// 文件名形如 `raw_<n>.png`（n 为正整数，只含 ASCII 数字）时返回 n。
    /// 前缀与后缀都不区分大小写：macOS 默认文件系统上 `Raw_7.png` 与 `raw_7.png` 是同一个文件。
    public static func rawIndex(fileName: String) -> Int? {
        parseRawIndex(fileName)
    }

    private static func lastComponent(_ path: String) -> Substring {
        path.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring(path)
    }

    private static func isPNG(_ path: String) -> Bool {
        let name = lastComponent(path)
        return name.count > 4 && name.lowercased().hasSuffix(".png")
    }

    private static func parseRawIndex(_ path: String) -> Int? {
        let name = lastComponent(path)
        let lower = name.lowercased()
        guard lower.hasPrefix("raw_"), lower.hasSuffix(".png") else { return nil }
        let digits = name.dropFirst(4).dropLast(4)
        guard !digits.isEmpty,
              digits.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
              let value = Int(digits), value > 0 else { return nil }
        return value
    }
}

/// 模型名（R3.3）。
public enum ModelName {
    /// Model_Variable 的环境变量名。
    public static let variable = "WINDOWFOLK_IMAGE_MODEL"
    public static let fallback = "gpt-image-2.5-flare"

    /// `WINDOWFOLK_IMAGE_MODEL` 去掉首尾空白后的值；未设置或为空时用 `fallback`。
    public static func resolve(_ env: [String: String]) -> String {
        let value = env[variable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }
}
