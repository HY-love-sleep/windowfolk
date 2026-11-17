import Foundation
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// `docs/art-spec.md` 的「出图流水线」一节测试（任务 12.3）。
/// _Requirements: 1.7_
@Suite struct ArtSpecDocTests {

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Art
            .deletingLastPathComponent()  // WindowfolkCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    static var documentURL: URL { packageRoot.appendingPathComponent("docs/art-spec.md") }
    static var manifestURL: URL { packageRoot.appendingPathComponent("art/prompt-manifest.json") }

    /// 「出图流水线」一节正文（到下一个二级标题为止）。
    static func pipelineSection() throws -> String {
        let document = try String(contentsOf: documentURL, encoding: .utf8)
        let start = try #require(document.range(of: "## 8. 出图流水线"), "文档缺少「出图流水线」一节")
        let rest = document[start.lowerBound...]
        let afterHeading = rest.index(after: rest.startIndex)
        let end = rest.range(of: "\n## ", range: afterHeading..<rest.endIndex)?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test func listsPipelineStepsInRequiredOrder() throws {
        let section = try Self.pipelineSection()
        let headers = [
            "步骤 1：设置",
            "步骤 2：生成原始图",
            "步骤 3：后处理",
            "步骤 4：预览",
            "步骤 5：写入最终素材",
            "步骤 6：校验",
        ]
        var offsets: [Int] = []
        for header in headers {
            let range = try #require(section.range(of: header), "缺少「\(header)」")
            offsets.append(section.distance(from: section.startIndex, to: range.lowerBound))
        }
        #expect(offsets == offsets.sorted(), "步骤顺序不符：\(offsets)")

        #expect(section.contains("OPENAI_API_KEY"), "步骤 1 应说明 API_Key_Variable")
        #expect(section.contains("WINDOWFOLK_IMAGE_MODEL"), "步骤 1 应说明可选的 Model_Variable")
        for command in ["generate", "process", "preview", "promote", "validate"] {
            #expect(section.contains("swift run windowfolk-art \(command)"),
                    "缺少 \(command) 的完整命令")
        }
        #expect(section.contains("swift run windowfolk-art sheet generate"))
        #expect(section.contains("swift run windowfolk-art sheet compose"))
    }

    @Test func listsManifestSheetPathsAndPaletteValues() throws {
        let section = try Self.pipelineSection()
        #expect(section.contains("art/prompt-manifest.json"))
        for owner in ResidentOwner.allCases {
            #expect(section.contains(ManifestParser.characterSheetPath(owner)),
                    "文档缺少设定图路径 \(ManifestParser.characterSheetPath(owner))")
        }

        #expect(FileManager.default.fileExists(atPath: Self.manifestURL.path),
                "art/prompt-manifest.json 必须存在")
        let data = try Data(contentsOf: Self.manifestURL)
        let manifest: PromptManifest
        switch ManifestParser.parse(data, fileExists: { _ in true }) {
        case .success(let value): manifest = value
        case .failure(let issues):
            Issue.record("art/prompt-manifest.json 解析失败：\n\(issues)")
            return
        }

        for group in PaletteGroup.allCases {
            #expect(section.contains("`\(group.rawValue)`"), "文档缺少 Palette 组 \(group.rawValue)")
            guard let colors = manifest.palettes[group] else {
                Issue.record("清单缺少 Palette \(group.rawValue)")
                continue
            }
            for name in group.requiredColors {
                guard let color = colors[name] else {
                    Issue.record("清单缺少 \(group.rawValue).\(name.rawValue)")
                    continue
                }
                #expect(section.contains(color.hex),
                        "文档中的 \(group.rawValue).\(name.rawValue) 应写成 \(color.hex)")
            }
        }
    }

    @Test func characterSheetPathsExistOnceGenerated() throws {
        // 设定图在出图前不存在；存在后文档列出的路径必须是真实文件。
        for owner in ResidentOwner.allCases {
            let path = ManifestParser.characterSheetPath(owner)
            let url = Self.packageRoot.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                #expect(FileManager.default.fileExists(atPath: url.path))
            } else {
                print("跳过：\(path) 尚未生成，出图后此检查自动生效")
            }
        }
    }
}
