import Foundation
import PropertyBased
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// GenerationPlanner 的属性测试与示例（任务 5.2）。清单生成器见 Support/ManifestGen.swift。
@Suite struct GenerationPlannerTests {

    // Feature: 美术, Property 4: 生成计划只补缺且序号不冲突
    /// *For any* 清单、请求键列表（可为空）、`count ∈ 1...8` 和每个键已有的 PNG 文件名集合：
    /// 请求键非空时，计划为每个请求键恰好 `count` 个任务；为空时，只为没有 PNG 的键各安排 `count` 个任务，
    /// 全部已有时计划为空；每个任务的输出文件名不与已有文件重名，同一键的新序号从已有最大序号加 1 起连续递增。
    ///
    /// 重名按不区分大小写比较：macOS 默认文件系统上 `Raw_7.png` 与 `raw_7.png` 是同一个文件。
    ///
    /// **Validates: Requirements 3.1, 3.2, 3.5**
    @Test func planFillsGapsWithoutIndexCollisions() async {
        await propertyCheck(
            count: 100,
            input: Gen.manifest, PlanGen.requested, Gen<Int>.int(in: GenerationPlanner.countRange), PlanGen.existing
        ) { manifest, requested, count, existing in
            let existingPNGs = existing.mapValues { $0.map(\.name) }
            guard case .success(let jobs) = GenerationPlanner.plan(
                manifest: manifest, requested: requested, count: count, existingPNGs: existingPNGs
            ) else {
                Issue.record("合法输入返回了错误：requested=\(requested) count=\(count)")
                return
            }

            // 预期的键顺序：请求非空时按首次出现去重；为空时按清单顺序取没有 PNG 的键。
            let expectedKeys: [String]
            if requested.isEmpty {
                expectedKeys = manifest.entries.map(\.key).filter { key in
                    !(existing[key] ?? []).contains(where: \.isPNG)
                }
            } else {
                var seen = Set<String>()
                expectedKeys = requested.filter { seen.insert($0).inserted }
            }

            // 每个键恰好 count 个任务，按键顺序连续排列；全部已有 PNG 时计划为空。
            let expectedKeySequence = expectedKeys.flatMap { Array(repeating: $0, count: count) }
            #expect(jobs.map(\.key) == expectedKeySequence,
                    "任务键序列不符：requested=\(requested) count=\(count)")

            // 输出路径互不相同。
            #expect(Set(jobs.map { $0.outputPath.lowercased() }).count == jobs.count, "计划内输出路径重复")

            for key in expectedKeys {
                let files = existing[key] ?? []
                let start = (files.compactMap(\.index).max() ?? 0) + 1
                let keyJobs = jobs.filter { $0.key == key }
                #expect(keyJobs.map(\.candidateIndex) == Array(start..<(start + count)),
                        "\(key)：序号 \(keyJobs.map(\.candidateIndex)) 不从 \(start) 起连续")

                let taken = Set(files.map { lastComponent($0.name).lowercased() })
                for job in keyJobs {
                    #expect(job.outputPath == "art/work/\(key)/raw_\(job.candidateIndex).png",
                            "\(key)：输出路径 \(job.outputPath) 与序号不符")
                    let name = lastComponent(job.outputPath).lowercased()
                    #expect(!taken.contains(name),
                            "\(key)：新文件 \(job.outputPath) 与已有文件重名，已有 \(files.map(\.name))")
                }
            }
        }
    }

    /// 已有文件中混有无关文件和非规范序号时，只按合法的 `raw_<n>.png` 取最大序号。
    @Test func startsAfterHighestRawIndex() throws {
        let manifest = try #require(Self.sampleManifest())
        let key = try #require(manifest.entries.first?.key)
        let result = GenerationPlanner.plan(
            manifest: manifest, requested: [key, key], count: 2,
            existingPNGs: [key: ["raw_2.png", "raw_10.png", "notes.txt", "processed_40.png", "raw_x.png"]]
        )
        let jobs = try result.get()
        #expect(jobs.map(\.candidateIndex) == [11, 12])
        #expect(jobs.map(\.outputPath) == ["art/work/\(key)/raw_11.png", "art/work/\(key)/raw_12.png"])
    }

    /// 未指定键且每个键都已有 PNG 时计划为空。
    @Test func emptyPlanWhenEveryKeyHasPNG() throws {
        let manifest = try #require(Self.sampleManifest())
        let existing = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.key, ["raw_1.png"]) })
        let jobs = try GenerationPlanner.plan(manifest: manifest, requested: [], count: 3, existingPNGs: existing).get()
        #expect(jobs.isEmpty)
    }

    /// 回归：`raw_` 前缀大小写不同的文件也计入最大序号，避免在不区分大小写的文件系统上撞名。
    @Test func rawPrefixIsCaseInsensitive() throws {
        #expect(GenerationPlanner.rawIndex(fileName: "Raw_7.png") == 7)
        #expect(GenerationPlanner.rawIndex(fileName: "RAW_3.PNG") == 3)

        let manifest = try #require(Self.sampleManifest())
        let key = try #require(manifest.entries.first?.key)
        let jobs = try GenerationPlanner.plan(
            manifest: manifest, requested: [key], count: 1, existingPNGs: [key: ["Raw_7.png", "raw_2.png"]]
        ).get()
        #expect(jobs.map(\.outputPath) == ["art/work/\(key)/raw_8.png"])
        let upper = try GenerationPlanner.plan(
            manifest: manifest, requested: [key], count: 1, existingPNGs: [key: ["RAW_3.PNG", "raw_1.png"]]
        ).get()
        #expect(upper.map(\.candidateIndex) == [4])
    }

    /// 回归：`CandidateNaming` 的 `raw_`/`processed_` 序号解析同样不区分大小写。
    @Test func candidateNamingIsCaseInsensitive() {
        let names = ["Raw_7.png", "RAW_3.PNG", "raw_1.png", "Processed_5.png", "PROCESSED_9.PNG", "raw_.png", "raw_x.png"]
        #expect(CandidateNaming.numbers(in: names, prefix: "raw") == [1, 3, 7])
        #expect(CandidateNaming.numbers(in: names, prefix: "processed") == [5, 9])
    }

    /// 取一份固定的合法清单（目录中每个键一条）。
    private static func sampleManifest() -> PromptManifest? {
        let entries = AssetCatalog.all.map { spec in
            PromptEntry(
                key: spec.key, description: "x", frames: spec.frames, layout: .horizontalNoGap,
                canvas: PixelSize(width: 64, height: 64),
                references: AssetRules.rules(for: spec.key)?.owner.map { [ManifestParser.characterSheetPath($0)] } ?? []
            )
        }
        return PromptManifest(prefix: "p", palettes: [:], entries: entries)
    }
}

