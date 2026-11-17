import Foundation
import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// PromptComposer 的属性测试与示例（任务 2.8）。清单生成器见 Support/ManifestGen.swift。
@Suite struct PromptComposerTests {

    // Feature: 美术, Property 3: 提示词组合确定且有序
    /// *For any* 合法清单和其中任一 Asset_Key，`compose` 的结果以 `prefix` 开头、以该条目 `description` 结尾，
    /// 包含且只包含 `AssetRules.palettes` 所列组的全部色值，两次调用逐字节相同。
    ///
    /// 比较按 UTF-8 字节进行，避免 `\r` 与 `\n`、字母与组合符跨段合并成一个 Character 时干扰切分。
    ///
    /// **Validates: Requirements 2.12**
    @Test func composeIsDeterministicAndOrdered() async {
        await propertyCheck(count: 100, input: Gen.manifest) { manifest in
            let reordered = reinsertedPalettes(manifest)
            for spec in AssetCatalog.all {
                guard let composed = PromptComposer.compose(manifest, key: spec.key),
                      let entry = manifest.entry(for: spec.key),
                      let rules = AssetRules.rules(for: spec.key) else {
                    Issue.record("\(spec.key)：compose 返回 nil")
                    continue
                }

                // 逐字节确定：两次调用相同；同内容但 Palette 字典插入顺序不同的清单结果也相同。
                #expect(PromptComposer.compose(manifest, key: spec.key) == composed, "\(spec.key)：两次组合结果不同")
                #expect(PromptComposer.compose(reordered, key: spec.key) == composed, "\(spec.key)：字典顺序影响了结果")

                let bytes = Array(composed.utf8)
                let applicable = PaletteGroup.allCases.filter(rules.palettes.contains)
                if applicable.isEmpty {
                    // 无适用 Palette：prefix 与 description 之间只有一个空行。
                    #expect(bytes == Array((manifest.prefix + "\n\n" + entry.description).utf8),
                            "\(spec.key)：无适用 Palette 时应为 prefix、空行、description")
                    continue
                }

                let head = Array((manifest.prefix + "\n\n").utf8)
                let tail = Array(("\n\n" + entry.description).utf8)
                guard bytes.count >= head.count + tail.count,
                      bytes.starts(with: head),
                      Array(bytes.suffix(tail.count)) == tail else {
                    Issue.record("\(spec.key)：结果不以 prefix 加空行开头或不以空行加 description 结尾")
                    continue
                }

                // 中段：适用 Palette 每组一行，位于 head 与 tail 之间。
                let middleBytes = bytes[head.count..<(bytes.count - tail.count)]
                let middle = String(decoding: middleBytes, as: UTF8.self)
                let lines = middle.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                #expect(lines.count == applicable.count, "\(spec.key)：Palette 行数 \(lines.count) ≠ \(applicable.count)")

                // 每行只含该组色值：组名、色名顺序与色值都与清单一致。
                for (line, group) in Swift.zip(lines, applicable) {
                    let colors = manifest.palettes[group] ?? [:]
                    let expected = "Palette \(group.rawValue): " + PaletteColorName.allCases
                        .compactMap { name in colors[name].map { "\(name.rawValue) \($0.hex)" } }
                        .joined(separator: ", ")
                    #expect(line == expected, "\(spec.key)：\(group.rawValue) 行不符")
                }

                // 不适用的组不出现在中段。
                for group in PaletteGroup.allCases where !applicable.contains(group) {
                    #expect(!middle.contains("Palette \(group.rawValue):"), "\(spec.key)：混入不适用的组 \(group.rawValue)")
                }
            }
        }
    }

    // MARK: - 示例

    @Test func unknownKeyReturnsNil() {
        let manifest = Self.sampleManifest
        #expect(PromptComposer.compose(manifest, key: "no_such_asset") == nil)
        #expect(PromptComposer.compose(manifest, key: "") == nil)
    }

    @Test func missingEntryReturnsNil() {
        var manifest = Self.sampleManifest
        manifest.entries.removeAll { $0.key == AssetCatalog.fruitKey }
        #expect(PromptComposer.compose(manifest, key: AssetCatalog.fruitKey) == nil)
    }

    @Test func keyWithoutPaletteOmitsMiddleSection() throws {
        let manifest = Self.sampleManifest
        let description = try #require(manifest.entry(for: AssetCatalog.lampOffKey)).description
        #expect(PromptComposer.compose(manifest, key: AssetCatalog.lampOffKey) == "PREFIX\n\n" + description)
    }

    @Test func singlePaletteLineFormat() throws {
        let manifest = Self.sampleManifest
        let description = try #require(manifest.entry(for: AssetCatalog.fruitKey)).description
        let expected = "PREFIX\n\nPalette plant: main #0A0B0C, shadow #102030, highlight #ABCDEF, outline #000000\n\n"
            + description
        #expect(PromptComposer.compose(manifest, key: AssetCatalog.fruitKey) == expected)
    }

    /// 固定清单：每组颜色固定，前缀为 `PREFIX`，描述为键名。
    static var sampleManifest: PromptManifest {
        let plant: [PaletteColorName: RGB] = [
            .main: RGB(r: 0x0A, g: 0x0B, b: 0x0C),
            .shadow: RGB(r: 0x10, g: 0x20, b: 0x30),
            .highlight: RGB(r: 0xAB, g: 0xCD, b: 0xEF),
            .outline: RGB(r: 0, g: 0, b: 0),
        ]
        var palettes: [PaletteGroup: [PaletteColorName: RGB]] = [:]
        for group in PaletteGroup.allCases {
            palettes[group] = Dictionary(uniqueKeysWithValues: group.requiredColors.map {
                ($0, RGB(r: 0x11, g: 0x22, b: 0x33))
            })
        }
        palettes[.plant] = plant
        let entries = AssetCatalog.all.map { spec in
            PromptEntry(
                key: spec.key, description: "desc " + spec.key, frames: spec.frames,
                layout: .horizontalNoGap, canvas: PixelSize(width: 1024, height: 1024), references: []
            )
        }
        return PromptManifest(prefix: "PREFIX", palettes: palettes, entries: entries)
    }
}

/// 内容相同、但 Palette 字典按相反顺序重新插入的清单。
fileprivate func reinsertedPalettes(_ manifest: PromptManifest) -> PromptManifest {
    var palettes: [PaletteGroup: [PaletteColorName: RGB]] = [:]
    for group in PaletteGroup.allCases.reversed() {
        guard let colors = manifest.palettes[group] else { continue }
        var row: [PaletteColorName: RGB] = [:]
        for name in PaletteColorName.allCases.reversed() {
            if let value = colors[name] { row[name] = value }
        }
        palettes[group] = row
    }
    var copy = manifest
    copy.palettes = palettes
    return copy
}
