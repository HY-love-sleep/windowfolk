import Foundation
import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// Prompt_Manifest 往返与稳定格式化的属性测试（任务 2.5）。生成器见 Support/ManifestGen.swift。
@Suite struct ManifestRoundTripTests {

    // Feature: 美术, Property 1: 清单往返与稳定格式化
    /// *For any* 合法清单对象 `m`，`parse(print(m))` 成功且等于 `m`，并且 `print(m)` 两次调用逐字节相同、
    /// `print(parse(print(m)))` 与 `print(m)` 逐字节相同。
    ///
    /// **Validates: Requirements 1.2, 2.8, 2.10, 2.11**
    @Test func manifestRoundTripsAndPrintsStably() async {
        await propertyCheck(count: 200, input: Gen.manifest) { manifest in
            let printed = ManifestPrinter.print(manifest)
            #expect(ManifestPrinter.print(manifest) == printed, "同一清单两次格式化结果不同")

            switch ManifestParser.parse(printed, fileExists: ManifestGen.fileExists(for: manifest)) {
            case .success(let parsed):
                #expect(parsed == manifest, "解析结果与原清单不等")
                #expect(ManifestPrinter.print(parsed) == printed, "再次格式化结果与首次不同")
            case .failure(let issues):
                Issue.record("合法清单解析失败：\n\(issues)")
            }
        }
    }

    /// 生成器自检：条目数与顺序符合 Asset_Catalog，描述长度在 1 到 1000，居民条目列本人设定图、
    /// 非居民条目不列设定图。
    @Test func generatorProducesValidManifests() async {
        let sheets = Set(ResidentOwner.allCases.map(ManifestParser.characterSheetPath))
        await propertyCheck(count: 100, input: Gen.manifest) { manifest in
            #expect(manifest.entries.map(\.key) == AssetCatalog.all.map(\.key))
            #expect(!manifest.prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            for entry in manifest.entries {
                #expect((1...ManifestParser.maxDescriptionLength).contains(entry.description.count), "\(entry.key)")
                let listed = Set(entry.references).intersection(sheets)
                if let owner = AssetRules.rules(for: entry.key)?.owner {
                    #expect(listed == [ManifestParser.characterSheetPath(owner)], "\(entry.key)")
                } else {
                    #expect(listed.isEmpty, "\(entry.key)")
                }
            }
        }
    }

    /// 边界示例：多行前缀含 `\r\n`、空行与首尾空白，描述含引号、方括号、换行和中文，长度恰为 1000。
    @Test func boundaryExampleRoundTrips() throws {
        let palettes = Dictionary(uniqueKeysWithValues: PaletteGroup.allCases.map { group in
            (group, Dictionary(uniqueKeysWithValues: group.requiredColors.map { ($0, RGB(r: 0xab, g: 0x0c, b: 0xff)) }))
        })
        let longText = "Say \"hi\" [x]\r\n你好\\" + String(repeating: "中", count: 984)
        #expect(longText.count == 1000)
        let manifest = PromptManifest(
            prefix: "  line one\r\n\n\nline 👩‍👩‍👧 two\n",
            palettes: palettes,
            entries: AssetCatalog.all.enumerated().map { index, spec in
                ManifestGen.entry(for: spec, .init(
                    description: index == 0 ? longText : "e\u{301}",
                    width: 2048, height: 768,
                    extraReferences: ["art/references/[draft] \"v2\".png"],
                    sheetPosition: 1
                ))
            }
        )
        let printed = ManifestPrinter.print(manifest)
        let text = try #require(String(data: printed, encoding: .utf8))
        #expect(text.contains("#AB0CFF"), "色值应输出为大写")
        let parsed = try ManifestParser.parse(printed, fileExists: ManifestGen.fileExists(for: manifest)).get()
        #expect(parsed == manifest)
        #expect(ManifestPrinter.print(parsed) == printed)
    }

    /// 回归：JSONSerialization 会删掉字符串开头的 U+FEFF。描述以 U+FEFF 开头、恰为 "\u{FEFF}"
    /// （长度 1，合法）以及含 U+2028、控制字符时都须原样往返。
    @Test func byteOrderMarkDescriptionsRoundTrip() throws {
        let palettes = Dictionary(uniqueKeysWithValues: PaletteGroup.allCases.map { group in
            (group, Dictionary(uniqueKeysWithValues: group.requiredColors.map { ($0, RGB(r: 1, g: 2, b: 3)) }))
        })
        let samples = ["\u{FEFF}", "\u{FEFF}开头的描述", "\u{FEFF}\u{FEFF}x\u{2028}\u{1}\u{FEFF}"]
        let manifest = PromptManifest(
            prefix: "\u{FEFF}prefix",
            palettes: palettes,
            entries: AssetCatalog.all.enumerated().map { index, spec in
                ManifestGen.entry(for: spec, .init(
                    description: samples[index % samples.count],
                    width: 64, height: 64, extraReferences: [], sheetPosition: 0
                ))
            }
        )
        #expect("\u{FEFF}".count == 1)
        let printed = ManifestPrinter.print(manifest)
        let parsed = try ManifestParser.parse(printed, fileExists: ManifestGen.fileExists(for: manifest)).get()
        #expect(parsed.entries.first?.description.unicodeScalars.elementsEqual("\u{FEFF}".unicodeScalars) == true)
        #expect(parsed == manifest)
        #expect(ManifestPrinter.print(parsed) == printed)
    }
}
