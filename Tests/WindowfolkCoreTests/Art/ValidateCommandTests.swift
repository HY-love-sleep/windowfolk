import Foundation
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// `validate` 子命令的单元测试（任务 11.10）。
@Suite struct ValidateCommandTests {

    @Test func missingDirectoryPrintsNothingPerKey() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }

        let status = await ValidateCommand.run(["no-such-directory"], environment: fixture.environment())

        #expect(status == .failure)
        #expect(fixture.stderr.contains("no-such-directory"))
        #expect(fixture.stdout.isEmpty || !fixture.stdout.contains("通过"))
        for spec in AssetCatalog.all {
            #expect(!fixture.stdout.contains(spec.key), "不应输出 \(spec.key) 的结果")
        }
    }

    @Test func reportsEveryKeyAndUnknownFiles() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writePNG(ArtImageFixture.compliantImage(for: "fruit"), to: "Assets/fruit.png")
        try fixture.writePNG(ArtImageFixture.compliantImage(for: "plank"), to: "Assets/plank.png")
        try fixture.writePNG(ArtImageFixture.invalidImage(for: "bubble_heart"), to: "Assets/bubble_heart.png")
        try fixture.store.overwrite(Data("not a png".utf8), to: "Assets/extra.png")

        let status = await ValidateCommand.run([], environment: fixture.environment())

        #expect(status == .failure)
        #expect(fixture.stdout.contains("fruit  通过"))
        #expect(fixture.stdout.contains("plank  通过"))
        #expect(fixture.stdout.contains("bubble_heart  未通过：像素尺寸"))
        #expect(fixture.stdout.contains("extra.png  未知文件"))

        let keyLines = fixture.stdout.components(separatedBy: "\n").filter { line in
            AssetCatalog.all.contains { line.hasPrefix($0.key + "  ") }
        }
        #expect(keyLines.count == AssetCatalog.all.count, "应恰好 45 行，实际 \(keyLines.count)")

        // 未知文件排在 45 行之后。
        let lines = fixture.stdout.components(separatedBy: "\n")
        let lastKeyLine = lines.lastIndex { line in
            AssetCatalog.all.contains { line.hasPrefix($0.key + "  ") }
        }
        let unknownLine = lines.firstIndex { $0.hasPrefix("extra.png  ") }
        if let lastKeyLine, let unknownLine {
            #expect(unknownLine > lastKeyLine)
        } else {
            Issue.record("缺少结果行或未知文件行")
        }
    }

    @Test func allValidAssetsExitZero() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        for spec in AssetCatalog.all {
            try fixture.writePNG(ArtImageFixture.compliantImage(for: spec.key), to: "Assets/\(spec.fileName)")
        }

        let status = await ValidateCommand.run([], environment: fixture.environment())

        #expect(status == .success)
        #expect(fixture.stdout.contains("resident_a_idle  通过"))
        #expect(fixture.stdout.contains("toolbox  通过"))
        #expect(!fixture.stdout.contains("未通过"))
        #expect(!fixture.stdout.contains(ValidationReport.unknownFileLabel))
    }

    @Test func explicitDirectoryIsUsed() async throws {
        let fixture = try ArtCommandFixture()
        defer { fixture.remove() }
        try fixture.writePNG(ArtImageFixture.compliantImage(for: "fruit"), to: "art/work/fruit/processed_1.png")

        let missing = await ValidateCommand.run(["art/work/fruit"], environment: fixture.environment())
        #expect(missing == .failure)
        #expect(fixture.stderr.isEmpty)
        #expect(fixture.stdout.contains("fruit  缺失"))
        #expect(fixture.stdout.contains("processed_1.png  未知文件"))
    }
}
