import Foundation
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// `generate` 子命令的单元测试（任务 11.4）。不发网络、不需要真实 Key。
@Suite struct GenerateCommandTests {

    // MARK: - 预检

    @Test func missingOrBlankAPIKeySendsNoRequest() async throws {
        for variables in [[String: String](), ["OPENAI_API_KEY": "   \t\n"]] {
            let fixture = try ArtCommandFixture()
            defer { fixture.remove() }
            try fixture.writeManifest()
            try fixture.writeCharacterSheets()

            let transport = FakeTransport([])
            let status = await GenerateCommand.run(
                ["fruit", "--count", "1"],
                environment: fixture.environment(transport: transport, variables: variables))

            #expect(transport.callCount == 0, "没有可用的 Key 时不应发出请求")
            #expect(status != .success)
            #expect(fixture.stderr.contains("OPENAI_API_KEY"), "应提示设置 OPENAI_API_KEY")
        }
    }

    @Test func unknownKeySendsNoRequest() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()
        try fixture.writeCharacterSheets()

        let transport = FakeTransport([])
        let status = await GenerateCommand.run(
            ["no_such_asset", "--count", "2"],
            environment: fixture.environment(transport: transport))

        #expect(transport.callCount == 0)
        #expect(status == .failure)
        #expect(fixture.stderr.contains("no_such_asset"))
    }

    @Test func missingReferenceSendsNoRequest() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        // 只写清单，不写两张设定图。
        try fixture.writeManifest()

        let transport = FakeTransport([])
        let status = await GenerateCommand.run(
            ["resident_a_idle", "--count", "1"],
            environment: fixture.environment(transport: transport))

        #expect(transport.callCount == 0)
        #expect(status == .failure)
        #expect(fixture.stderr.contains(ManifestParser.characterSheetPath(.a)))
    }

    @Test func invalidCountIsUsageError() async throws {
        for value in ["0", "9", "abc", "-1"] {
            let fixture = try ArtCommandFixture()
            defer { fixture.remove() }
            try fixture.writeManifest()

            let transport = FakeTransport([])
            let status = await GenerateCommand.run(
                ["fruit", "--count", value],
                environment: fixture.environment(transport: transport))

            #expect(transport.callCount == 0, "--count \(value)")
            #expect(status == .usage, "--count \(value)")
        }
    }

    // MARK: - 试运行

    @Test func dryRunPrintsEveryRequestAndWritesNothing() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()
        try fixture.writeCharacterSheets()

        let transport = FakeTransport([])
        let status = await GenerateCommand.run(
            ["fruit", "bubble_heart", "--count", "2", "--dry-run"],
            environment: fixture.environment(transport: transport))

        #expect(status == .success)
        #expect(transport.callCount == 0)
        #expect(fixture.files(in: "art/work").isEmpty, "试运行不应写文件")

        for key in ["fruit", "bubble_heart"] {
            for index in 1...2 {
                #expect(fixture.stdout.contains("\(key) #\(index)"), "缺少 \(key) #\(index)")
            }
            #expect(fixture.stdout.contains("Asset_Key：\(key)"))
            #expect(fixture.stdout.contains("art/work/\(key)/raw_1.png"))
        }
        #expect(fixture.stdout.contains("模型：\(ModelName.fallback)"))
        #expect(fixture.stdout.contains("画布：1024x1024"))
        #expect(fixture.stdout.contains("参考图：无"))
    }

    @Test func dryRunDoesNotRequireAPIKey() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()
        try fixture.writeCharacterSheets()

        let transport = FakeTransport([])
        let status = await GenerateCommand.run(
            ["fruit", "--count", "1", "--dry-run"],
            environment: fixture.environment(transport: transport, variables: [:]))

        #expect(status == .success)
        #expect(transport.callCount == 0)
    }

    // MARK: - 进度与报告

    @Test func progressLinesAndSuccessReport() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()
        try fixture.writeCharacterSheets()

        let png = PNGCodec.encode(RGBAImage(width: 1, height: 1, fill: RGBA(r: 4, g: 5, b: 6, a: 255)))
        let transport = FakeTransport([.success(png), .success(png)])
        let status = await GenerateCommand.run(
            ["fruit", "--count", "2"],
            environment: fixture.environment(transport: transport))

        #expect(status == .success)
        #expect(transport.callCount == 2)
        #expect(fixture.stdout.contains("[1/2] 发送 fruit #1"))
        #expect(fixture.stdout.contains("[1/2] 完成 fruit #1"))
        #expect(fixture.stdout.contains("[2/2] 发送 fruit #2"))
        #expect(fixture.stdout.contains("[2/2] 完成 fruit #2"))
        #expect(fixture.stdout.contains("art/work/fruit/raw_1.png  art/work/fruit/raw_2.png"))
        #expect(fixture.files(in: "art/work/fruit") == ["raw_1.png", "raw_2.png"])
    }

    @Test func noPendingAssetsPrintsMessageAndSucceeds() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()
        try fixture.writeCharacterSheets()
        let png = PNGCodec.encode(RGBAImage(width: 1, height: 1, fill: RGBA(r: 1, g: 1, b: 1, a: 255)))
        for spec in AssetCatalog.all {
            try fixture.store.overwrite(png, to: "art/work/\(spec.key)/raw_1.png")
        }

        let transport = FakeTransport([])
        let status = await GenerateCommand.run([], environment: fixture.environment(transport: transport))

        #expect(status == .success)
        #expect(transport.callCount == 0)
        #expect(fixture.stdout.contains(GenerateCommand.noPendingMessage))
    }

    @Test func modelUnavailableStopsRemainingRequests() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()
        try fixture.writeCharacterSheets()

        let transport = FakeTransport([.failure(.modelUnavailable("gpt-image-2.5-flare"))])
        let status = await GenerateCommand.run(
            ["fruit", "--count", "3"],
            environment: fixture.environment(transport: transport))

        #expect(status == .failure)
        #expect(transport.callCount == 1, "模型不可用后不再发送剩余请求")
        #expect(fixture.stdout.contains("gpt-image-2.5-flare"))
        #expect(fixture.stdout.contains(ModelName.variable), "应提示可用 WINDOWFOLK_IMAGE_MODEL 指定其他模型")
        #expect(fixture.stdout.contains("fruit  成功 0 张  失败原因："))
        #expect(fixture.files(in: "art/work/fruit").isEmpty)
    }

    // MARK: - 脱敏（Property 7 的端到端部分）

    // Feature: 美术, Property 7: Key 不泄露
    @Test func endToEndOutputNeverLeaksAPIKey() async throws {
        let key = "sk-live-A1B2C3D4E5F6G7H8"
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()
        try fixture.writeCharacterSheets()

        // 服务器错误信息回显完整 Key、开头片段与掩码形式。
        let echoed = "invalid key \(key), fragment \(key.prefix(10)), masked \(key.prefix(6))***\(key.suffix(4))"
        let transport = FakeTransport([.failure(.http(status: 400, message: echoed))])
        let status = await GenerateCommand.run(
            ["fruit", "--count", "1"],
            environment: fixture.environment(transport: transport, variables: ["OPENAI_API_KEY": key]))

        #expect(status == .failure)

        var haystacks = [fixture.stdout, fixture.stderr]
        for name in fixture.files(in: "art/work/fruit") {
            if let data = try? fixture.store.read("art/work/fruit/\(name)"),
               let text = String(data: data, encoding: .utf8) {
                haystacks.append(text)
            }
        }
        for text in haystacks {
            for length in 6...min(12, key.count) {
                for start in 0...(key.count - length) {
                    let fragment = String(Array(key)[start..<(start + length)])
                    #expect(!text.contains(fragment), "输出泄露了 Key 片段 \(fragment)")
                }
            }
        }
    }
}
