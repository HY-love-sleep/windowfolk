import Foundation
import PropertyBased
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// `process` 子命令的测试（任务 11.6）。
@Suite struct ProcessCommandEmptyFrameTests {

    // Feature: 美术, Property 17: 空帧报错且不写文件
    /// *For any* Asset_Key 和清空了随机一帧的合成原始图，`process` 返回 `emptyFrame`，序号等于被清空帧
    /// （从 1 开始）；`process` 子命令以非零退出码结束，Work_Directory 的文件列表与内容不变。
    ///
    /// **Validates: Requirements 4.12**
    @Test func emptyFrameFailsWithoutWritingFiles() async {
        await propertyCheck(
            count: 100,
            input: Gen<RawImageSample>.rawImage(among: AssetCatalog.all.map(\.key)),
            Gen<Int>.int(in: 0...11)
        ) { sample, pick in
            let clearedFrame = pick % sample.frames
            let cleared = sample.clearingFrame(clearedFrame)

            switch PostProcessor.process(cleared, key: sample.key, resampler: NearestResampler()) {
            case .failure(.emptyFrame(let index)):
                #expect(index == clearedFrame + 1, "\(sample) 空帧序号应为 \(clearedFrame + 1)，实际 \(index)")
            case .failure(let error):
                Issue.record("\(sample) 应报空帧，实际 \(error)")
            case .success:
                Issue.record("\(sample) 清空第 \(clearedFrame + 1) 帧后仍处理成功")
            }

            do {
                let fixture = try ArtCommandFixture()
                defer { fixture.remove() }
                let directory = "art/work/\(sample.key)"
                // 预置一个已有文件，确认失败时不被改动。
                try fixture.writePNG(RGBAImage(width: 1, height: 1), to: "\(directory)/processed_7.png")
                let rawPath = "\(directory)/raw_1.png"
                try fixture.writePNG(cleared, to: rawPath)
                let before = fixture.files(in: directory)

                let status = await ProcessCommand.run([sample.key, rawPath], environment: fixture.environment())
                #expect(status != .success, "\(sample) 空帧应失败")
                #expect(fixture.files(in: directory) == before, "\(sample) 失败时不应写文件")
                #expect(fixture.stderr.contains(sample.key), "错误信息应包含 Asset_Key")
                #expect(fixture.stderr.contains("第 \(clearedFrame + 1) 帧"), "错误信息应包含帧序号")
            } catch {
                Issue.record("夹具准备失败：\(error)")
            }
        }
    }

    // MARK: - 成功路径

    @Test func processWritesProcessedCandidateAndPrintsPath() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }

        let sample = RawImageSample.build(keys: ["fruit"], entropy: Array(repeating: 0, count: RawImageSample.entropyCount))
        let rawPath = "art/work/fruit/raw_1.png"
        try fixture.writePNG(sample.image, to: rawPath)

        let status = await ProcessCommand.run(["fruit", rawPath], environment: fixture.environment())
        #expect(status == .success)
        #expect(fixture.stdout.contains("art/work/fruit/processed_1.png"))
        #expect(fixture.files(in: "art/work/fruit") == ["processed_1.png", "raw_1.png"])

        let produced = try #require(PNGCodec.decode(try fixture.store.read("art/work/fruit/processed_1.png")))
        #expect(produced.image.width == AssetCatalog.spec("fruit")!.expectedPixelWidth)
        #expect(produced.image.height == AssetCatalog.spec("fruit")!.expectedPixelHeight)
        #expect(AssetValidator.validate(key: "fruit", decoded: produced) == .pass)

        // 再处理一次时序号递增，不覆盖已有文件。
        let status2 = await ProcessCommand.run(["fruit", rawPath], environment: fixture.environment())
        #expect(status2 == .success)
        #expect(fixture.files(in: "art/work/fruit") == ["processed_1.png", "processed_2.png", "raw_1.png"])
    }

    @Test func unknownKeyAndUnreadableRawFileFail() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }

        let sample = RawImageSample.build(keys: ["fruit"], entropy: Array(repeating: 0, count: RawImageSample.entropyCount))
        try fixture.writePNG(sample.image, to: "art/work/fruit/raw_1.png")

        let unknown = await ProcessCommand.run(["no_such_asset", "art/work/fruit/raw_1.png"],
                                               environment: fixture.environment())
        #expect(unknown == .failure)
        #expect(fixture.stderr.contains("no_such_asset"))

        let missing = await ProcessCommand.run(["fruit", "art/work/fruit/raw_404.png"],
                                               environment: fixture.environment())
        #expect(missing == .failure)
        #expect(fixture.stderr.contains("art/work/fruit/raw_404.png"))
    }

    @Test func wrongArgumentCountIsUsageError() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        let status = await ProcessCommand.run(["fruit"], environment: fixture.environment())
        #expect(status == .usage)
    }

    // MARK: - idle 参考高度

    @Test func idleReferenceHeightComesFromFinalAssetFirstFrame() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }

        let idle = ArtImageFixture.compliantImage(for: "resident_a_idle")
        try fixture.writePNG(idle, to: "Assets/resident_a_idle.png")

        let expected = idle.opaqueBounds(
            in: FrameSlicer.frameRects(width: idle.width, height: idle.height, frames: 4)[0])?.height
        #expect(ProcessCommand.idleReferenceHeight(for: "resident_a_walking", store: fixture.store) == expected)
        #expect(ProcessCommand.idleReferenceHeight(for: "resident_b_walking", store: fixture.store) == nil)
        #expect(ProcessCommand.idleReferenceHeight(for: "fruit", store: fixture.store) == nil)
    }
}
