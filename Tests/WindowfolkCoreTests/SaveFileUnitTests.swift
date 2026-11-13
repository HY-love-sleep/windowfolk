import Foundation
import Testing
@testable import WindowfolkCore

// 任务 16.1：SaveFile 与 SaveCodec 的单元测试。往返属性测试见任务 16.4（PersistenceTests.swift）。
// V2 任务 10.1：格式版本 2（居民新字段、chair / lamp、wishBook）。

private func sample() -> SaveFile {
    let planted = SaveTime.normalized(Date(timeIntervalSince1970: 1_792_499_900.123))
    return SaveFile(
        savedAt: SaveTime.normalized(Date(timeIntervalSince1970: 1_792_500_000.5)),
        story: SavedStory(stage: .growing, round: 3, doneAt: nil),
        residents: [
            SavedResident(id: .b, x: 1180.5, heldItem: SavedHeldItem(id: UUID().uuidString, kind: .fruit),
                          walkDistance: 220),
            SavedResident(id: .a, x: 412, heldItem: nil, walkDistance: 1530.5, lastWishEndedAt: planted),
        ],
        groundObjects: [
            SavedObject(id: "plank:7", kind: .plank, x: 800),
            SavedObject(id: UUID().uuidString, kind: .flower, x: 1175,
                        flower: SavedFlower(storyRound: 3, plantedAt: planted, reached: .sprout)),
            SavedObject(id: "ladder:2", kind: .ladder, x: 640),
            SavedObject(id: "3", kind: .chair, x: 640),
            SavedObject(id: "4", kind: .lamp, x: 702),
        ],
        wishBook: SavedWishBook(
            unlockedDecor: [.lamp, .chair, .lamp], flowerCount: 3, lastFlowerDoneAt: nil,
            activeWishes: [
                SavedWish(type: .visit, wisher: .b, createdAt: planted, visitTargetApp: "Notes"),
                SavedWish(type: .chair, wisher: .a, createdAt: planted, visitTargetApp: "ignored"),
            ])
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
        #expect(obj["version"] as? Int == 2)
        let story = try #require(obj["story"] as? [String: Any])
        #expect(story["stage"] is NSNull)
        #expect(story["doneAt"] is NSNull)
        #expect(story["round"] as? Int == 1)
        let residents = try #require(obj["residents"] as? [[String: Any]])
        #expect(residents[0]["id"] as? String == "resident_a")
        #expect(residents[0]["heldItem"] is NSNull)
        #expect(residents[0]["walkDistance"] as? Double == 1530.5)
        #expect(residents[1]["lastWishEndedAt"] is NSNull)
        let book = try #require(obj["wishBook"] as? [String: Any])
        #expect(book["unlockedDecor"] as? [String] == ["chair", "lamp"])
        #expect(book["flowerCount"] as? Int == 3)
        #expect(book["lastFlowerDoneAt"] is NSNull)
        let wishes = try #require(book["activeWishes"] as? [[String: Any]])
        #expect(wishes.map { $0["type"] as? String } == ["chair", "visit"])
        #expect(wishes[0]["visitTargetApp"] is NSNull)
        #expect(wishes[1]["visitTargetApp"] as? String == "Notes")
        let objects = try #require(obj["groundObjects"] as? [[String: Any]])
        let flower = try #require(objects.first { $0["kind"] as? String == "flower" })
        let fg = try #require(flower["flower"] as? [String: Any])
        #expect(fg["reached"] as? String == "sprout")
        #expect(fg["storyRound"] as? Int == 3)
        #expect((fg["plantedAt"] as? Double).map { abs($0 - 1_792_499_900.123) < 1e-6 } == true)
    }

    @Test func versionMismatchThrows() throws {
        for v in [1, 3] {
            var s = sample()
            s.version = v
            let d = try SaveCodec.encode(s)
            #expect(throws: SaveCodecError.versionMismatch(found: v)) { try SaveCodec.decode(d) }
        }
    }

    /// v1 格式的存档（没有 v2 字段）按版本不符处理，不做迁移（V2 Requirement 15.5）。
    @Test func v1SaveIsVersionMismatch() {
        let text = """
        {"version":1,"savedAt":1792500000,"story":{"stage":null,"round":1,"doneAt":null},
         "residents":[{"id":"resident_a","x":10,"heldItem":null}],"groundObjects":[]}
        """
        #expect(throws: SaveCodecError.versionMismatch(found: 1)) { try SaveCodec.decode(Data(text.utf8)) }
    }

    /// `unlockedDecor` 丢弃未知值并去重排序；`activeWishes` 跳过未知类型和 chase，按 (createdAt, wisher) 排序
    /// （V2 Requirement 1.9、15.11）。
    @Test func wishBookDecodingIsLossy() throws {
        let text = """
        {"version":2,"savedAt":1792500000,"story":{"stage":null,"round":1,"doneAt":null},
         "residents":[],"groundObjects":[{"id":"9","kind":"lamp","x":5},{"id":"8","kind":"sofa","x":6}],
         "wishBook":{"unlockedDecor":["lamp","sofa","chair","lamp",""],"flowerCount":2,
           "lastFlowerDoneAt":1792499000,
           "activeWishes":[
             {"type":"lamp","wisher":"resident_b","createdAt":1792499900,"visitTargetApp":null},
             {"type":"chase","wisher":"resident_a","createdAt":1792499800,"visitTargetApp":null},
             {"type":"dance","wisher":"resident_a","createdAt":1792499700},
             {"type":"chair","wisher":"resident_a","createdAt":1792499900}]}}
        """
        let s = try SaveCodec.decode(Data(text.utf8))
        #expect(s.groundObjects == [SavedObject(id: "9", kind: .lamp, x: 5)])
        #expect(s.wishBook.unlockedDecor == [.chair, .lamp])
        #expect(s.wishBook.flowerCount == 2)
        #expect(s.wishBook.lastFlowerDoneAt == Date(timeIntervalSince1970: 1_792_499_000))
        let t = Date(timeIntervalSince1970: 1_792_499_900)
        #expect(s.wishBook.activeWishes == [
            SavedWish(type: .chair, wisher: .a, createdAt: t),
            SavedWish(type: .lamp, wisher: .b, createdAt: t),
        ])
    }

    /// 已知类型但内容不合法的 Wish 不跳过，整份存档按损坏处理。
    @Test func visitWishWithoutAppIsInvalid() {
        let text = """
        {"version":2,"savedAt":1792500000,"story":{"stage":null,"round":1,"doneAt":null},
         "residents":[],"groundObjects":[],
         "wishBook":{"unlockedDecor":[],"flowerCount":0,"lastFlowerDoneAt":null,
           "activeWishes":[{"type":"visit","wisher":"resident_a","createdAt":1792499900,"visitTargetApp":null}]}}
        """
        #expect {
            try SaveCodec.decode(Data(text.utf8))
        } throws: { e in
            if case SaveCodecError.invalidData = e { return true }
            return false
        }
    }

    /// 直接构造时也不保留 Chase_Wish（V2 Requirement 15.11）。
    @Test func wishBookDropsChaseOnInit() {
        let t = Date(timeIntervalSince1970: 1_792_499_900)
        let book = SavedWishBook(activeWishes: [
            SavedWish(type: .chase, wisher: .a, createdAt: t),
            SavedWish(type: .flower, wisher: .b, createdAt: t),
        ])
        #expect(book.activeWishes == [SavedWish(type: .flower, wisher: .b, createdAt: t)])
    }

    @Test func garbageThrowsInvalidData() {
        for bytes in [Data("not json".utf8), Data("{}".utf8), Data("{\"version\":2}".utf8)] {
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
        {"version":2,"savedAt":1792500000,"story":{"stage":"done","round":2,"doneAt":1792499000},
         "residents":[{"id":"resident_a","x":10,"heldItem":{"id":"x","kind":"balloon"},"walkDistance":0}],
         "groundObjects":[{"id":"a","kind":"balloon","x":1},{"id":"b","kind":"plank","x":2}],
         "wishBook":{"unlockedDecor":[],"flowerCount":2,"lastFlowerDoneAt":null,"activeWishes":[]}}
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
