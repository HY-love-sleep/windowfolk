import Foundation
import Testing
@testable import WindowfolkCore

/// FileSaveStore 的文件读写（任务 16.3，Requirement 1.10、22.5、22.11、22.12、27.6）。
/// 只使用临时目录，不访问 `~/Library/Application Support/Windowfolk/`。
@Suite struct FileSaveStoreUnitTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-save-\(UUID().uuidString)", isDirectory: true)
    }

    private func sample() -> SaveFile {
        SaveFile(savedAt: Date(timeIntervalSince1970: 1_792_500_000),
                 story: SavedStory(stage: .growing, round: 3, doneAt: nil),
                 residents: [], groundObjects: [])
    }

    private func backups(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("world.corrupt-") }
    }

    @Test func missingFileReportsMissing() {
        let store = FileSaveStore(directory: tempDir())
        #expect(store.loadSave() == .missing)
    }

    @Test func saveCreatesDirectoryAndRoundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSaveStore(directory: dir)
        #expect(store.save(sample()))
        #expect(store.loadSave() == .loaded(sample()))
    }

    @Test func corruptFileIsBackedUpWithContentKept() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileSaveStore(directory: dir)
        let garbage = Data("{not json".utf8)
        try garbage.write(to: store.fileURL)

        guard case let .corrupt(backup?) = store.loadSave() else {
            Issue.record("expected corrupt with backup"); return
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(try Data(contentsOf: backup) == garbage)
        #expect(backup.lastPathComponent.range(of: #"^world\.corrupt-\d{8}-\d{6}(-\d+)?\.json$"#,
                                               options: .regularExpression) != nil)
        // 备份后再次读取按首次开局处理。
        #expect(store.loadSave() == .missing)
    }

    @Test func versionMismatchIsBackedUp() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSaveStore(directory: dir)
        var file = sample()
        file.version = SaveCodec.currentVersion + 1
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 用其他版本号写一份结构完整的存档。
        try SaveCodec.encode(file).write(to: store.fileURL)

        guard case .corrupt = store.loadSave() else { Issue.record("expected corrupt"); return }
        #expect(backups(in: dir).count == 1)
    }

    @Test func repeatedBackupsInSameSecondDoNotOverwrite() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileSaveStore(directory: dir)
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        try Data("a".utf8).write(to: store.fileURL)
        _ = store.loadSave(now: now)
        try Data("b".utf8).write(to: store.fileURL)
        _ = store.loadSave(now: now)
        #expect(backups(in: dir).count == 2)
    }

    @Test func failedWriteLeavesOriginalIntact() throws {
        let dir = tempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = FileSaveStore(directory: dir)
        #expect(store.save(sample()))
        let before = try Data(contentsOf: store.fileURL)

        // 目录只读：原子写入无法创建临时文件。
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        var other = sample()
        other.story.round = 9
        #expect(!store.save(other))
        #expect(try Data(contentsOf: store.fileURL) == before)
    }
}
