import Foundation
import PropertyBased
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// Image_Generator 的失败隔离属性测试（任务 11.3）。夹具见 Support/CommandFixture.swift 与
/// Support/FakeTransport.swift。
@Suite struct GenerateFailureIsolationTests {

    // Feature: 美术, Property 6: 请求失败互不影响
    /// *For any* 生成计划和为每个任务随机指定的结果（成功、HTTP 错误、不可解码、超时），运行后
    /// Work_Directory 中新增的文件恰好对应成功任务、已有文件不变；退出码为 0 当且仅当全部成功；
    /// 有失败时报告恰好列出有失败的 Asset_Key，每项的成功张数等于该键成功任务数（可为 0）并附失败原因；
    /// 全部成功时每个键一行列出其新文件路径。
    ///
    /// **Validates: Requirements 3.7, 3.11, 3.13**
    @Test func requestFailuresAreIsolated() async {
        let png = PNGCodec.encode(RGBAImage(width: 1, height: 1, fill: RGBA(r: 9, g: 8, b: 7, a: 255)))
        await propertyCheck(count: 100, input: IsolationGen.scenario) { scenario in
            do {
                let fixture = try ArtCommandFixture()
                defer { fixture.remove() }
                try fixture.writeManifest()
                try fixture.writeCharacterSheets()

                // 已有一个高序号的原始图，运行后必须保持不变。
                let existingPath = "art/work/\(scenario.keys[0])/raw_9.png"
                let existingData = Data("existing candidate".utf8)
                try fixture.store.overwrite(existingData, to: existingPath)

                var outcomes: [FakeTransport.Outcome] = []
                var successIndices: [String: [Int]] = [:]
                var failureCounts: [String: Int] = [:]
                for (k, key) in scenario.keys.enumerated() {
                    // 第一个键已有 raw_9.png，新序号从 10 起；其余键从 1 起。
                    let base = key == scenario.keys[0] ? 10 : 1
                    for (t, kind) in scenario.kinds[k].enumerated() {
                        let index = base + t
                        switch kind {
                        case 0:
                            outcomes.append(.success(png))
                            successIndices[key, default: []].append(index)
                        case 1:
                            outcomes.append(.failure(.http(status: 500, message: "服务器错误")))
                            failureCounts[key, default: 0] += 1
                        case 2:
                            // 返回内容不是 PNG：失败原因为「返回内容无法解码为图像」。
                            outcomes.append(.success(Data("not a png".utf8)))
                            failureCounts[key, default: 0] += 1
                        default:
                            outcomes.append(.failure(.timeout))
                            failureCounts[key, default: 0] += 1
                        }
                    }
                }

                let transport = FakeTransport(outcomes)
                let arguments = scenario.keys + ["--count", String(scenario.count)]
                let status = await GenerateCommand.run(
                    arguments, environment: fixture.environment(transport: transport))

                #expect(transport.callCount == scenario.keys.count * scenario.count, "请求数不符")

                let allSucceeded = failureCounts.isEmpty
                #expect(status == (allSucceeded ? .success : .failure),
                        "退出码应为 \(allSucceeded ? 0 : 1)，实际 \(status)")

                for key in scenario.keys {
                    let directory = "art/work/\(key)"
                    let files = Set(fixture.files(in: directory))
                    var expected = Set((successIndices[key] ?? []).map {
                        CandidateNaming.fileName(prefix: "raw", number: $0)
                    })
                    if key == scenario.keys[0] { expected.insert("raw_9.png") }
                    #expect(files == expected, "\(key) 的文件集合 \(files) 与预期 \(expected) 不符")

                    for index in successIndices[key] ?? [] {
                        let path = "\(directory)/\(CandidateNaming.fileName(prefix: "raw", number: index))"
                        #expect((try? fixture.store.read(path)) == png, "\(path) 的内容不是返回的 PNG")
                    }
                }
                #expect((try? fixture.store.read(existingPath)) == existingData,
                        "已有文件 \(existingPath) 被改动")

                let reportLines = fixture.stdout.components(separatedBy: "\n")
                    .filter { $0.contains("成功 ") && $0.contains("失败原因：") }
                if allSucceeded {
                    #expect(reportLines.isEmpty)
                    for key in scenario.keys {
                        guard let line = reportLinesForSuccess(key: key, in: fixture.stdout) else {
                            Issue.record("\(key) 缺少成功报告行")
                            continue
                        }
                        for index in successIndices[key] ?? [] {
                            let path = "art/work/\(key)/\(CandidateNaming.fileName(prefix: "raw", number: index))"
                            #expect(line.contains(path), "\(key) 的报告行没有列出 \(path)")
                        }
                    }
                } else {
                    let reportedKeys = Set(reportLines.compactMap { line in
                        scenario.keys.first { line.hasPrefix($0 + "  ") }
                    })
                    #expect(reportedKeys == Set(failureCounts.keys), "失败报告列出的键不符")
                    for key in failureCounts.keys {
                        guard let line = reportLines.first(where: { $0.hasPrefix(key + "  ") }) else {
                            Issue.record("\(key) 缺少失败报告行")
                            continue
                        }
                        let expectedCount = (successIndices[key] ?? []).count
                        #expect(line.contains("成功 \(expectedCount) 张"), "\(key) 的成功张数不符：\(line)")
                    }
                }
            } catch {
                Issue.record("夹具准备失败：\(error)")
            }
        }
    }

    private func reportLinesForSuccess(key: String, in output: String) -> String? {
        output.components(separatedBy: "\n").first { $0.hasPrefix(key + "  ") }
    }
}

// MARK: - 生成器

private struct IsolationScenario: Sendable, CustomStringConvertible {
    var keys: [String]
    var count: Int
    /// 每个键 `count` 个结果：0 成功、1 HTTP 错误、2 不可解码、3 超时。
    var kinds: [[Int]]

    var description: String { "\(keys) count=\(count) kinds=\(kinds)" }
}

private enum IsolationGen {
    static var scenario: Generator<IsolationScenario, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...44).array(of: 1...3),
            Gen<Int>.int(in: 1...3),
            Gen<Int>.int(in: 0...3).array(of: 9)
        ).map { picks, count, entropy -> IsolationScenario in
            var seen = Set<String>()
            var keys: [String] = []
            for pick in picks {
                let key = AssetCatalog.all[pick % AssetCatalog.all.count].key
                if seen.insert(key).inserted { keys.append(key) }
            }
            let kinds = keys.enumerated().map { index, _ in
                Array(entropy[(index * count)..<(index * count + count)])
            }
            return IsolationScenario(keys: keys, count: count, kinds: kinds)
        }
    }
}
