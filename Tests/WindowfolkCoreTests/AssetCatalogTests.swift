import Foundation
import Testing
@testable import WindowfolkCore

/// 素材清单测试（任务 17.8）：清单完整性、与 `docs/art-spec.md` 一致、PNG 校验和素材目录选择。
/// _Requirements: 25.2, 25.3, 25.4, 25.5, 25.6, 25.8_
@Suite struct AssetCatalogTests {

    // MARK: - 期望的清单

    /// 气泡种类到素材图标的映射。switch 穷举 `Bubble`，新增剧情气泡时编译失败，提醒补素材。
    static func icon(for bubble: Bubble) -> BubbleIcon {
        switch bubble {
        case .wish: return .wish
        case .dots: return .dots
        case .heart: return .heart
        }
    }

    /// Requirement 25.2 列出的全部图形：两位居民 × 9 个状态、3 个生长阶段、果子、木板、梯子、工具箱、4 种气泡。
    static var requiredKeys: [String] {
        var keys: [String] = []
        for id in ResidentID.allCases {
            for state in ResidentState.allCases { keys.append("\(id.rawValue)_\(state.rawValue)") }
        }
        keys += ["flower_pot", "flower_sprout", "flower_bloom", "fruit", "plank", "ladder", "toolbox"]
        keys += ["bubble_wish", "bubble_dots", "bubble_question", "bubble_heart"]
        return keys
    }

    // MARK: - 清单完整性

    @Test func catalogCoversEveryRequiredItemExactlyOnce() {
        #expect(ResidentState.allCases.count == 9)
        #expect(ResidentID.allCases.count == 2)

        let keys = AssetCatalog.all.map(\.key)
        // 18 + 3 + 4（果子、木板、梯子、工具箱）+ 4 = 29。
        #expect(Self.requiredKeys.count == 29)
        #expect(keys.count == Self.requiredKeys.count)
        #expect(Set(keys).count == keys.count, "清单中有重复的素材键")
        #expect(Set(keys) == Set(Self.requiredKeys))

        let fileNames = AssetCatalog.all.map(\.fileName)
        #expect(Set(fileNames).count == fileNames.count, "清单中有重复的文件名")
    }

    @Test func keyHelpersResolveToCatalogEntries() {
        for id in ResidentID.allCases {
            for state in ResidentState.allCases {
                let spec = AssetCatalog.residentSpec(id, state)
                #expect(spec.key == AssetCatalog.residentKey(id, state))
                #expect(spec.size == AssetCatalog.residentSize)
                #expect(spec.frames == AssetCatalog.frameCount(for: state))
                #expect(spec.frames >= 1)
            }
        }
        for stage in [GrowthStage.pot, .sprout, .bloom] {
            let key = AssetCatalog.flowerKey(growth: stage)
            #expect(key == "flower_\(stage.name)")
            #expect(AssetCatalog.spec(key)?.size == AssetCatalog.flowerSize)
        }
        for icon in BubbleIcon.allCases {
            #expect(AssetCatalog.spec(AssetCatalog.bubbleKey(icon))?.size == AssetCatalog.bubbleSize)
        }
        // 剧情气泡和戳居民的「?」都有对应素材。
        let used: Set<BubbleIcon> = [
            Self.icon(for: .wish(receiver: .b)), Self.icon(for: .dots), Self.icon(for: .heart), .question,
        ]
        #expect(used == Set(BubbleIcon.allCases))

        #expect(AssetCatalog.spec(AssetCatalog.fruitKey)?.size == AssetCatalog.fruitSize)
        #expect(AssetCatalog.spec(AssetCatalog.plankKey)?.tiling == .horizontal)
        #expect(AssetCatalog.spec(AssetCatalog.ladderKey)?.tiling == .vertical)
        #expect(AssetCatalog.spec(AssetCatalog.toolboxKey)?.size == AssetCatalog.toolboxSize)
        #expect(AssetCatalog.spec("nonexistent") == nil)
    }

    /// Requirement 25.3：命中区域和占位图形的尺寸与规格一致。
    @Test func spriteMetricsMatchCatalogSizes() {
        #expect(SpriteMetrics.resident == AssetCatalog.residentSize)
        #expect(SpriteMetrics.flower == AssetCatalog.flowerSize)
        #expect(SpriteMetrics.fruit == AssetCatalog.fruitSize)
        #expect(SpriteMetrics.toolbox == AssetCatalog.toolboxSize)
        #expect(SpriteMetrics.bubble == AssetCatalog.bubbleSize)
        #expect(SpriteMetrics.plankThickness == AssetCatalog.plankTileSize.height)
        #expect(SpriteMetrics.ladderWidth == AssetCatalog.ladderTileSize.width)
        #expect(SpriteMetrics.itemSize(.fruit) == AssetCatalog.fruitSize)
        #expect(SpriteMetrics.itemSize(.flower(storyRound: nil)) == AssetCatalog.flowerSize)
        let rect = SpriteMetrics.residentRect(bottomCenter: Point(x: 100, y: 200))
        #expect(rect.width == AssetCatalog.residentSize.width)
        #expect(rect.height == AssetCatalog.residentSize.height)
    }

