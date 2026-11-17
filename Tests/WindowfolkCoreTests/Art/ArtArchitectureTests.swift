import Foundation
import Testing
import WindowfolkCore

/// 美术流水线的架构与快照测试（任务 1.2）。
/// _Requirements: 5.7, 9.5, 9.6, 9.8_
@Suite struct ArtArchitectureTests {

    // MARK: - 路径

    /// 仓库根目录，按本测试文件位置推出。
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Art
            .deletingLastPathComponent()  // WindowfolkCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    static func sourcesDirectory(_ target: String) -> URL {
        packageRoot.appendingPathComponent("Sources/\(target)", isDirectory: true)
    }

    /// 三个流水线 target。
    static let pipelineTargets = ["WindowfolkArtKit", "WindowfolkArtIO", "windowfolk-art"]

    /// 列出某个 target 全部源文件中的导入：(文件名, 行号, 模块名)。
    static func imports(inTarget target: String) throws -> [(file: String, line: Int, module: String)] {
        let files = ArchitectureTests.swiftFiles(in: sourcesDirectory(target))
        #expect(!files.isEmpty, "Sources/\(target) 中没有 .swift 文件")
        var result: [(file: String, line: Int, module: String)] = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                if let module = ArchitectureTests.importedModule(in: line) {
                    result.append((file.lastPathComponent, index + 1, module))
                }
            }
        }
        return result
    }

    // MARK: - 导入限制（R9.8 及设计「纯逻辑层只导入 Foundation 和 WindowfolkCore」）

    @Test func artKitImportsOnlyFoundationAndCore() throws {
        let allowed: Set<String> = ["Foundation", "WindowfolkCore"]
        for entry in try Self.imports(inTarget: "WindowfolkArtKit") {
            #expect(allowed.contains(entry.module),
                    "WindowfolkArtKit/\(entry.file):\(entry.line) 导入了 \(entry.module)")
        }
    }

    @Test(arguments: pipelineTargets)
    func pipelineTargetDoesNotImportAppKitOrSpriteKit(target: String) throws {
        for entry in try Self.imports(inTarget: target) {
            #expect(!ArchitectureTests.forbiddenModules.contains(entry.module),
                    "\(target)/\(entry.file):\(entry.line) 导入了 \(entry.module)")
        }
    }

    // MARK: - AssetCatalog 快照（R9.5）

    struct Snapshot: Equatable, CustomStringConvertible {
        var key: String
        var width: Double
        var height: Double
        var frames: Int
        var tiling: AssetTiling

        var description: String { "\(key) \(width)x\(height) ×\(frames) \(tiling)" }
    }

    /// 本 spec 开始前 `AssetCatalog.all` 的取值，按清单顺序排列。
    static let expectedCatalog: [Snapshot] = {
        var rows: [Snapshot] = []
        let states: [(String, Int)] = [
            ("idle", 4), ("walking", 6), ("carrying", 6), ("waiting", 4), ("falling", 2), ("hanging", 2),
            ("climbing", 4), ("planting", 6), ("celebrating", 6), ("sitting", 2), ("sleeping", 4), ("running", 6),
        ]
        for resident in ["resident_a", "resident_b"] {
            for (state, frames) in states {
                rows.append(Snapshot(key: "\(resident)_\(state)", width: 32, height: 32, frames: frames, tiling: .none))
            }
        }
        for stage in ["pot", "sprout", "bloom"] {
            rows.append(Snapshot(key: "flower_\(stage)", width: 20, height: 24, frames: 1, tiling: .none))
        }
        rows.append(Snapshot(key: "fruit", width: 16, height: 16, frames: 1, tiling: .none))
        rows.append(Snapshot(key: "plank", width: 16, height: 6, frames: 1, tiling: .horizontal))
        rows.append(Snapshot(key: "ladder", width: 16, height: 16, frames: 1, tiling: .vertical))
        rows.append(Snapshot(key: "toolbox", width: 72, height: 40, frames: 1, tiling: .none))
        for icon in ["wish", "dots", "question", "heart", "chair", "lamp", "flag", "flower", "zzz", "footprints"] {
            rows.append(Snapshot(key: "bubble_\(icon)", width: 24, height: 24, frames: 1, tiling: .none))
        }
        rows.append(Snapshot(key: "decor_chair", width: 24, height: 24, frames: 1, tiling: .none))
        rows.append(Snapshot(key: "decor_lamp_off", width: 16, height: 32, frames: 1, tiling: .none))
        rows.append(Snapshot(key: "decor_lamp_on", width: 16, height: 32, frames: 1, tiling: .none))
        rows.append(Snapshot(key: "visit_flag", width: 16, height: 24, frames: 1, tiling: .none))
        return rows
    }()

    @Test func assetCatalogMatchesPreSpecSnapshot() {
        #expect(Self.expectedCatalog.count == 45)
        let actual = AssetCatalog.all.map {
            Snapshot(key: $0.key, width: $0.size.width, height: $0.size.height, frames: $0.frames, tiling: $0.tiling)
        }
        #expect(actual.count == Self.expectedCatalog.count)
        for (expected, got) in zip(Self.expectedCatalog, actual) {
            #expect(got == expected)
        }
        #expect(AssetCatalog.pixelScale == 2)
    }

    // MARK: - Package.swift 依赖（R9.6）

    /// 取出 `.target(name: "<name>"` 或 `.executableTarget(name: "<name>"` 开始、到配对右括号为止的声明文本。
    static func targetDeclaration(named name: String, in manifest: String) -> String? {
        for kind in [".target", ".executableTarget"] {
            guard let start = manifest.range(of: "\(kind)(name: \"\(name)\"") else { continue }
            var depth = 0
            // 从 `(` 开始做括号配对。
            var index = manifest[start.lowerBound...].firstIndex(of: "(")!
            while index < manifest.endIndex {
                let ch = manifest[index]
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 { return String(manifest[start.lowerBound...index]) }
                }
                index = manifest.index(after: index)
            }
        }
        return nil
    }

    /// 声明中所有带引号的名字，例如 `"WindowfolkCore"`。
    static func quotedNames(in text: String) -> [String] {
        text.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    }

    @Test func targetDeclarationParserExtractsWholeDeclaration() {
        let manifest = """
        .target(name: "A", dependencies: ["B", .product(name: "P", package: "p")]),
        .target(name: "B"),
        """
        #expect(Self.targetDeclaration(named: "A", in: manifest)
                == #".target(name: "A", dependencies: ["B", .product(name: "P", package: "p")])"#)
        #expect(Self.targetDeclaration(named: "B", in: manifest) == #".target(name: "B")"#)
        #expect(Self.targetDeclaration(named: "C", in: manifest) == nil)
    }

    @Test func pipelineTargetsDependOnlyOnLocalTargets() throws {
        let manifest = try String(contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let expected: [String: Set<String>] = [
            "WindowfolkArtKit": ["WindowfolkCore"],
            "WindowfolkArtIO": ["WindowfolkArtKit"],
            "windowfolk-art": ["WindowfolkArtKit", "WindowfolkArtIO"],
        ]
        let localTargets: Set<String> = ["WindowfolkCore", "WindowfolkArtKit", "WindowfolkArtIO"]
        for target in Self.pipelineTargets {
            let declaration = try #require(Self.targetDeclaration(named: target, in: manifest),
                                           "Package.swift 中找不到 target \(target)")
            #expect(!declaration.contains(".product("), "\(target) 依赖了外部包产品")
            #expect(!declaration.contains("package:"), "\(target) 依赖了外部包")
            let dependencies = Set(Self.quotedNames(in: declaration).dropFirst())  // 第一个是 target 名
            #expect(dependencies.isSubset(of: localTargets), "\(target) 依赖 \(dependencies)")
            #expect(dependencies == expected[target], "\(target) 依赖 \(dependencies)")
        }
    }

    // MARK: - .gitignore（R5.7）

    @Test func gitignoreExcludesArtWorkDirectory() throws {
        let gitignore = try String(contentsOf: Self.packageRoot.appendingPathComponent(".gitignore"), encoding: .utf8)
        let lines = gitignore.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("art/work/"))
    }
}
