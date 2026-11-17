import Foundation
import PropertyBased
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// `promote` 子命令的测试（任务 11.8）。
@Suite struct PromoteCommandTests {

    // Feature: 美术, Property 21: Promotion 只写通过校验的图
    /// *For any* Asset_Key、随机合规或不合规的候选图、`Assets/` 中该键是否已有文件以及其他随机文件：
    /// 候选合规时 `Assets/<key>.png` 与候选逐字节相同，原文件（若有）被逐字节复制到一个新的备份文件；
    /// 不合规时 `Assets/<key>.png` 保持原内容（原本没有则仍不存在），退出码非零并列出全部未通过规则；
    /// 两种情况下候选文件与 `Assets/` 中其他文件都不变。
    ///
    /// **Validates: Requirements 5.1, 5.2, 5.3, 5.4**
    @Test func promotionOnlyWritesValidatedImages() async {
        await propertyCheck(
            count: 100,
            input: Gen<Int>.int(in: 0...44), Gen<Bool>.bool, Gen<Bool>.bool
        ) { pick, valid, hadExisting in
            let key = AssetCatalog.all[pick].key
            do {
                let fixture = try ArtCommandFixture()
                defer { fixture.remove() }

                let candidatePath = "candidates/\(key).png"
                let candidate = valid
                    ? ArtImageFixture.compliantImage(for: key)
                    : ArtImageFixture.invalidImage(for: key)
                try fixture.writePNG(candidate, to: candidatePath)
                let candidateData = try fixture.store.read(candidatePath)

                let finalPath = "Assets/\(key).png"
                let oldData = Data("old final asset".utf8)
                if hadExisting { try fixture.store.overwrite(oldData, to: finalPath) }
                let unrelatedPath = "Assets/unrelated.png"
                let unrelatedData = Data("unrelated".utf8)
                try fixture.store.overwrite(unrelatedData, to: unrelatedPath)

                let before = fixture.files(in: "Assets")
                let status = await PromoteCommand.run([key, candidatePath],
                                                       environment: fixture.environment())

                #expect((try? fixture.store.read(candidatePath)) == candidateData, "候选文件被改动")
                #expect((try? fixture.store.read(unrelatedPath)) == unrelatedData, "其他文件被改动")

                if valid {
                    #expect(status == .success, "合规候选应写入成功")
                    #expect((try? fixture.store.read(finalPath)) == candidateData,
                            "\(finalPath) 与候选不是逐字节相同")
                    #expect(fixture.stdout.contains(key) && fixture.stdout.contains(finalPath))

                    let backups = fixture.files(in: "art/work/backups")
                    if hadExisting {
                        #expect(backups.count == 1, "覆盖时应产生一个备份，实际 \(backups)")
                        if let name = backups.first {
                            #expect((try? fixture.store.read("art/work/backups/\(name)")) == oldData,
                                    "备份与旧文件不逐字节相同")
                        }
                    } else {
                        #expect(backups.isEmpty, "原本没有文件时不应产生备份")
                    }
                    if hadExisting {
                        #expect(fixture.files(in: "Assets") == before, "覆盖时文件列表应不变")
                    } else {
                        #expect(fixture.files(in: "Assets") == (before + ["\(key).png"]).sorted(),
                                "原本没有文件时应新增一个")
                    }
                } else {
                    #expect(status == .failure, "不合规候选应失败")
                    if hadExisting {
                        #expect((try? fixture.store.read(finalPath)) == oldData, "原有文件被改动")
                    } else {
                        #expect(!fixture.store.fileExists(finalPath), "不合规时不应创建文件")
                    }
                    #expect(fixture.stderr.contains("像素尺寸"), "应列出未通过的规则")
                    #expect(fixture.files(in: "art/work/backups").isEmpty)
                }
            } catch {
                Issue.record("夹具准备失败：\(error)")
            }
        }
    }

    // MARK: - 单元测试

    @Test func unknownKeyAndMissingCandidateFailBeforeValidation() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        let candidate = "candidates/fruit.png"
        try fixture.writePNG(ArtImageFixture.compliantImage(for: "fruit"), to: candidate)

        let unknown = await PromoteCommand.run(["no_such_asset", candidate],
                                               environment: fixture.environment())
        #expect(unknown == .failure)
        #expect(fixture.stderr.contains("no_such_asset"))
        #expect(fixture.files(in: "Assets").isEmpty)

        let missing = await PromoteCommand.run(["fruit", "candidates/missing.png"],
                                               environment: fixture.environment())
        #expect(missing == .failure)
        #expect(fixture.stderr.contains("candidates/missing.png"))
        #expect(fixture.files(in: "Assets").isEmpty)
    }

    @Test func backupFailureKeepsOriginalFile() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        let key = "fruit"
        let finalPath = "Assets/\(key).png"
        let oldData = Data("old final asset".utf8)
        try fixture.store.overwrite(oldData, to: finalPath)
        let candidatePath = "candidates/fruit.png"
        try fixture.writePNG(ArtImageFixture.compliantImage(for: key), to: candidatePath)

        let environment = CommandEnvironment(
            variables: ["OPENAI_API_KEY": ArtCommandFixture.defaultAPIKey],
            fileStore: FailingFileStore(base: fixture.store, failing: .backup),
            transport: FakeTransport([]),
            standardOutput: fixture.standardOutput,
            standardError: fixture.standardError)
        let status = await PromoteCommand.run([key, candidatePath], environment: environment)

        #expect(status == .failure)
        #expect(fixture.stderr.contains("备份失败"))
        #expect((try? fixture.store.read(finalPath)) == oldData, "备份失败时不应写入")
        #expect(fixture.files(in: "Assets") == ["fruit.png"])
    }

    @Test func writeFailureKeepsOriginalFile() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        let key = "fruit"
        let finalPath = "Assets/\(key).png"
        let oldData = Data("old final asset".utf8)
        try fixture.store.overwrite(oldData, to: finalPath)
        let candidatePath = "candidates/fruit.png"
        try fixture.writePNG(ArtImageFixture.compliantImage(for: key), to: candidatePath)

        let environment = CommandEnvironment(
            variables: ["OPENAI_API_KEY": ArtCommandFixture.defaultAPIKey],
            fileStore: FailingFileStore(base: fixture.store, failing: .overwrite),
            transport: FakeTransport([]),
            standardOutput: fixture.standardOutput,
            standardError: fixture.standardError)
        let status = await PromoteCommand.run([key, candidatePath], environment: environment)

        #expect(status == .failure)
        #expect(fixture.stderr.contains("写入失败"))
        #expect((try? fixture.store.read(finalPath)) == oldData, "写入失败时原文件应保持完整")
        #expect(fixture.files(in: "Assets") == ["fruit.png"], "不应留下部分写入的文件")
    }

    @Test func invalidCandidateListsEveryFailedRule() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        let key = "fruit"
        let candidatePath = "candidates/fruit.png"
        try fixture.writePNG(ArtImageFixture.invalidImage(for: key), to: candidatePath)

        let status = await PromoteCommand.run([key, candidatePath], environment: fixture.environment())
        #expect(status == .failure)
        #expect(fixture.stderr.contains("像素尺寸"))
        #expect(!fixture.store.fileExists("Assets/\(key).png"))
    }
}
