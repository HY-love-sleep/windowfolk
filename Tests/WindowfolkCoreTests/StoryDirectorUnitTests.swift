import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 13.3：StoryDirector 剧情状态机的具体例子。
/// 用 StoryDirector.update + ResidentController.update 组成的最小循环驱动，不经过 WorldEngine（接入见任务 13.5）。
struct StoryDirectorUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    let constants = Tunables()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let dt = 1.0 / 30

    func win(_ id: WindowID, z: Int, x: Double, y: Double, w: Double = 200, h: Double = 200) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    /// 两个上沿同高、相距 100pt 的窗口；`bridged` 时在两者之间架一块木板。
    func world(_ snaps: [WindowSnapshot], bridged: Bool = false) -> WorldState {
        var w = WorldState(screen: screen)
        setWindows(&w, snaps, bridged: bridged)
        return w
    }

    var bridge: PlacedPlank {
        PlacedPlank(id: PlankID(1), endA: PlankEnd(window: 1, offset: 200), endB: PlankEnd(window: 2, offset: 0))
    }

    func setWindows(_ w: inout WorldState, _ snaps: [WindowSnapshot], bridged: Bool = false) {
        w.windows.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        let planks = bridged ? [bridge] : []
        w.surfaces = SurfaceBuilder.build(windows: snaps, planks: planks, screen: screen)
        w.nav = NavGraph.build(surfaces: w.surfaces, planks: planks, constants: constants)
    }

    var twoWindows: [WindowSnapshot] {
        [win(1, z: 0, x: 100, y: 400), win(2, z: 1, x: 400, y: 400)]
    }

    /// 推进若干帧：先剧情，再居民。`until` 为真时提前结束。
    @discardableResult
    func run(_ s: inout StoryState, _ w: inout WorldState, now: inout Date, frames: Int,
             until: (StoryState, WorldState) -> Bool = { _, _ in false }) -> [StoryEvent] {
        var rng = RandomSource(seed: 7)
        var events: [StoryEvent] = []
        for _ in 0 ..< frames {
            now = now.addingTimeInterval(dt)
            events += StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: dt)
            var ctx = StoryDirector.context(w, constants)
            for id in ResidentID.allCases {
                ctx.residentLocations[id] = StoryDirector.location(id, world: w, ctx: ctx)
            }
            for id in ResidentID.allCases {
                guard var r = w.residents[id] else { continue }
                ResidentController.update(&r, world: ctx, dt: dt, rng: &rng)
                w.residents[id] = r
            }
            if until(s, w) { break }
        }
        return events
    }

    @Test func giverAlternatesByRound() {
        #expect(StoryDirector.giver(round: 1) == .a)
        #expect(StoryDirector.giver(round: 2) == .b)
        #expect(StoryDirector.receiver(round: 1) == .b)
        #expect(StoryDirector.giver(round: 3) == StoryDirector.receiver(round: 2))
    }

    @Test func selectHomesPicksWidestPairAndBreaksTiesByFront() {
        // 窗口 3 最右，与窗口 1 距离最大；窗口 1 在左，归都都。
        let snaps = [win(1, z: 2, x: 0, y: 300), win(2, z: 0, x: 500, y: 300), win(3, z: 1, x: 1000, y: 300)]
        let ledges = SurfaceBuilder.build(windows: snaps, screen: screen)
        let homes = StoryDirector.selectHomes(windows: snaps, ledges: ledges, minSize: 120)
        #expect(homes?.a == 1 && homes?.b == 3)

        // 两对距离并列（1-2 与 3-4），选 zIndex 之和更小的 3-4。
        let tie = [win(1, z: 2, x: 0, y: 100), win(2, z: 3, x: 1000, y: 100),
                   win(3, z: 0, x: 0, y: 500), win(4, z: 1, x: 1000, y: 500)]
        let tieHomes = StoryDirector.selectHomes(
            windows: tie, ledges: SurfaceBuilder.build(windows: tie, screen: screen), minSize: 120)
        #expect(tieHomes?.a == 3 && tieHomes?.b == 4)

        // 太小的窗口不算候选。
        let small = [win(1, z: 0, x: 0, y: 300), win(2, z: 1, x: 800, y: 300, w: 100, h: 100)]
        #expect(StoryDirector.selectHomes(
            windows: small, ledges: SurfaceBuilder.build(windows: small, screen: screen), minSize: 120) == nil)
    }

    @Test func waitsOnGroundUntilTwoWindowsThenBegins() {
        var w = world([win(1, z: 0, x: 100, y: 400)])
        var s = StoryState()
        var now = t0
        run(&s, &w, now: &now, frames: 3)
        #expect(s.stage == nil)
        #expect(w.residents.count == 2)
        for r in w.residents.values {
            if case .ground = r.attachment {} else { Issue.record("expected ground: \(r.attachment)") }
            #expect(r.goal == Goal.none)
        }

        setWindows(&w, twoWindows)
        now = now.addingTimeInterval(dt)
        let events = StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: dt)
        // 同一次更新完成分配、开局，并因无路线进入 Waiting。
        #expect(s.stage == .waiting)
        #expect(s.homes == [.a: 1, .b: 2])
        #expect(w.residents[.a]?.attachment == .window(1, offset: 100))
        #expect(w.residents[.b]?.attachment == .window(2, offset: 100))
        #expect(w.residents[.a]?.heldItem == s.currentFlower)
        #expect(w.residents[.a]?.goal == .reach(.b))
        #expect(w.residents[.b]?.goal == .confined)
        #expect(events.contains(.roundStarted(round: 1, giver: .a, receiver: .b)))
    }

    @Test func fullRoundThenRolesSwap() throws {
        var w = world(twoWindows, bridged: true)
        var s = StoryState()
        var now = t0
        run(&s, &w, now: &now, frames: 1)
        #expect(s.stage == .travel)

        run(&s, &w, now: &now, frames: 30 * 40) { s, _ in s.stage == .growing }
        #expect(s.stage == .growing)
        let flowerID = try #require(s.currentFlower)
        let flower = try #require(w.items[flowerID])
        #expect(flower.growth?.plantedAt != nil)
        #expect(flower.placement.holder == nil)
        #expect(w.residents[.a]?.heldItem == nil)
        #expect(w.residents[.a]?.bubble == .heart && w.residents[.b]?.bubble == .heart)

        // 时间推进到开花：同一次更新进入 ReturnGift，嘟嘟拿到果子。
        now = now.addingTimeInterval(constants.bloomDuration)
        StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: dt)
        #expect(s.stage == .returnGift)
        #expect(w.items[flowerID]?.stage == .bloom)
        #expect(w.residents[.b]?.heldItem == s.currentFruit)
        #expect(w.residents[.b]?.goal == .reach(.a))
        #expect(w.residents[.a]?.goal == .confined)

        run(&s, &w, now: &now, frames: 30 * 40) { s, _ in s.stage == .done }
        #expect(s.stage == .done)
        let fruitID = try #require(s.currentFruit)
        if case .attached = w.items[fruitID]?.placement {} else { Issue.record("fruit not attached") }
        #expect(w.residents[.a]?.state == .celebrating && w.residents[.b]?.state == .celebrating)

        run(&s, &w, now: &now, frames: Int(StoryDirector.celebrateDuration * 30) + 2)
        #expect(w.residents[.a]?.state != .celebrating && w.residents[.b]?.state != .celebrating)

        now = now.addingTimeInterval(constants.roundInterval)
        StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: dt)
        #expect(s.round == 2)
        #expect(s.stage == .travel)
        #expect(w.residents[.b]?.heldItem == s.currentFlower)
        #expect(w.residents[.b]?.goal == .reach(.a))
        // 上一轮的花和果子保留。
        #expect(w.items[flowerID] != nil && w.items[fruitID] != nil)
    }

    @Test func plantingInterruptedByFallReturnsToTravel() throws {
        var w = world(twoWindows, bridged: true)
        var s = StoryState()
        var now = t0
        run(&s, &w, now: &now, frames: 30 * 40) { s, _ in s.stage == .planting }
        #expect(s.stage == .planting)
        let flowerID = try #require(s.currentFlower)

        ResidentController.startFalling(&w.residents[.b]!, from: Point(x: 500, y: 400), screen: screen)
        now = now.addingTimeInterval(dt)
        StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: dt)
        #expect(s.stage == .travel)
        #expect(w.residents[.a]?.heldItem == flowerID)
        #expect(w.items[flowerID]?.growth?.plantedAt == nil)
        #expect(w.residents[.a]?.state == .idle)
    }

    @Test func plantingPausesWhileWindowHidden() {
        var w = world(twoWindows, bridged: true)
        var s = StoryState()
        var now = t0
        run(&s, &w, now: &now, frames: 30 * 40) { s, _ in s.stage == .planting }
        #expect(s.stage == .planting)
        // 嘟嘟和都都都在窗口 2 上；隐藏窗口 2 后计时暂停。
        w.windows.apply(.success(eligible: [twoWindows[0]], existingIDs: [1, 2]))
        let before = s.plantingElapsed
        for _ in 0 ..< 120 {
            now = now.addingTimeInterval(dt)
            StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: dt)
        }
        #expect(s.stage == .planting)
        #expect(s.plantingElapsed == before)
    }

    // MARK: 任务 13.4：快进与重新开始剧情

    @Test func fastForwardInGrowingAdvancesExactlyOneStage() throws {
        var w = world(twoWindows, bridged: true)
        var s = StoryState()
        var now = t0
        run(&s, &w, now: &now, frames: 30 * 40) { s, _ in s.stage == .growing }
        #expect(s.stage == .growing)
        let id = try #require(s.currentFlower)

        let e1 = StoryDirector.fastForward(&s, world: &w, constants: constants, now: now)
        #expect(e1 == [.sprouted(flower: id)])
        #expect(w.items[id]?.stage == .sprout)
        let planted1 = try #require(w.items[id]?.growth?.plantedAt)
        #expect(now.timeIntervalSince(planted1) == constants.bloomDuration * 0.5)
        #expect(s.stage == .growing)

        let e2 = StoryDirector.fastForward(&s, world: &w, constants: constants, now: now)
        #expect(e2 == [.bloomed(flower: id)])
        #expect(w.items[id]?.stage == .bloom)

        // 下一次更新按正常路径进入 ReturnGift。
        now = now.addingTimeInterval(dt)
        StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: dt)
        #expect(s.stage == .returnGift)
        #expect(w.residents[.b]?.heldItem == s.currentFruit)
    }

    @Test func fastForwardInDoneStartsNextRoundImmediately() {
        var w = world(twoWindows, bridged: true)
        var s = StoryState()
        var now = t0
        run(&s, &w, now: &now, frames: 30 * 40) { s, _ in s.stage == .growing }
        now = now.addingTimeInterval(constants.bloomDuration)
        StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: dt)
        run(&s, &w, now: &now, frames: 30 * 40) { s, _ in s.stage == .done }
        #expect(s.stage == .done)

        let events = StoryDirector.fastForward(&s, world: &w, constants: constants, now: now)
        #expect(s.round == 2)
        #expect(s.stage == .travel)
        #expect(events.contains(.roundStarted(round: 2, giver: .b, receiver: .a)))
        #expect(w.residents[.b]?.heldItem == s.currentFlower)
        #expect(w.residents[.a]?.state != .celebrating && w.residents[.b]?.state != .celebrating)
    }

    @Test func fastForwardInOtherStagesChangesNothing() {
        var w = world(twoWindows)
        var s = StoryState()
        var now = t0
        run(&s, &w, now: &now, frames: 1)
        #expect(s.stage == .waiting)
        let before = s
        let items = w.items
        #expect(StoryDirector.fastForward(&s, world: &w, constants: constants, now: now).isEmpty)
        #expect(s == before)
        #expect(w.items == items)
    }

    @Test func restartClearsFlowersAndFruitsKeepsPlanksAndRebegins() throws {
        var w = world(twoWindows, bridged: true)
        w.planks.planks[bridge.id] = .placed(bridge)
        var s = StoryState()
        var now = t0
        run(&s, &w, now: &now, frames: 30 * 40) { s, _ in s.stage == .growing }
        now = now.addingTimeInterval(constants.bloomDuration)
        StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: dt)
        #expect(s.stage == .returnGift)
        #expect(w.residents[.b]?.heldItem != nil)
        // 额外放一颗地面果子。
        let loose = Item.fruit(placement: .attached(.ground(x: 300)))
        w.items[loose.id] = loose
        let planks = w.planks

        StoryDirector.restart(&s, world: &w, constants: constants, now: now)
        #expect(s.round == 1)
        #expect(s.homes == [.a: 1, .b: 2])
        // 场上只剩新一轮都都抱着的花盆。
        let flower = try #require(s.currentFlower)
        #expect(w.items.items.keys.sorted() == [flower])
        #expect(w.residents[.a]?.heldItem == flower)
        #expect(w.residents[.b]?.heldItem == nil)
        #expect(w.items[flower]?.growth?.plantedAt == nil)
        #expect(w.planks == planks)
        #expect(s.stage == .travel)
    }

    @Test func restartIsIndependentOfStage() {
        var w1 = world(twoWindows)
        var s1 = StoryState()
        var now = t0
        run(&s1, &w1, now: &now, frames: 1)
        var w2 = w1
        var s2 = s1
        s2.stage = .done
        s2.round = 7
        s2.doneAt = now
        StoryDirector.restart(&s1, world: &w1, constants: constants, now: now)
        StoryDirector.restart(&s2, world: &w2, constants: constants, now: now)
        #expect(s1.stage == s2.stage && s1.round == s2.round && s1.homes == s2.homes)
        #expect(s1.stage == .waiting)

        // 窗口不足时重新开始为未开局，两人在 Ground 上。
        var w3 = world([win(1, z: 0, x: 100, y: 400)])
        var s3 = StoryState(stage: .growing, round: 3)
        StoryDirector.restart(&s3, world: &w3, constants: constants, now: now)
        #expect(s3.stage == nil && s3.round == 1)
        #expect(w3.residents.count == 2)
    }

    @Test func evictsOldestStoryFlower() {
        var w = WorldState(screen: screen)
        var ids: [ItemID] = []
        for k in 0 ..< 6 {
            var item = Item.flowerPot(storyRound: k + 1, placement: .attached(.ground(x: Double(k) * 50)))
            item.growth = FlowerGrowth(plantedAt: t0.addingTimeInterval(Double(k)), reached: .pot)
            w.items[item.id] = item
            ids.append(item.id)
        }
        let events = StoryDirector.evictFlowers(world: &w, max: 5)
        #expect(events == [.flowerEvicted(flower: ids[0])])
        #expect(w.items[ids[0]] == nil)
        #expect(w.items.items.count == 5)
    }
}
