import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 16.2：世界快照与恢复（SaveSnapshot、WorldEngine.init(restored:)、WorldEngine.makeSave）。
struct PersistenceUnitTests {
    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    static let dt = 1.0 / 30
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func win(_ id: WindowID, x: Double, y: Double, w: Double = 200, h: Double = 200, z: Int = 0)
        -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now: Date

        init(_ windows: [WindowSnapshot], story: Bool = false, restored: SaveFile? = nil,
             now: Date = PersistenceUnitTests.t0) {
            self.now = now
            engine = WorldEngine(clockStart: now, screen: PersistenceUnitTests.screen, rng: RandomSource(seed: 7),
                                 demoResident: false, story: story, restored: restored)
            source = FakeWindowSource(snapshots: windows)
        }

        @discardableResult
        func step(_ n: Int = 1) -> StepOutput? {
            step([], n)
        }

        /// 第一帧带上 `commands`。
        @discardableResult
        func step(_ commands: [Command], _ n: Int = 1) -> StepOutput? {
            var out: StepOutput?
            for i in 0..<n {
                now = now.addingTimeInterval(PersistenceUnitTests.dt)
                out = engine.step(FrameInput(poll: source.poll(), screen: PersistenceUnitTests.screen,
                                             commands: i == 0 ? commands : [], now: now))
                #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())")
            }
            return out
        }
    }

    // MARK: - snapshot

    @Test func snapshotNormalizesObjectsToGroundAndKeepsHeldItemsWithResidents() throws {
        let h = Harness([Self.win(1, x: 100, y: 400), Self.win(2, x: 400, y: 380), Self.win(3, x: 800, y: 700)])
        h.step()
        let e = h.engine
        e.place(Resident(id: .a, attachment: .window(1, offset: 50)))
        e.place(Resident(id: .b, attachment: .ground(x: 900)))
        let planted = Date(timeIntervalSince1970: 1_799_999_000.123_4)
        let held = Item(kind: .flower(storyRound: 1), placement: .held(.a),
                        growth: FlowerGrowth(plantedAt: nil, reached: .pot))
        e.give(held, to: .a)
        let onLedge = Item(kind: .flower(storyRound: 1), placement: .attached(.window(2, offset: 30)),
                           growth: FlowerGrowth(plantedAt: planted, reached: .sprout))
        e.insertItem(onLedge)
        let fruit = Item.fruit(placement: .attached(.ground(x: 700)))
        e.insertItem(fruit)
        e.insertPlank(.placed(PlacedPlank(id: PlankID(0), endA: PlankEnd(window: 1, offset: 190),
                                          endB: PlankEnd(window: 2, offset: 10))))
        e.insertLadder(.placed(PlacedLadder(id: LadderID(0), top: PlankEnd(window: 3, offset: 100),
                                            bottomSurface: .ground, bottom: Point(x: 900, y: 825))))
        h.step()

        #expect(e.state.ladders.placedLadders.count == 1)
        #expect(e.state.planks.placedPlanks.count == 1)
        // 隐藏窗口 2：其上的物件和木板端点按最后可见快照取 x。
        h.source.hide(2)
        h.step()
        let save = e.makeSave()

        #expect(save.version == SaveCodec.currentVersion)
        #expect(save.residents.map(\.id) == [.a, .b])
        let a = try #require(save.residents.first { $0.id == .a })
        #expect(a.x == 150)
        #expect(a.heldItem?.id == held.id.rawValue.uuidString)
        #expect(a.heldItem?.kind == .flower)
        #expect(save.residents.first { $0.id == .b }?.x == 900)

        #expect(!save.groundObjects.contains { $0.id == held.id.rawValue.uuidString })
        let flower = try #require(save.groundObjects.first { $0.id == onLedge.id.rawValue.uuidString })
        #expect(flower.kind == .flower && flower.x == 430)
        #expect(flower.flower?.plantedAt == SaveTime.normalized(planted))
        #expect(flower.flower?.reached == .sprout && flower.flower?.storyRound == 1)
        #expect(save.groundObjects.first { $0.id == fruit.id.rawValue.uuidString }?.x == 700)
        let plank = try #require(save.groundObjects.first { $0.kind == .plank })
        #expect(plank.x == (290 + 410) / 2)
        let ladder = try #require(save.groundObjects.first { $0.kind == .ladder })
        #expect(ladder.x == 900)
        #expect(save.groundObjects.count == 4)

        // 往返精确相等。
        #expect(try SaveCodec.decode(SaveCodec.encode(save)) == save)
    }

    @Test func snapshotMapsTransientStages() {
        var world = WorldState(screen: Self.screen)
        world.residents[.a] = Resident(id: .a, attachment: .ground(x: 100))
        world.residents[.b] = Resident(id: .b, attachment: .ground(x: 300))
        world.story = StoryState(stage: .planting, round: 3)
        #expect(SaveSnapshot.snapshot(world: world, now: Self.t0).story.stage == .travel)

        world.story = StoryState(stage: .bloomed, round: 2)
        let s = SaveSnapshot.snapshot(world: world, now: Self.t0)
        #expect(s.story.stage == .returnGift)
        // 第 2 轮 Receiver 为都都，带着 Fruit。
        #expect(s.residents.first { $0.id == .a }?.heldItem?.kind == .fruit)
    }

    // MARK: - restore

    @Test func restoreDropsObjectsToGroundAndResidentsToNearestLedge() throws {
        let fruitID = UUID()
        let flowerID = UUID()
        let save = SaveFile(
            savedAt: Self.t0,
            story: SavedStory(stage: nil, round: 1, doneAt: nil),
            residents: [
                SavedResident(id: .a, x: 50),
                SavedResident(id: .b, x: 1000, heldItem: SavedHeldItem(id: fruitID.uuidString, kind: .fruit)),
            ],
            groundObjects: [
                // x 落在窗口 1 上方，但恢复时只落到 Ground 上。
                SavedObject(id: flowerID.uuidString, kind: .flower, x: 200,
                            flower: SavedFlower(storyRound: nil, plantedAt: nil, reached: .pot)),
                SavedObject(id: "p", kind: .plank, x: 5000),
                SavedObject(id: "l", kind: .ladder, x: 600),
            ])
        let h = Harness([Self.win(1, x: 100, y: 400), Self.win(2, x: 400, y: 300)], restored: save)
        #expect(h.engine.makeSave() == save)
        h.step(90)
        let st = h.engine.state
        #expect(h.engine.pendingRestore == nil)
        #expect(h.engine.restoreLanding.isEmpty)

        // 都都：保存 x 50，最近的窗沿是窗口 1 的左端（x 100）。嘟嘟：x 1000，最近的是窗口 2 右端（x 600）。
        let a = try #require(st.residents[.a])
        #expect(a.state != .falling)
        #expect(a.attachment.windowID == 1)
        let b = try #require(st.residents[.b])
        #expect(b.attachment.windowID == 2)
        #expect(b.heldItem == ItemID(fruitID))
        #expect(st.items[ItemID(fruitID)]?.placement == .held(.b))

        #expect(st.items[ItemID(flowerID)]?.placement == .attached(.ground(x: 200)))
        let planks = st.planks.planks.values
        #expect(planks.count == 1)
        #expect(planks.first == .loose(.ground(x: Self.screen.frame.maxX)))
        #expect(st.ladders.ladders.values.first == .loose(.ground(x: 600)))
    }

    @Test func restoreWithoutLedgesPutsResidentsOnGroundAtSavedX() {
        let save = SaveFile(savedAt: Self.t0, story: SavedStory(stage: nil, round: 1, doneAt: nil),
                            residents: [SavedResident(id: .a, x: 300), SavedResident(id: .b, x: 2000)],
                            groundObjects: [])
        let h = Harness([], restored: save)
        for _ in 0..<90 where h.engine.state.residents.isEmpty
            || h.engine.state.residents.values.contains(where: { $0.state == .falling }) {
            h.step()
        }
        #expect(h.engine.state.residents[.a]?.attachment == .ground(x: 300))
        #expect(h.engine.state.residents[.b]?.attachment == .ground(x: Self.screen.frame.maxX))
    }

    @Test func restoreWaitsForFirstSuccessfulPoll() {
        let save = SaveFile(savedAt: Self.t0, story: SavedStory(stage: .travel, round: 2, doneAt: nil),
                            residents: [SavedResident(id: .a, x: 300), SavedResident(id: .b, x: 600)],
                            groundObjects: [])
        let h = Harness([Self.win(1, x: 100, y: 400)], story: true, restored: save)
        h.source.failNextPoll = true
        h.step()
        #expect(h.engine.pendingRestore != nil)
        #expect(h.engine.state.residents.isEmpty)
        h.step()
        #expect(h.engine.pendingRestore == nil)
        #expect(h.engine.state.residents.count == 2)
    }

    @Test func restoreResumesStoryWithParityAndRecomputedGrowth() throws {
        let flowerID = UUID()
        // 种下 200 秒前（Bloom_Duration 180 秒）：应用未运行期间已开花。
        let planted = Self.t0.addingTimeInterval(-200)
        let save = SaveFile(
            savedAt: Self.t0.addingTimeInterval(-150),
            story: SavedStory(stage: .growing, round: 2, doneAt: nil),
            residents: [SavedResident(id: .a, x: 150), SavedResident(id: .b, x: 450)],
            groundObjects: [SavedObject(id: flowerID.uuidString, kind: .flower, x: 460,
                                        flower: SavedFlower(storyRound: 2, plantedAt: planted, reached: .sprout))])
        let h = Harness([Self.win(1, x: 100, y: 400), Self.win(2, x: 400, y: 400)], story: true, restored: save)
        h.step()
        let st = h.engine.state.story
        #expect(st.round == 2)
        #expect(st.giver == .b && st.receiver == .a)
        // V2：恢复后重新分配 Home_Window（不移动居民），进行中的送花恢复为 active Flower_Wish
        // （design.md「已确认决策 2」，v2 Requirement 15.3）。
        #expect(st.homes == [.a: 1, .b: 2])
        #expect(h.engine.state.wishes.active.map(\.type) == [.flower])
        #expect(h.engine.state.wishes.flowerCount == 2)
        #expect(st.currentFlower == ItemID(flowerID))
        #expect(h.engine.state.items[ItemID(flowerID)]?.growth?.reached == .bloom)
        // 已开花：同一次剧情更新进入 ReturnGift，Receiver（都都）带着 Fruit。
        #expect(st.stage == .returnGift)
        let fruit = try #require(h.engine.state.residents[.a]?.heldItem)
        #expect(h.engine.state.items[fruit]?.kind == .fruit)
    }

    @Test func restoreTravelGivesGiverTheSavedFlower() {
        let flowerID = UUID()
        let save = SaveFile(
            savedAt: Self.t0, story: SavedStory(stage: .travel, round: 1, doneAt: nil),
            residents: [
                SavedResident(id: .a, x: 150, heldItem: SavedHeldItem(
                    id: flowerID.uuidString, kind: .flower,
                    flower: SavedFlower(storyRound: 1, plantedAt: nil, reached: .pot))),
                SavedResident(id: .b, x: 450),
            ],
            groundObjects: [])
        let h = Harness([Self.win(1, x: 100, y: 400), Self.win(2, x: 400, y: 400)], story: true, restored: save)
        h.step()
        #expect(h.engine.state.story.currentFlower == ItemID(flowerID))
        #expect(h.engine.state.residents[.a]?.heldItem == ItemID(flowerID))
        #expect(h.engine.state.story.homes == [.a: 1, .b: 2])
    }

    /// V2：恢复的 Done 立即完成 Flower_Wish；下一次送花（嘟嘟为 Giver）是否满足条件取决于 Round_Interval
    /// 是否已满（v1 Requirement 19.7 按 v2 Requirement 8.1、8.4 调整）。
    @Test func restoreDoneStartsNextRoundWhenIntervalPassed() {
        let c = Tunables()
        func save(doneAgo: Double) -> SaveFile {
            SaveFile(savedAt: Self.t0, story: SavedStory(stage: .done, round: 1,
                                                          doneAt: Self.t0.addingTimeInterval(-doneAgo)),
                     residents: [SavedResident(id: .a, x: 150), SavedResident(id: .b, x: 450)],
                     groundObjects: [])
        }
        let wins = [Self.win(1, x: 100, y: 400), Self.win(2, x: 400, y: 400)]
        func flowerEligible(_ h: Harness) -> Bool {
            var book = h.engine.state.wishes
            book.active = []
            let ctx = WishContext(world: h.engine.state, now: h.engine.lastNow)
            return WishDirector.eligibleTypes(.b, book: book, world: h.engine.state, ctx: ctx).contains(.flower)
        }
        let past = Harness(wins, story: true, restored: save(doneAgo: c.roundInterval + 10))
        past.step()
        #expect(past.engine.state.story.stage == nil)
        #expect(past.engine.state.wishes.flowerCount == 1)
        #expect(flowerEligible(past))
        past.step([.triggerWish(.flower, nil)])
        #expect(past.engine.state.story.round == 2)
        #expect(past.engine.state.story.giver == .b)

        let pending = Harness(wins, story: true, restored: save(doneAgo: 10))
        pending.step()
        #expect(pending.engine.state.story.stage == nil)
        #expect(pending.engine.state.story.round == 1)
        #expect(!flowerEligible(pending))
    }
}
