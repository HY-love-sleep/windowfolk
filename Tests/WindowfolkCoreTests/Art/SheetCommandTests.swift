import Foundation
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// `sheet generate` / `sheet compose` 的单元测试（任务 11.14）。
@Suite struct SheetCommandTests {

    // MARK: - sheet generate

    @Test func generateDryRunWritesNothingAndSendsNothing() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()

        let transport = FakeTransport([])
        let status = await SheetCommand.generate(
            ["resident_a", "--count", "2", "--dry-run"],
            environment: fixture.environment(transport: transport, variables: [:]))

        #expect(status == .success)
        #expect(transport.callCount == 0)
        #expect(fixture.files(in: "\(SheetCommand.workDirectory)/resident_a").isEmpty)
        #expect(fixture.stdout.contains("resident_a #1"))
        #expect(fixture.stdout.contains("resident_a #2"))
        #expect(fixture.stdout.contains("画布：\(CharacterSheetPrompts.requestCanvas.canvasString)"))
        #expect(fixture.stdout.contains("参考图：无"))
        #expect(fixture.stdout.contains("Character turnaround sheet"))
        #expect(fixture.stdout.contains("art/work/sheets/resident_a/raw_1.png"))
    }

    @Test func generateWithoutAPIKeySendsNothing() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()

        let transport = FakeTransport([])
        let status = await SheetCommand.generate(
            ["resident_b", "--count", "1"],
            environment: fixture.environment(transport: transport, variables: [:]))

        #expect(status == .failure)
        #expect(transport.callCount == 0)
        #expect(fixture.stderr.contains("OPENAI_API_KEY"))
    }

    @Test func generateWritesRawCandidateWithSequence() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()
        try fixture.store.overwrite(Data("old".utf8), to: "\(SheetCommand.workDirectory)/resident_a/raw_3.png")

        let png = PNGCodec.encode(RGBAImage(width: 1, height: 1, fill: RGBA(r: 1, g: 1, b: 1, a: 255)))
        let transport = FakeTransport([.success(png), .success(png)])
        let status = await SheetCommand.generate(
            ["resident_a", "--count", "2"],
            environment: fixture.environment(transport: transport))

        #expect(status == .success)
        #expect(transport.callCount == 2)
        #expect(fixture.files(in: "\(SheetCommand.workDirectory)/resident_a")
            == ["raw_3.png", "raw_4.png", "raw_5.png"])
    }

    @Test func unknownResidentIsUsageError() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()
        let status = await SheetCommand.generate(["resident_c"], environment: fixture.environment())
        #expect(status == .usage)
    }

    // MARK: - sheet compose

    @Test func composeWritesSwatchesAndViews() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()

        let rawPath = "art/work/sheets/resident_a/raw_1.png"
        try fixture.writePNG(threeViewImage(), to: rawPath)

        let status = await SheetCommand.compose(["resident_a", rawPath], environment: fixture.environment())
        #expect(status == .success)

        let path = CharacterSheetPrompts.sheetPath(for: .a)
        #expect(fixture.stdout.contains(path))
        let decoded = try #require(PNGCodec.decode(try fixture.store.read(path)))
        #expect(decoded.image.width == SheetLayout.canvas.width)
        #expect(decoded.image.height == SheetLayout.canvas.height)

        let expectedColors = try #require(SheetLayout.swatchColors(ArtCommandFixture.palettes[.residentA]!))
        for (index, color) in expectedColors.enumerated() {
            let rect = SheetLayout.swatchRect(index)
            let center = decoded.image[rect.x + rect.width / 2, rect.y + rect.height / 2]
            #expect(center == RGBA(r: color.r, g: color.g, b: color.b, a: 255),
                    "第 \(index) 个色块中心应为 \(color.hex)，实际 \(center)")
        }

        for index in 0..<SheetLayout.viewCount {
            let cell = SheetLayout.viewCellRect(index)
            let bounds = try #require(decoded.image.opaqueBounds(in: cell), "第 \(index) 个视图格为空")
            #expect(bounds.height >= SheetLayout.viewMinHeight,
                    "第 \(index) 个视图高度 \(bounds.height) 小于 \(SheetLayout.viewMinHeight)")
        }
    }

    @Test func composeWithoutManifestFails() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        let rawPath = "art/work/sheets/resident_a/raw_1.png"
        try fixture.writePNG(threeViewImage(), to: rawPath)

        let status = await SheetCommand.compose(["resident_a", rawPath], environment: fixture.environment())
        #expect(status == .failure)
        #expect(fixture.stderr.contains(GenerateCommand.manifestPath))
        #expect(!fixture.store.fileExists(CharacterSheetPrompts.sheetPath(for: .a)))
    }

    @Test func composeWithMissingOrUnreadableRawFails() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writeManifest()

        let missing = await SheetCommand.compose(["resident_a", "art/work/sheets/resident_a/raw_404.png"],
                                                 environment: fixture.environment())
        #expect(missing == .failure)
        #expect(fixture.stderr.contains("raw_404.png"))

        try fixture.store.overwrite(Data("not a png".utf8), to: "art/work/sheets/resident_a/raw_2.png")
        let undecodable = await SheetCommand.compose(["resident_a", "art/work/sheets/resident_a/raw_2.png"],
                                                     environment: fixture.environment())
        #expect(undecodable == .failure)
        #expect(!fixture.store.fileExists(CharacterSheetPrompts.sheetPath(for: .a)))
    }

    // MARK: - 辅助

    /// 三个等宽视图的长条图：每格中央一块 220×500 的不透明矩形。
    private func threeViewImage() -> RGBAImage {
        let cellWidth = 600, height = 700
        var image = RGBAImage(width: cellWidth * 3, height: height)
        for index in 0..<3 {
            let x0 = index * cellWidth + 190
            let color = RGBA(r: UInt8(80 + index * 60), g: 120, b: 160, a: 255)
            for y in 100..<600 {
                for x in x0..<(x0 + 220) {
                    image[x, y] = color
                }
            }
        }
        return image
    }
}
