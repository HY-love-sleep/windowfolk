import Foundation
import Testing

/// Requirement 27.2: WindowfolkCore must not depend on AppKit or SpriteKit.
@Suite struct ArchitectureTests {
    static let forbiddenModules = ["AppKit", "SpriteKit"]

    /// `Sources/WindowfolkCore`, located relative to this test file.
    static var coreSourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WindowfolkCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/WindowfolkCore", isDirectory: true)
    }

    static func swiftFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// Returns the module name if `line` is an import declaration, covering forms such as
    /// `import AppKit`, `@testable import AppKit`, `import class AppKit.NSView`, `import AppKit.NSView`.
    static func importedModule(in line: String) -> String? {
        var tokens = line.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        while let first = tokens.first, first.hasPrefix("@") { tokens.removeFirst() }
        guard tokens.first == "import", tokens.count >= 2 else { return nil }
        tokens.removeFirst()
        let kinds: Set<String> = ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"]
        if let kind = tokens.first, kinds.contains(kind), tokens.count >= 2 { tokens.removeFirst() }
        return tokens.first?.split(separator: ".").first.map(String.init)
    }

    @Test func importParserRecognizesForbiddenForms() {
        #expect(Self.importedModule(in: "import AppKit") == "AppKit")
        #expect(Self.importedModule(in: "  @testable import SpriteKit") == "SpriteKit")
        #expect(Self.importedModule(in: "import class AppKit.NSView") == "AppKit")
        #expect(Self.importedModule(in: "import Foundation") == "Foundation")
        #expect(Self.importedModule(in: "// import AppKit") == nil)
        #expect(Self.importedModule(in: "let x = 1") == nil)
    }

    @Test func coreDoesNotImportAppKitOrSpriteKit() throws {
        let files = Self.swiftFiles(in: Self.coreSourcesDirectory)
        #expect(!files.isEmpty, "No .swift files found in \(Self.coreSourcesDirectory.path)")

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                guard let module = Self.importedModule(in: line) else { continue }
                #expect(
                    !Self.forbiddenModules.contains(module),
                    "\(file.lastPathComponent):\(index + 1) imports \(module)"
                )
            }
        }
    }
}
