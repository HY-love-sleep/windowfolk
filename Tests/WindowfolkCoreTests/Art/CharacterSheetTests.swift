import Foundation
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// 角色设定图的测试（任务 12.4）。两张设定图都不存在时跳过。
/// _Requirements: 1.1, 1.5_
@Suite struct CharacterSheetTests {

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Art
            .deletingLastPathComponent()  // WindowfolkCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    static var manifestURL: URL { packageRoot.appendingPathComponent("art/prompt-manifest.json") }

    static func sheetURL(_ owner: ResidentOwner) -> URL {
        packageRoot.appendingPathComponent(ManifestParser.characterSheetPath(owner))
    }

    static var hasAnySheet: Bool {
        ResidentOwner.allCases.contains { FileManager.default.fileExists(atPath: sheetURL($0).path) }
    }

    @Test(.enabled(if: CharacterSheetTests.hasAnySheet, "两张角色设定图都不存在"))
    func sheetsHavePaletteSwatchesAndViews() throws {
        let data = try Data(contentsOf: Self.manifestURL)
        let manifest: PromptManifest
        switch ManifestParser.parse(data, fileExists: { _ in true }) {
        case .success(let value): manifest = value
        case .failure(let issues):
            Issue.record("art/prompt-manifest.json 解析失败：\n\(issues)")
            return
        }

        for owner in ResidentOwner.allCases {
            let url = Self.sheetURL(owner)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("跳过：\(ManifestParser.characterSheetPath(owner)) 尚未生成")
                continue
            }
            let fileData = try Data(contentsOf: url)
            guard let decoded = PNGCodec.decode(fileData) else {
                Issue.record("\(ManifestParser.characterSheetPath(owner)) 无法解码为 PNG")
                continue
            }
            #expect(decoded.hasAlpha, "\(owner.residentID.rawValue) 设定图应带 alpha 通道")
            let image = decoded.image
            #expect(image.width == SheetLayout.canvas.width && image.height == SheetLayout.canvas.height,
                    "\(owner.residentID.rawValue) 设定图尺寸应为 \(SheetLayout.canvas.canvasString)")

            let group = CharacterSheetPrompts.paletteGroup(for: owner)
            let colors = try #require(SheetLayout.swatchColors(manifest.palettes[group] ?? [:]),
                                      "清单缺少 Palette \(group.rawValue) 的 5 个颜色")
            for (index, color) in colors.enumerated() {
                let rect = SheetLayout.swatchRect(index)
                let center = image[rect.x + rect.width / 2, rect.y + rect.height / 2]
                #expect(center == RGBA(r: color.r, g: color.g, b: color.b, a: 255),
                        "\(owner.residentID.rawValue) 第 \(index) 个色块中心应为 \(color.hex)，实际 \(center)")
            }

            for index in 0..<SheetLayout.viewCount {
                let cell = SheetLayout.viewCellRect(index)
                guard let bounds = image.opaqueBounds(in: cell) else {
                    Issue.record("\(owner.residentID.rawValue) 第 \(index + 1) 个视图格为空")
                    continue
                }
                #expect(bounds.height >= SheetLayout.viewMinHeight,
                        "\(owner.residentID.rawValue) 第 \(index + 1) 个视图高度 \(bounds.height) 小于 \(SheetLayout.viewMinHeight)")
            }
        }
    }
}