/// 路径最后一段。
fileprivate func lastComponent(_ path: String) -> String {
    String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring(path))
}

/// 子目录中的一个已有文件：文件名、是否算 PNG、作为 Raw_Candidate 的序号（不是合法 `raw_<n>.png` 时为 nil）。
fileprivate struct ExistingFile: Sendable, CustomStringConvertible {
    var name: String
    var isPNG: Bool
    var index: Int?
    var description: String { name }
}

fileprivate enum PlanGen {
    /// 已有文件池，序号与 PNG 判定是独立写出的预期值。
    static let pool: [ExistingFile] = [
        ExistingFile(name: "raw_1.png", isPNG: true, index: 1),
        ExistingFile(name: "raw_2.png", isPNG: true, index: 2),
        ExistingFile(name: "raw_3.png", isPNG: true, index: 3),
        ExistingFile(name: "raw_9.png", isPNG: true, index: 9),
        ExistingFile(name: "raw_10.png", isPNG: true, index: 10),
        ExistingFile(name: "raw_04.png", isPNG: true, index: 4),
        ExistingFile(name: "raw_5.PNG", isPNG: true, index: 5),
        ExistingFile(name: "art/work/x/raw_6.png", isPNG: true, index: 6),
        ExistingFile(name: "Raw_7.png", isPNG: true, index: 7),
        ExistingFile(name: "RAW_3.PNG", isPNG: true, index: 3),
        ExistingFile(name: "raw_0.png", isPNG: true, index: nil),
        ExistingFile(name: "raw_.png", isPNG: true, index: nil),
        ExistingFile(name: "raw_x.png", isPNG: true, index: nil),
        ExistingFile(name: "raw_-3.png", isPNG: true, index: nil),
        ExistingFile(name: "raw_٣.png", isPNG: true, index: nil),
        ExistingFile(name: "processed_12.png", isPNG: true, index: nil),
        ExistingFile(name: "raw_8.txt", isPNG: false, index: nil),
        ExistingFile(name: "raw_11.png.bak", isPNG: false, index: nil),
        ExistingFile(name: "notes.txt", isPNG: false, index: nil),
        ExistingFile(name: ".DS_Store", isPNG: false, index: nil),
    ]

    static let keys = AssetCatalog.all.map(\.key)

    /// 约 1/3 为空；其余为 1 到 6 个目录键，可能重复。
    static var requested: Generator<[String], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...2),
            Gen<String?>.element(of: keys).map { $0! }.array(of: 1...6)
        ).map { mode, keys in mode == 0 ? [] : keys }
    }

    /// 每个目录键 0 到 4 个已有文件。约 1/4 的样本让每个键都至少有一张 PNG（覆盖“全部已有时计划为空”）。
    /// 空列表的键一半保留空数组、一半缺省，两者都表示没有文件。
    static var existing: Generator<[String: [ExistingFile]], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...3),
            Gen<Int>.int(in: 0..<pool.count).array(of: 0...4).array(of: keys.count)
        ).map { mode, picks -> [String: [ExistingFile]] in
            var result: [String: [ExistingFile]] = [:]
            for (i, key) in keys.enumerated() {
                var files = picks[i].map { pool[$0] }
                if mode == 0, !files.contains(where: \.isPNG) {
                    files.append(pool[0])
                }
                if files.isEmpty, i.isMultiple(of: 2) { continue }
                result[key] = files
            }
            return result
        }
    }
}