    // MARK: - docs/art-spec.md

    static var artSpecURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WindowfolkCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("docs/art-spec.md")
    }

    struct DocRow { var pixelSize: String?; var frames: Int? }

    /// 解析文档中以「| `xxx.png` |」开头的表格行：取第一个纯数字单元格为帧数，最后一个「W×H」单元格为像素尺寸。
    static func parseDocRows(_ text: String) -> [String: [DocRow]] {
        var rows: [String: [DocRow]] = [:]
        for line in text.components(separatedBy: .newlines) {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3, cells[0].isEmpty else { continue }
            let first = cells[1]
            guard first.hasPrefix("`"), first.hasSuffix(".png`") else { continue }
            let name = String(first.dropFirst().dropLast())
            let frames = cells.dropFirst(2).first { Int($0) != nil }.flatMap { Int($0) }
            let size = cells.dropFirst(2).last { cell in
                let parts = cell.split(separator: "×")
                return parts.count == 2 && parts.allSatisfy { Int($0) != nil }
            }
            rows[name, default: []].append(DocRow(pixelSize: size, frames: frames))
        }
        return rows
    }

    @Test func artSpecListsEveryFileNameWithMatchingSpec() throws {
        let text = try String(contentsOf: Self.artSpecURL, encoding: .utf8)
        let rows = Self.parseDocRows(text)

        #expect(text.contains("共 \(AssetCatalog.all.count) 个文件"))
        #expect(Set(rows.keys) == Set(AssetCatalog.all.map(\.fileName)), "文档表格与清单的文件名集合不一致")

        // 气泡表只有文件名一列，尺寸写在小节标题中。
        let bubble = AssetCatalog.bubbleSize
        let bubblePx = "\(Int(bubble.width * 2))×\(Int(bubble.height * 2)) 像素"
        #expect(text.contains("每个 \(Int(bubble.width))×\(Int(bubble.height))pt，即 \(bubblePx)"))

        for spec in AssetCatalog.all {
            let entries = rows[spec.fileName] ?? []
            #expect(entries.count == 1, "\(spec.fileName) 在文档表格中出现 \(entries.count) 次")
            guard let row = entries.first else { continue }
            let expectedPx = "\(spec.expectedPixelWidth)×\(spec.expectedPixelHeight)"
            if spec.key.hasPrefix("bubble_") {
                #expect(row.pixelSize == nil && row.frames == nil)
                #expect(spec.frames == 1)
            } else {
                #expect(row.pixelSize == expectedPx, "\(spec.fileName)：文档 \(row.pixelSize ?? "nil")，清单 \(expectedPx)")
                #expect(row.frames == spec.frames, "\(spec.fileName)：文档帧数 \(row.frames.map(String.init) ?? "nil")，清单 \(spec.frames)")
            }
        }
    }

    @Test func artSpecStateTableMatchesFrameCounts() throws {
        let text = try String(contentsOf: Self.artSpecURL, encoding: .utf8)
        for state in ResidentState.allCases {
            let prefix = "| `\(state.rawValue)` | \(AssetCatalog.frameCount(for: state)) |"
            #expect(text.contains(prefix), "第 4 节缺少或帧数不符：\(state.rawValue)")
        }
    }

    // MARK: - PNG 校验

    @Test func validationAcceptsExactSpecForEveryEntry() {
        for spec in AssetCatalog.all {
            let result = AssetCatalog.validation(fileName: spec.fileName,
                                                 pixelWidth: spec.expectedPixelWidth,
                                                 pixelHeight: spec.expectedPixelHeight)
            #expect(result == .valid(spec))
            #expect(AssetCatalog.validate(fileName: spec.fileName, pixelWidth: spec.expectedPixelWidth,
                                          pixelHeight: spec.expectedPixelHeight))
        }
    }

    @Test func validationRejectsWrongSizeAndFrameCount() {
        for spec in AssetCatalog.all {
            let w = spec.expectedPixelWidth, h = spec.expectedPixelHeight
            let frameW = w / spec.frames
            let wrongSize = AssetValidation.wrongPixelSize(expectedWidth: w, expectedHeight: h)

            // @1x 图（像素等于 pt）。
            #expect(AssetCatalog.validation(fileName: spec.fileName, pixelWidth: w / 2, pixelHeight: h / 2) == wrongSize)
            // 高度不对。
            #expect(AssetCatalog.validation(fileName: spec.fileName, pixelWidth: w, pixelHeight: h + 1) == wrongSize)
            // 宽度不是每帧宽度的整数倍。
            #expect(AssetCatalog.validation(fileName: spec.fileName, pixelWidth: w + 1, pixelHeight: h) == wrongSize)
            #expect(AssetCatalog.validation(fileName: spec.fileName, pixelWidth: 0, pixelHeight: h) == wrongSize)
            // 多一帧。
            #expect(AssetCatalog.validation(fileName: spec.fileName, pixelWidth: w + frameW, pixelHeight: h)
                    == .wrongFrameCount(expected: spec.frames, actual: spec.frames + 1))
            // 少一帧（单帧素材没有「少一帧」）。
            if spec.frames > 1 {
                #expect(AssetCatalog.validation(fileName: spec.fileName, pixelWidth: w - frameW, pixelHeight: h)
                        == .wrongFrameCount(expected: spec.frames, actual: spec.frames - 1))
            }
        }
        // 例子：walking 6 帧，误交成 4 帧的 sheet。
        #expect(AssetCatalog.validation(fileName: "resident_a_walking.png", pixelWidth: 256, pixelHeight: 64)
                == .wrongFrameCount(expected: 6, actual: 4))
        #expect(!AssetCatalog.validate(fileName: "resident_a_walking.png", pixelWidth: 256, pixelHeight: 64))
    }

    @Test func validationRejectsUnknownNamesAndCaseVariants() {
        let names = [
            "unknown.png", "resident_c_idle.png", "resident_a_idle", "resident_a_idle.PNG",
            "Resident_A_Idle.png", "TOOLBOX.png", "Fruit.png", "resident_a_idle@2x.png",
            "resident-a-idle.png", "flower.png", "bubble_text.png", " fruit.png", "",
        ]
        for name in names {
            #expect(AssetCatalog.spec(forFileName: name) == nil, "\(name)")
            #expect(AssetCatalog.validation(fileName: name, pixelWidth: 64, pixelHeight: 64) == .unknownFileName, "\(name)")
        }
        for spec in AssetCatalog.all {
            #expect(AssetCatalog.spec(forFileName: spec.fileName) == spec)
            let upper = spec.fileName.uppercased()
            #expect(AssetCatalog.validation(fileName: upper, pixelWidth: spec.expectedPixelWidth,
                                            pixelHeight: spec.expectedPixelHeight) == .unknownFileName)
        }
    }

    // MARK: - 素材目录选择

    @Test func directoryCandidatesFollowDocumentedOrder() {
        let all = AssetCatalog.directoryCandidates(
            environment: ["WINDOWFOLK_ASSETS": "/art"],
            bundleResourcePath: "/App.app/Contents/Resources",
            currentDirectory: "/repo")
        #expect(all == ["/art", "/App.app/Contents/Resources/Assets", "/repo/Assets"])

        // 环境变量为空或缺失时跳过；bundle 缺失时跳过。
        #expect(AssetCatalog.directoryCandidates(environment: ["WINDOWFOLK_ASSETS": ""],
                                                 bundleResourcePath: nil, currentDirectory: "/repo")
                == ["/repo/Assets"])
        #expect(AssetCatalog.directoryCandidates(environment: [:], bundleResourcePath: nil,
                                                 currentDirectory: nil).isEmpty)

        // `~` 展开为主目录。
        let tilde = AssetCatalog.directoryCandidates(environment: ["WINDOWFOLK_ASSETS": "~/art"],
                                                     bundleResourcePath: nil, currentDirectory: nil)
        #expect(tilde.count == 1)
        #expect(!(tilde.first ?? "~").hasPrefix("~"))
        #expect(tilde.first?.hasSuffix("/art") == true)
    }

    @Test func selectDirectoryUsesFirstExistingOnly() {
        let candidates = ["/art", "/App.app/Contents/Resources/Assets", "/repo/Assets"]
        #expect(AssetCatalog.selectDirectory(candidates) { _ in true } == "/art")
        #expect(AssetCatalog.selectDirectory(candidates) { $0 != "/art" } == "/App.app/Contents/Resources/Assets")
        #expect(AssetCatalog.selectDirectory(candidates) { $0 == "/repo/Assets" } == "/repo/Assets")
        #expect(AssetCatalog.selectDirectory(candidates) { _ in false } == nil)
        #expect(AssetCatalog.selectDirectory([]) { _ in true } == nil)
    }

    @Test func selectDirectoryWithRealFileSystem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetCatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: cwd.appendingPathComponent("Assets"),
                                                withIntermediateDirectories: true)
        let isDir: (String) -> Bool = { path in
            var flag: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
        }
        let candidates = AssetCatalog.directoryCandidates(
            environment: ["WINDOWFOLK_ASSETS": root.appendingPathComponent("missing").path],
            bundleResourcePath: root.appendingPathComponent("App.app/Contents/Resources").path,
            currentDirectory: cwd.path)
        #expect(AssetCatalog.selectDirectory(candidates, isDirectory: isDir)
                == cwd.appendingPathComponent("Assets").path)

        try FileManager.default.removeItem(at: cwd.appendingPathComponent("Assets"))
        #expect(AssetCatalog.selectDirectory(candidates, isDirectory: isDir) == nil)
    }
}
