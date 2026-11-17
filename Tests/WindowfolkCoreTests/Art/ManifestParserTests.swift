import Foundation
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// ManifestParser 的单元测试（任务 2.4）。随机化的拒绝性质见 ManifestRejectionTests。
/// _Requirements: 1.6, 2.1, 2.2, 2.4, 2.6, 2.8, 2.9, 2.13_
@Suite struct ManifestParserTests {

    static let sheetA = "art/character_sheets/resident_a.png"
    static let sheetB = "art/character_sheets/resident_b.png"

    static func palette(_ group: PaletteGroup) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: group.requiredColors.map { ($0.rawValue, "#a1B2c3") })
    }

    static func entry(_ spec: AssetSpec) -> [String: Any] {
        let refs: [String]
        switch AssetRules.rules(for: spec.key)?.owner {
        case .a: refs = [sheetA]
        case .b: refs = ["./" + sheetB]
        case nil: refs = []
        }
        return [
            "key": spec.key,
            "description": "Sprite of \(spec.key)",
            "frames": spec.frames,
            "layout": "horizontal_no_gap",
            "canvas": "1024x1024",
            "references": refs,
        ]
    }

    /// 合法清单的原始字典；条目倒序给出。
    static func validDocument() -> [String: Any] {
        [
            "version": 1,
            "prefix": ["line one", "line two"],
            "palettes": Dictionary(uniqueKeysWithValues: PaletteGroup.allCases.map { ($0.rawValue, palette($0)) }),
            "entries": AssetCatalog.all.reversed().map(entry),
        ]
    }

    static func data(_ document: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    static func issues(_ result: Result<PromptManifest, ManifestIssues>) -> [ManifestIssue] {
        if case .failure(let issues) = result { return issues.issues }
        return []
    }

    @Test func parsesValidManifestInCatalogOrder() throws {
        let result = ManifestParser.parse(Self.data(Self.validDocument())) { _ in true }
        let manifest = try result.get()
        #expect(manifest.prefix == "line one\nline two")
        #expect(manifest.entries.map(\.key) == AssetCatalog.all.map(\.key))
        #expect(manifest.palettes[.wood]?[.main] == RGB(r: 0xA1, g: 0xB2, b: 0xC3))
        #expect(manifest.palettes[.residentA]?.count == 5)
        #expect(manifest.palettes[.plant]?.count == 4)
        // 参考图按文件写法保留。
        #expect(manifest.entry(for: "resident_b_idle")?.references == ["./" + Self.sheetB])
    }

    @Test func syntaxErrorReportsLine() {
        let text = "{\n  \"prefix\" : [\"a\"],\n  \"entries\" : [,]\n}"
        let issues = Self.issues(ManifestParser.parse(Data(text.utf8)) { _ in true })
        #expect(issues == [ManifestIssue(location: .line(3), message: issues.first?.message ?? "")])
    }

    @Test func nonUTF8Rejected() {
        var bytes = Array("{\n\"a\": \"".utf8)
        bytes.append(0xFF)
        bytes += Array("\"}".utf8)
        let issues = Self.issues(ManifestParser.parse(Data(bytes)) { _ in true })
        #expect(issues.map(\.location) == [.line(2)])
    }

    @Test func collectsAllIssues() {
        var document = Self.validDocument()
        document["prefix"] = ["  ", ""]
        var palettes = document["palettes"] as! [String: Any]
        palettes["plant"] = nil
        var wood = palettes["wood"] as! [String: Any]
        wood["shadow"] = nil
        wood["main"] = "#12345G"
        palettes["wood"] = wood
        document["palettes"] = palettes

        var entries = (document["entries"] as! [[String: Any]]).filter { $0["key"] as? String != "fruit" }
        func edit(_ key: String, _ change: (inout [String: Any]) -> Void) {
            let i = entries.firstIndex { $0["key"] as? String == key }!
            change(&entries[i])
        }
        edit("resident_a_idle") { $0["references"] = [Self.sheetB] }
        edit("resident_b_walking") { $0["frames"] = 99 }
        edit("plank") { $0["references"] = [Self.sheetA] }
        edit("ladder") { $0["layout"] = "vertical" }
        edit("toolbox") { $0["canvas"] = "0x10" }
        edit("visit_flag") { $0["description"] = String(repeating: "x", count: 1001) }
        edit("decor_chair") { $0["references"] = ["art/missing.png"] }
        entries.append(Self.entry(AssetCatalog.spec("plank")!))
        entries.append(["key": "unknown_key", "description": "d", "frames": 1,
                        "layout": "horizontal_no_gap", "canvas": "16x16", "references": []])
        document["entries"] = entries

        let issues = Self.issues(ManifestParser.parse(Self.data(document)) { $0 != "art/missing.png" })
        let locations = Set(issues.map(\.location))
        let expected: Set<ManifestIssue.Location> = [
            .document(field: "prefix"),
            .palette(group: "plant", color: nil),
            .palette(group: "wood", color: "shadow"),
            .palette(group: "wood", color: "main"),
            .entry(key: "fruit", field: "key"),
            .entry(key: "resident_a_idle", field: "references"),
            .entry(key: "resident_b_walking", field: "frames"),
            .entry(key: "plank", field: "references"),
            .entry(key: "plank", field: "key"),
            .entry(key: "ladder", field: "layout"),
            .entry(key: "toolbox", field: "canvas"),
            .entry(key: "visit_flag", field: "description"),
            .entry(key: "decor_chair", field: "references"),
            .entry(key: "unknown_key", field: "key"),
        ]
        #expect(locations == expected)
        // resident_a_idle：未列本人设定图、列了另一位的，各一条。
        #expect(issues.filter { $0.location == .entry(key: "resident_a_idle", field: "references") }.count == 2)
    }

    @Test func missingReferenceFileRejected() {
        let issues = Self.issues(ManifestParser.parse(Self.data(Self.validDocument())) { $0 != Self.sheetA })
        let keys = Set(issues.map(\.location))
        let residentA = AssetCatalog.all.map(\.key).filter { $0.hasPrefix("resident_a_") }
        #expect(keys == Set(residentA.map { .entry(key: $0, field: "references") }))
    }
}
