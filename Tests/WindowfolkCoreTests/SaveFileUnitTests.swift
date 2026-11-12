import Foundation
import Testing
@testable import WindowfolkCore

// 任务 16.1：SaveFile 与 SaveCodec 的单元测试。往返属性测试见任务 16.4（PersistenceTests.swift）。

private func sample() -> SaveFile {
    let planted = SaveTime.normalized(Date(timeIntervalSince1970: 1_792_499_900.123))
    return SaveFile(
        savedAt: SaveTime.normalized(Date(timeIntervalSince1970: 1_792_500_000.5)),
        story: SavedStory(stage: .growing, round: 3, doneAt: nil),
        residents: [
            SavedResident(id: .b, x: 1180.5, heldItem: SavedHeldItem(id: UUID().uuidString, kind: .fruit)),
            SavedResident(id: .a, x: 412, heldItem: nil),
        ],
        groundObjects: [
            SavedObject(id: "plank:7", kind: .plank, x: 800),
            SavedObject(id: UUID().uuidString, kind: .flower, x: 1175,
                        flower: SavedFlower(storyRound: 3, plantedAt: planted, reached: .sprout)),
            SavedObject(id: "ladder:2", kind: .ladder, x: 640),
        ]
    )
}

private func json(_ d: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: d) as? [String: Any])
}

@Suite struct SaveFileUnitTests {
    @Test func roundTripsAndSortsByID() throws {
        let s = sample()
        #expect(s.residents.map(\.id) == [.a, .b])
        #expect(s.groundObjects.map(\.id) == s.groundObjects.map(\.id).sorted())
        #expect(try SaveCodec.decode(SaveCodec.encode(s)) == s)
    }

    @Test func encodesRequiredFieldsWithExplicitNulls() throws {
        var s = sample()
        s.story = SavedStory(stage: nil, round: 1, doneAt: nil)
        let obj = try json(SaveCodec.encode(s))
        #expect(obj["version"] as? Int == 1)
        let story = try #require(obj["story"] as? [String: Any])
        #expect(story["stage"] is NSNull)
        #expect(story["doneAt"] is NSNull)
        #expect(story["round"] as? Int == 1)
        let residents = try #require(obj["residents"] as? [[String: Any]])
        #expect(residents[0]["id"] as? String == "resident_a")
        #expect(residents[0]["heldItem"] is NSNull)
        let objects = try #require(obj["groundObjects"] as? [[String: Any]])
        let flower = try #require(objects.first { $0["kind"] as? String == "flower" })
        let fg = try #require(flower["flower"] as? [String: Any])
        #expect(fg["reached"] as? String == "sprout")
        #expect(fg["storyRound"] as? Int == 3)
        #expect((fg["plantedAt"] as? Double).map { abs($0 - 1_792_499_900.123) < 1e-6 } == true)
    }

    @Test func versionMismatchThrows() throws {
        var s = sample()
        s.version = 2
        let d = try SaveCodec.encode(s)
        #expect(throws: SaveCodecError.versionMismatch(found: 2)) { try SaveCodec.decode(d) }
    }

    @Test func garbageThrowsInvalidData() {
        for bytes in [Data("not json".utf8), Data("{}".utf8), Data("{\"version\":1}".utf8)] {
            #expect {
                try SaveCodec.decode(bytes)
            } throws: { e in
                if case SaveCodecError.invalidData = e { return true }
                return false
            }
        }
    }

    @Test func unknownObjectKindsAreSkipped() throws {
        let text = """
        {"version":1,"savedAt":1792500000,"story":{"stage":"done","round":2,"doneAt":1792499000},
         "residents":[{"id":"resident_a","x":10,"heldItem":{"id":"x","kind":"balloon"}}],
         "groundObjects":[{"id":"a","kind":"balloon","x":1},{"id":"b","kind":"plank","x":2}]}
        """
        let s = try SaveCodec.decode(Data(text.utf8))
        #expect(s.story.stage == .done)
        #expect(s.story.doneAt == Date(timeIntervalSince1970: 1_792_499_000))
        #expect(s.residents.first?.heldItem == nil)
        #expect(s.groundObjects == [SavedObject(id: "b", kind: .plank, x: 2)])
    }

    @Test func persistedStageMapsShortStages() {
        #expect(SavedStory.persistedStage(.planting) == .travel)
        #expect(SavedStory.persistedStage(.bloomed) == .returnGift)
        #expect(SavedStory.persistedStage(nil) == nil)
        for st in StoryStage.allCases where st != .planting && st != .bloomed {
            #expect(SavedStory.persistedStage(st) == st)
        }
    }

    @Test func normalizedTimeIsStable() throws {
        for t in [0.0, 1_792_500_000.123456, 1_000_000_000.9999, -12.3456] {
            let n = SaveTime.normalized(Date(timeIntervalSince1970: t))
            #expect(SaveTime.normalized(n) == n)
            let s = SaveFile(savedAt: n, story: SavedStory(stage: .done, round: 1, doneAt: n),
                             residents: [], groundObjects: [])
            #expect(try SaveCodec.decode(SaveCodec.encode(s)) == s)
        }
    }
}
