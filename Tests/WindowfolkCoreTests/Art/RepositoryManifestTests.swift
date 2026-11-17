import Foundation
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 仓库清单 `art/prompt-manifest.json` 的测试（任务 3.2）。
///
/// 两张 Character_Sheet 在手动任务 14.1 才生成。在那之前，解析时把缺失的设定图路径视为存在，
/// 并在测试输出中注明；两张设定图都生成后自动改为严格检查真实文件。
/// _Requirements: 1.3, 2.1, 2.5, 2.7, 2.8_
@Suite struct RepositoryManifestTests {

    // MARK: - 路径与加载

    /// 仓库根目录，按本测试文件位置推出。
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Art
            .deletingLastPathComponent()  // WindowfolkCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    static var manifestURL: URL {
        packageRoot.appendingPathComponent("art/prompt-manifest.json")
    }

    /// 两张设定图的仓库相对路径（已标准化）。
    static var sheetPaths: Set<String> {
        Set(ResidentOwner.allCases.map { (ManifestParser.characterSheetPath($0) as NSString).standardizingPath })
    }

    static func existsInRepository(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(path).path)
    }

    /// 尚不存在的设定图路径；为空时解析使用真实 `fileExists`。
    static var missingSheets: Set<String> {
        sheetPaths.filter { !existsInRepository($0) }
    }

    /// 解析用的 `fileExists`：真实检查；设定图未生成时把缺失的设定图路径视为存在。
    static func fileExists(_ path: String) -> Bool {
        if existsInRepository(path) { return true }
        return missingSheets.contains((path as NSString).standardizingPath)
    }

    static func loadData() throws -> Data {
        try Data(contentsOf: manifestURL)
    }

    static func parsed() throws -> PromptManifest {
        let missing = missingSheets
        if !missing.isEmpty {
            print("[RepositoryManifestTests] 注意：设定图尚未生成（手动任务 14.1），解析时把以下路径视为存在：\(missing.sorted().joined(separator: ", "))")
        }
        switch ManifestParser.parse(try loadData(), fileExists: fileExists) {
        case .success(let manifest):
            return manifest
        case .failure(let issues):
            Issue.record("art/prompt-manifest.json 解析失败：\n\(issues)")
            throw issues
        }
    }

    // MARK: - 解析与条目（R2.1、R2.8）

    @Test func parsesWith45EntriesInCatalogOrder() throws {
        let manifest = try Self.parsed()
        #expect(manifest.entries.count == 45)
        #expect(manifest.entries.map(\.key) == AssetCatalog.all.map(\.key))
        #expect(Set(manifest.entries.map(\.key)).count == 45)
    }

    // MARK: - 前缀关键词（R1.3）

    /// R1.3 的 10 点：每点至少一个关键词须出现在前缀中（不区分大小写）。
    static let prefixKeywords: [(point: String, keyword: String)] = [
        ("柔和手绘 Q 版画风", "chibi"),
        ("2px 左右的深色描边", "2px"),
        ("平涂加一层阴影", "one shadow tone"),
        ("柔和粉彩配色", "pastel"),
        ("透明背景", "transparent background"),
        ("居民朝右", "face right"),
        ("脚底贴住底边", "bottom edge"),
        ("水平居中", "centered horizontally"),
        ("画面中不出现文字", "no text"),
        ("不画地面阴影和背景", "no ground shadow"),
    ]

    @Test func prefixStatesTheTenStylePoints() throws {
        let prefix = try Self.parsed().prefix.lowercased()
        for item in Self.prefixKeywords {
            #expect(prefix.contains(item.keyword), "前缀缺少「\(item.point)」的关键词 \"\(item.keyword)\"")
        }
        #expect(prefix.contains("background"), "前缀应写明不画背景")
        #expect(prefix.contains("hand-drawn"), "前缀应写明手绘")
    }

    // MARK: - 不画物件、梯子、椅子（R2.7）

    @Test func residentEntriesSayWhatNotToDraw() throws {
        let manifest = try Self.parsed()
        let rules: [(state: String, object: String)] = [
            ("carrying", "carried object"),
            ("climbing", "ladder"),
            ("sitting", "chair"),
        ]
        var checked = 0
        for owner in ResidentOwner.allCases {
            for rule in rules {
                let key = "\(owner.residentID.rawValue)_\(rule.state)"
                let entry = try #require(manifest.entry(for: key), "缺少条目 \(key)")
                let text = entry.description.lowercased()
                #expect(text.contains("do not draw the \(rule.object)"), "\(key) 未写明不画 \(rule.object)")
                checked += 1
            }
        }
        #expect(checked == 6)
    }

    // MARK: - 画布（R2.5 与 API 尺寸约束）

    @Test func canvasesMeetFramePixelsAndAPIConstraints() throws {
        let manifest = try Self.parsed()
        let specs = Dictionary(uniqueKeysWithValues: AssetCatalog.all.map { ($0.key, $0) })
        for entry in manifest.entries {
            let spec = try #require(specs[entry.key])
            let w = entry.canvas.width
            let h = entry.canvas.height
            let frameW = spec.expectedPixelWidth / spec.frames
            let frameH = spec.expectedPixelHeight
            let label = "\(entry.key) 画布 \(entry.canvas.canvasString)"

            // R2.5：每帧不小于目标像素。
            #expect(w / spec.frames >= frameW, "\(label)：每帧宽 \(w / spec.frames) < \(frameW)")
            #expect(h >= frameH, "\(label)：高 \(h) < \(frameH)")

            // API：16 的倍数、宽高比 1:3 到 3:1、单边 ≤ 3840、总像素 655,360 到 8,294,400。
            #expect(w % 16 == 0 && h % 16 == 0, "\(label)：宽高须为 16 的倍数")
            #expect(w <= 3 * h && h <= 3 * w, "\(label)：宽高比须在 1:3 到 3:1 之间")
            #expect(w <= 3840 && h <= 3840, "\(label)：单边不超过 3840")
            #expect((655_360...8_294_400).contains(w * h), "\(label)：总像素 \(w * h) 超出范围")
        }
    }

    // MARK: - 稳定格式（R2.8 与 Printer）

    @Test func fileIsByteIdenticalToPrinterOutput() throws {
        let data = try Self.loadData()
        let manifest = try Self.parsed()
        let printed = ManifestPrinter.print(manifest)
        #expect(printed == data, "art/prompt-manifest.json 与 ManifestPrinter.print(parse(file)) 不一致")
    }

    // MARK: - 设定图检查模式

    /// 设定图生成后严格检查：参考图全部指向真实文件。
    @Test func referencesExistOnceSheetsAreGenerated() throws {
        let manifest = try Self.parsed()
        let missing = Self.missingSheets
        for entry in manifest.entries {
            for path in entry.references {
                let standardized = (path as NSString).standardizingPath
                if missing.contains(standardized) { continue }
                #expect(Self.existsInRepository(path), "\(entry.key) 的参考图不存在：\(path)")
            }
        }
        if missing.isEmpty {
            #expect(ManifestParser.parse(try Self.loadData(), fileExists: Self.existsInRepository).isSuccess)
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
