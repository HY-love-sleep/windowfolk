import Foundation
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// `preview` 子命令的单元测试（任务 11.12）。
@Suite struct PreviewCommandTests {

    @Test func missingDirectoryWritesNoPreview() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }

        let status = await PreviewCommand.run(["no-such-directory"], environment: fixture.environment())

        #expect(status == .failure)
        #expect(fixture.stderr.contains("no-such-directory"))
        #expect(fixture.files(in: PreviewCommand.outputDirectory).isEmpty)
    }

    @Test func writesTwoThemedPreviewsAndSummarizes() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writePNG(ArtImageFixture.compliantImage(for: "fruit"), to: "Assets/fruit.png")
        try fixture.writePNG(ArtImageFixture.invalidImage(for: "bubble_heart"), to: "Assets/bubble_heart.png")
        try fixture.store.overwrite(Data("not a png".utf8), to: "Assets/extra.png")

        let assetsBefore = try snapshot("Assets", fixture: fixture)
        let status = await PreviewCommand.run([], environment: fixture.environment())
        let assetsAfter = try snapshot("Assets", fixture: fixture)

        #expect(status == .success)
        #expect(assetsAfter == assetsBefore, "被检查目录的内容不应改变（R7.1）")

        let names = fixture.files(in: PreviewCommand.outputDirectory)
        #expect(names == [PreviewTheme.dark.fileName, PreviewTheme.light.fileName].sorted())

        // 背景为单一纯色（R7.2）。
        for theme in PreviewTheme.allCases {
            let path = "\(PreviewCommand.outputDirectory)/\(theme.fileName)"
            let decoded = try #require(PNGCodec.decode(try fixture.store.read(path)))
            let expected = theme.background
            for (x, y) in [(2, 2), (decoded.image.width - 3, 2), (2, decoded.image.height - 3)] {
                let pixel = decoded.image[x, y]
                #expect(pixel == expected, "\(theme) 背景点 (\(x), \(y)) 为 \(pixel)，应为 \(expected)")
            }
            if theme == .dark {
                #expect(expected.r <= 48 && expected.g <= 48 && expected.b <= 48)
            } else {
                #expect(expected.r >= 208 && expected.g >= 208 && expected.b >= 208)
            }
        }

        // 缺失项在两张图上都有等大的标记区域（R7.4）。
        let verdicts: [String: AssetVerdict] = [
            "fruit": .pass,
            "bubble_heart": .fail([.pixelSize], emptyFrames: []),
        ]
        let layout = PreviewLayout.make(verdicts: verdicts)
        let row = try #require(layout.rows.first { $0.key == "resident_a_idle" })
        let marker = try #require(row.marker)
        #expect(marker.kind == .missing)
        #expect(marker.text == "缺失")
        #expect(marker.rect.width == AssetCatalog.spec("resident_a_idle")!.expectedPixelWidth)
        #expect(marker.rect.height == AssetCatalog.spec("resident_a_idle")!.expectedPixelHeight)

        for theme in PreviewTheme.allCases {
            let path = "\(PreviewCommand.outputDirectory)/\(theme.fileName)"
            let decoded = try #require(PNGCodec.decode(try fixture.store.read(path)))
            let corner = decoded.image[marker.rect.maxX - 1, marker.rect.maxY - 1]
            #expect(corner == theme.markerFill, "\(theme) 的缺失标记区域没有被填充")
        }

        // 汇总输出（R7.6）。
        #expect(fixture.stdout.contains("\(PreviewCommand.outputDirectory)/\(PreviewTheme.dark.fileName)"))
        #expect(fixture.stdout.contains("\(PreviewCommand.outputDirectory)/\(PreviewTheme.light.fileName)"))
        #expect(fixture.stdout.contains("正常显示 1 项：fruit"))
        #expect(fixture.stdout.contains("不合规 1 项：bubble_heart"))
        #expect(fixture.stdout.contains("缺失 43 项："))
    }

    @Test func overwritesExistingPreviews() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        for theme in PreviewTheme.allCases {
            try fixture.store.overwrite(Data("old".utf8),
                                        to: "\(PreviewCommand.outputDirectory)/\(theme.fileName)")
        }
        try fixture.writePNG(ArtImageFixture.compliantImage(for: "fruit"), to: "Assets/fruit.png")

        let status = await PreviewCommand.run([], environment: fixture.environment())
        #expect(status == .success)
        for theme in PreviewTheme.allCases {
            let data = try fixture.store.read("\(PreviewCommand.outputDirectory)/\(theme.fileName)")
            #expect(data != Data("old".utf8), "旧的总览图应被覆盖")
            #expect(PNGCodec.decode(data) != nil)
        }
    }

    private func snapshot(_ directory: String, fixture: ArtCommandFixture) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in fixture.files(in: directory) {
            result[name] = try fixture.store.read("\(directory)/\(name)")
        }
        return result
    }
}
