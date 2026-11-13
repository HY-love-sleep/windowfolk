import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 10.4：`SaveSnapshot` 的 v2 保存与恢复（Decor、居民新字段、wishBook、Wish 恢复规则）。
/// 屏幕 1440×900，Ground y = 825。
struct PersistenceV2UnitTests {
    typealias H = PersistenceUnitTests.Harness
    static let t0 = PersistenceUnitTests.t0
    static let groundY = 825.0

    static func win(_ id: WindowID, _ name: String, x: Double, y: Double, z: Int) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: name, ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: 200, height: 200), zIndex: z)
    }

    /// 窗口 1（最左）和窗口 5（最右）成为 Home_Window；窗口 1 的应用名称也是 Notes 且层级最靠前。
    static let windows = [
        win(1, "Notes", x: 0, y: 400, z: 0),
        win(3, "Notes", x: 400, y: 300, z: 3),
        win(4, "Notes", x: 700, y: 300, z: 1),
        win(5, "Safari", x: 1200, y: 400, z: 2),
    ]

    static func save(
        residents: [SavedResident] = [SavedResident(id: .a, x: 100), SavedResident(id: .b, x: 1300)],
        objects: [SavedObject] = [], book: SavedWishBook = SavedWishBook(),
        story: SavedStory = SavedStory(stage: nil, round: 1, doneAt: nil)
    ) -> SaveFile {
        SaveFile(savedAt: t0, story: story, residents: residents, groundObjects: objects, wishBook: book)
    }

    // MARK: - snapshot

    @Test func snapshotWritesDecorResidentFieldsAndWishBook() throws {
        let h = H([PersistenceUnitTests.win(1, x: 100, y: 400), PersistenceUnitTests.win(2, x: 400, y: 380)])
        h.step()
        h.engine.insertDecor(Decor(id: DecorID(1), type: .chair, placement: .attached(.window(2, offset: 30))))
        h.engine.insertDecor(Decor(id: DecorID(2), type: .lamp, placement: .attached(.ground(x: 900))))
        h.engine.unlockDecor(.lamp)
        h.engine.unlockDecor(.chair)
        h.step()
        // 隐藏窗口 2：其上的 Chair 按最后可见快照取 x（400 + 30）。
        h.source.hide(2)
        h.step()

        var world = h.engine.state
        var a = Resident(id: .a, attachment: .ground(x: 200))
        a.walkDistance = 1530.5
        world.residents = [.a: a, .b: Resident(id: .b, attachment: .ground(x: 600))]
        // 下落中的 Decor 取下落 x；拖动中的 Decor 取指针减抓取偏移。
        world.decors.decors[DecorID(3)] = Decor(
            id: DecorID(3), type: .lamp,
            placement: .falling(FallState(position: Point(x: 321, y: 100), velocityY: 0), byPlayer: true))
        world.decors.decors[DecorID(4)] = Decor(
            id: DecorID(4), type: .chair, placement: .dragged(grabOffset: Point(x: 3, y: -5), fresh: false))
        world.gesture = .dragging(.decor(DecorID(4)), grabOffset: Point(x: 3, y: -5), pointer: Point(x: 500, y: 300))
        let ended = Date(timeIntervalSince1970: 1_799_999_000.123_4)
        world.wishes = WishBook(
            active: [Wish(id: WishID(1), type: .visit, wisher: .b, createdAt: Self.t0,
                          visitTarget: VisitTarget(window: 1, ownerName: "备忘录"))],
            lastEnded: [.a: ended], flowerCount: 3, lastFlowerDoneAt: ended)

        let s = SaveSnapshot.snapshot(world: world, now: Self.t0)
        let decors = s.groundObjects.filter { $0.kind == .chair || $0.kind == .lamp }
        #expect(decors.map(\.id) == ["decor:1", "decor:2", "decor:3", "decor:4"])
        #expect(decors.map(\.kind) == [.chair, .lamp, .lamp, .chair])
        #expect(decors.map(\.x) == [430, 900, 321, 497])

        let sa = try #require(s.residents.first { $0.id == .a })
        #expect(sa.walkDistance == 1530.5 && sa.lastWishEndedAt == SaveTime.normalized(ended))
        #expect(s.residents.first { $0.id == .b }?.lastWishEndedAt == nil)
        #expect(s.wishBook.unlockedDecor == [.chair, .lamp])
        #expect(s.wishBook.flowerCount == 3)
        #expect(s.wishBook.lastFlowerDoneAt == SaveTime.normalized(ended))
        #expect(s.wishBook.activeWishes == [SavedWish(type: .visit, wisher: .b, createdAt: Self.t0,
                                                      visitTargetApp: "备忘录")])
        #expect(try SaveCodec.decode(SaveCodec.encode(s)) == s)
    }

    /// 追逐中保存：不写 Chase_Wish，两位居民的上一个 Wish 结束时间是追逐开始前的值（Requirement 15.11）。
    @Test func snapshotDuringChaseKeepsPreChaseCooldown() {
        var world = WorldState(screen: PersistenceUnitTests.screen)
        world.residents = [.a: Resident(id: .a, attachment: .ground(x: 100)),
                           .b: Resident(id: .b, attachment: .ground(x: 600))]
        let before = Self.t0.addingTimeInterval(-500)
        world.wishes = WishBook(
            active: [Wish(id: WishID(1), type: .chase, wisher: .a, createdAt: Self.t0,
                          chase: ChaseState(phase: .running, readyAt: Self.t0, runningAt: Self.t0))],
            lastEnded: [.b: before])
        let s = SaveSnapshot.snapshot(world: world, now: Self.t0.addingTimeInterval(10))
        #expect(s.wishBook.activeWishes.isEmpty)
        #expect(s.residents.first { $0.id == .a }?.lastWishEndedAt == nil)
        #expect(s.residents.first { $0.id == .b }?.lastWishEndedAt == before)
    }

    // MARK: - restore

    /// Decor 从上方落到 Ground 上夹紧后的保存 x（即使正下方有窗沿），不写 `decor_placed` 和 `decor_unlocked`；
    /// Walk_Distance 原样恢复，居民不处于 sitting、sleeping、running（Requirement 1.8、15.2、15.10）。
    @Test func restoreDropsDecorToGroundSilently() throws {
        let s = Self.save(
            residents: [SavedResident(id: .a, x: 100, walkDistance: 2100),
                        SavedResident(id: .b, x: 1300, walkDistance: 0)],
            objects: [SavedObject(id: "decor:7", kind: .chair, x: 100),
                      SavedObject(id: "decor:8", kind: .lamp, x: 5000)],
            book: SavedWishBook(unlockedDecor: [.lamp, .chair]))
        let h = H(Self.windows, story: true, restored: s)
        var types = h.step()?.events.map(\.type) ?? []
        let first = h.engine.state
        #expect(first.residents.count == 2)
        #expect(first.residents.values.allSatisfy { ![.sitting, .sleeping, .running].contains($0.state) })
        #expect(first.residents[.a]?.walkDistance == 2100 && first.residents[.b]?.walkDistance == 0)
        // 恢复后按 v1 规则重新分配 Home_Window，不移动居民。
        #expect(first.story.homes == [.a: 1, .b: 5])
        for _ in 0..<89 {
            types += h.step()?.events.map(\.type) ?? []
        }
        let st = h.engine.state
        #expect(st.decors.unlocked == [.chair, .lamp])
        let placements = st.decors.sortedIDs.map { st.decors.decors[$0]!.placement }
        #expect(placements == [.attached(.ground(x: 100)),
                               .attached(.ground(x: PersistenceUnitTests.screen.frame.maxX))])
        #expect(h.engine.restoreLanding.isEmpty)
        #expect(!types.contains(.decorPlaced) && !types.contains(.decorUnlocked))
    }

    /// Wish 恢复：未超时的 Chair_Wish 恢复且创建时间不变；超时的 Lamp_Wish 放弃，Wisher 冷却从恢复时刻起算，
    /// 写一条 `wish_dropped`（Requirement 15.3、15.8、18.2）。
    @Test func restoreKeepsFreshWishesAndDropsTimedOutOnes() throws {
        let c = Tunables()
        let fresh = Self.t0.addingTimeInterval(-(c.wishTimeout - 60))
        let stale = Self.t0.addingTimeInterval(-c.wishTimeout)
        let s = Self.save(book: SavedWishBook(unlockedDecor: [.chair], activeWishes: [
            SavedWish(type: .chair, wisher: .a, createdAt: fresh),
            SavedWish(type: .lamp, wisher: .b, createdAt: stale),
        ]))
        let h = H(Self.windows, story: true, restored: s)
        let out = try #require(h.step())
        let book = h.engine.state.wishes
        #expect(book.active.map(\.type) == [.chair])
        #expect(book.active.first?.wisher == .a && book.active.first?.createdAt == fresh)
        #expect(book.lastEnded[.b] == h.now && book.lastEnded[.a] == nil)
        let drops = out.events.filter { $0.type == .wishDropped }
        #expect(drops.count == 1)
        #expect(drops.first?.actor == EventRecord.residentRef(.b) && drops.first?.target == nil)
        #expect(!out.events.contains { $0.type == .wishStarted || $0.type == .decorUnlocked })
    }

    /// Visit_Target 按应用名称匹配，排除 Home_Window，取 zIndex 最小；找不到时放弃（Requirement 15.4）。
    @Test func restoreMatchesVisitTargetByAppName() throws {
        let s = Self.save(book: SavedWishBook(activeWishes: [
            SavedWish(type: .visit, wisher: .a, createdAt: Self.t0, visitTargetApp: "Notes"),
            SavedWish(type: .visit, wisher: .b, createdAt: Self.t0, visitTargetApp: "Mail"),
        ]))
        let h = H(Self.windows, story: true, restored: s)
        let out = try #require(h.step())
        let book = h.engine.state.wishes
        #expect(book.active.count == 1)
        #expect(book.active.first?.visitTarget == VisitTarget(window: 4, ownerName: "Notes"))
        #expect(book.lastEnded[.b] == h.now)
        let drop = try #require(out.events.first { $0.type == .wishDropped })
        #expect(drop.actor == EventRecord.residentRef(.b) && drop.target == EventRecord.appRef("Mail"))
    }

    /// Flower_Wish 不受 Wish_Timeout 约束；保存的冷却起点原样恢复，冷却未满前不生成新 Wish（Requirement 15.3、15.9）。
    @Test func restoreFlowerUnconditionallyAndCooldownFromSavedTime() throws {
        let c = Tunables()
        let old = Self.t0.addingTimeInterval(-c.wishTimeout * 3)
        let lastEnded = Self.t0.addingTimeInterval(-60)
        let s = Self.save(
            residents: [SavedResident(id: .a, x: 100), SavedResident(id: .b, x: 1300, lastWishEndedAt: lastEnded)],
            book: SavedWishBook(flowerCount: 2, activeWishes: [SavedWish(type: .flower, wisher: .b, createdAt: old)]),
            story: SavedStory(stage: .growing, round: 2, doneAt: nil))
        let h = H(Self.windows, story: true, restored: s)
        h.step()
        var book = h.engine.state.wishes
        #expect(book.active.map(\.type) == [.flower])
        #expect(book.active.first?.wisher == .b && book.active.first?.createdAt == old)
        #expect(book.flowerCount == 2 && h.engine.state.story.round == 2)
        #expect(book.lastEnded[.b] == lastEnded)
        book.active = []
        #expect(!WishDirector.cooledDown(.b, book: book, now: h.now, constants: c))
        #expect(WishDirector.cooledDown(.b, book: book, now: lastEnded.addingTimeInterval(c.wishCooldown),
                                        constants: c))
    }
}
