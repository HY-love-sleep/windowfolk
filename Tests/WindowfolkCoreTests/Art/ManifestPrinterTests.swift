import Foundation
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// ManifestPrinter 的单元测试（任务 2.3）。往返性质见 ManifestRoundTripTests。
/// _Requirements: 2.10_
@Suite struct ManifestPrinterTests {

    static func sample() -> PromptManifest {
        let catalog = AssetCatalog.all
        // 故意倒序给出，检查输出按 Asset_Catalog 顺序。
        let entries = [catalog[2], catalog[0], catalog[1]].map { spec in
            PromptEntry(
                key: spec.key,
                description: "Say \"hi\" [x] 你好\nline2",
                frames: spec.frames,
                canvas: PixelSize(width: 2048, height: 768),
                references: ["art/character_sheets/resident_a.png"]
            )
        }
        return PromptManifest(
            prefix: "Cute chibi sprite\nclean 2px outline",
            palettes: [
                .wood: [.main: RGB(r: 0xab, g: 0x12, b: 0xcd), .outline: RGB(r: 0, g: 0, b: 0)],
                .residentA: [.blush: RGB(r: 0xff, g: 0x9e, b: 0xa8)],
            ],
            entries: entries
        )
    }

    static func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func outputIsByteIdenticalAcrossCalls() {
        let manifest = Self.sample()
        let first = ManifestPrinter.print(manifest)
        #expect(first == ManifestPrinter.print(manifest))
        // 字典插入顺序不同的等价对象也得到相同字节。
        var shuffled = manifest
        shuffled.palettes = [
            .residentA: [.blush: RGB(r: 0xff, g: 0x9e, b: 0xa8)],
            .wood: [.outline: RGB(r: 0, g: 0, b: 0), .main: RGB(r: 0xab, g: 0x12, b: 0xcd)],
        ]
        #expect(first == ManifestPrinter.print(shuffled))
    }

    @Test func formatsFieldsAsDesigned() throws {
        let data = ManifestPrinter.print(Self.sample())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasSuffix("}\n"))
        #expect(!text.contains("\\/"), "斜杠不应转义")
        #expect(text.contains("\"version\" : 1"))

        let root = try Self.json(data)
        #expect(root["version"] as? Int == 1)
        #expect(root["prefix"] as? [String] == ["Cute chibi sprite", "clean 2px outline"])

        let palettes = try #require(root["palettes"] as? [String: [String: String]])
        #expect(palettes["wood"] == ["main": "#AB12CD", "outline": "#000000"])
        #expect(palettes["resident_a"] == ["blush": "#FF9EA8"])

        let entries = try #require(root["entries"] as? [[String: Any]])
        #expect(entries.map { $0["key"] as? String } == AssetCatalog.all.prefix(3).map(\.key))
        let first = entries[0]
        #expect(first["canvas"] as? String == "2048x768")
        #expect(first["layout"] as? String == "horizontal_no_gap")
        #expect(first["frames"] as? Int == AssetCatalog.all[0].frames)
        #expect(first["description"] as? String == "Say \"hi\" [x] 你好\nline2")
        #expect(first["references"] as? [String] == ["art/character_sheets/resident_a.png"])
    }

    @Test func topLevelKeysAreSorted() throws {
        let text = try #require(String(data: ManifestPrinter.print(Self.sample()), encoding: .utf8))
        let positions = ["\"entries\"", "\"palettes\"", "\"prefix\"", "\"version\""].map {
            text.range(of: $0)?.lowerBound
        }
        let found = positions.compactMap { $0 }
        #expect(found.count == 4)
        #expect(found == found.sorted())
    }

    @Test(arguments: ["", "one", "a\n\nb\n", "crlf\r\nnext"])
    func prefixSplitsOnNewlineAndRejoinsLosslessly(prefix: String) throws {
        var manifest = Self.sample()
        manifest.prefix = prefix
        let lines = try #require(try Self.json(ManifestPrinter.print(manifest))["prefix"] as? [String])
        #expect(lines.joined(separator: "\n") == prefix)
        #expect(lines.count == prefix.unicodeScalars.filter { $0 == "\n" }.count + 1)
    }
}
