import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 7.3：WishDirector 的单元测试（生成条件、检查节奏、Chair / Lamp / Visit 的推进与完成、
/// 放弃、Debug 触发、快进）。全部直接调用纯函数，不经过 WorldEngine。
///
/// 世界：窗口 1（x 100 → 700）、窗口 2（x 800 → 1200）、窗口 3（x 1250 → 1400），上沿 y = 300。
/// Home_Window：A 为 1，B 为 2；窗口 3 是唯一的 Visit_Target 候选。
struct WishDirectorUnitTests {
    static let screen = ResidentTests.screen
    static let t0 = Date(timeIntervalSince1970: 50_000)

    static func win(_ id: WindowID, x: Double, w: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: 300, width: w, height: 300), zIndex: Int(id))
    }

    static let windows = [win(1, x: 100, w: 600), win(2, x: 800, w: 400), win(3, x: 1250, w: 150)]

    /// 由窗口构造世界；`hidden` 中的窗口为 Hidden_Window，`closed` 中的不出现。
    static func world(hidden: Set<WindowID> = [], closed: Set<WindowID> = []) -> WorldState {
        var table = WindowTable()
        let all = windows.filter { !closed.contains($0.id) }
        table.apply(.success(eligible: all, existingIDs: Set(all.map(\.id))))
        if !hidden.isEmpty {
            table.apply(.success(eligible: all.filter { !hidden.contains($0.id) }, existingIDs: Set(all.map(\.id))))
        }
        let surfaces = SurfaceBuilder.build(windows: table.visibleSnapshots, screen: screen)
        var w = WorldState(screen: screen, windows: table, surfaces: surfaces,
                           nav: NavGraph.build(surfaces: surfaces, constants: Tunables()))
        w.residents = [.a: onLedge(.a, 1, x: 400), .b: onLedge(.b, 2, x: 1000)]
        w.story.homes = [.a: 1, .b: 2]
        return w
    }

    static func onLedge(_ id: ResidentID, _ window: WindowID, x: Double) -> Resident {
        let minX = windows.first { $0.id == window }!.frame.minX
        return Resident(id: id, attachment: .window(window, offset: x - minX))
    }

    static func chair(_ id: UInt64, x: Double, seq: UInt64) -> Decor {
        Decor(id: DecorID(id), type: .chair, placement: .attached(.window(1, offset: x - 100)), placedSeq: seq)
    }

    static func ctx(_ w: WorldState, at now: Date = t0, _ k: Tunables = Tunables()) -> WishContext {
        WishContext(world: w, now: now, constants: k)
    }

    static func startedTypes(_ events: [WishEvent]) -> [WishType] {
        events.compactMap { if case let .started(w) = $0 { return w.type } else { return nil } }
    }

    // MARK: - 生成条件（Requirement 6.3、8.1、20.1）

    @Test func eligibleTypesFollowRequirementConditions() {
        var w = Self.world()
        var book = WishBook()
        // 白天、不累、无 Decor：flower（A 是第 1 次 Giver）、visit、chase（同窗不同窗都由 Ground 可达性决定）。
        let a = WishDirector.eligibleTypes(.a, book: book, world: w, ctx: Self.ctx(w))
        #expect(a.contains(.flower) && a.contains(.visit))
        #expect(!a.contains(.chair) && !a.contains(.lamp))
        #expect(!WishDirector.eligibleTypes(.b, book: book, world: w, ctx: Self.ctx(w)).contains(.flower))

        // 累了且没有 Chair：chair 可生成；放一把可达的空闲 Chair 后不可生成。
        w.residents[.a]?.walkDistance = 2000
        #expect(WishDirector.eligibleTypes(.a, book: book, world: w, ctx: Self.ctx(w)).contains(.chair))
        w.decors = DecorStore(decors: [DecorID(1): Self.chair(1, x: 200, seq: 1)])
        #expect(!WishDirector.eligibleTypes(.a, book: book, world: w, ctx: Self.ctx(w)).contains(.chair))

        // Night：lamp 可生成，chase 不可生成。
        w.isNight = true
        let night = WishDirector.eligibleTypes(.a, book: book, world: w, ctx: Self.ctx(w))
        #expect(night.contains(.lamp) && !night.contains(.chase))

        // Round_Interval 未满时没有 flower；flowerCount 为奇数时 Giver 为 B。
        book.flowerCount = 1
        book.lastFlowerDoneAt = Self.t0.addingTimeInterval(-10)
        #expect(!WishDirector.eligibleTypes(.b, book: book, world: w, ctx: Self.ctx(w)).contains(.flower))
        book.lastFlowerDoneAt = Self.t0.addingTimeInterval(-Tunables().roundInterval)
        #expect(WishDirector.eligibleTypes(.b, book: book, world: w, ctx: Self.ctx(w)).contains(.flower))
    }

    @Test func chaseNeedsRouteFromAToBAndOtherCooledDown() {
        var w = Self.world()
        // B 在窗口 2 上，A 在窗口 1 上：之间没有路线（窗沿间隔 100pt）时没有 chase。
        let book = WishBook()
        let reach = w.nav.horizontalField(from: .ledge(1, index: 0), at: 400).isReachable(.ledge(2, index: 0))
        #expect(WishDirector.eligibleTypes(.a, book: book, world: w, ctx: Self.ctx(w)).contains(.chase) == reach)
        // 同一 Surface 视为有路线。
        w.residents[.b] = Self.onLedge(.b, 1, x: 600)
        #expect(WishDirector.eligibleTypes(.a, book: book, world: w, ctx: Self.ctx(w)).contains(.chase))
        // 另一位冷却未满时没有 chase。
        let cooling = WishBook(lastEnded: [.b: Self.t0.addingTimeInterval(-10)])
        #expect(!WishDirector.eligibleTypes(.a, book: cooling, world: w, ctx: Self.ctx(w)).contains(.chase))
    }

    @Test func visitCandidatesExcludeHomesHiddenAndTakenTargets() {
        let w = Self.world()
        var book = WishBook()
        #expect(WishDirector.visitCandidates(book: book, world: w, ctx: Self.ctx(w)).map(\.window) == [3])
        book.active = [Wish(id: book.makeID(), type: .visit, wisher: .a, createdAt: Self.t0,
                            visitTarget: VisitTarget(window: 3, ownerName: "App3"))]
        #expect(WishDirector.visitCandidates(book: book, world: w, ctx: Self.ctx(w)).isEmpty)
        let hidden = Self.world(hidden: [3])
        #expect(WishDirector.visitCandidates(book: WishBook(), world: hidden, ctx: Self.ctx(hidden)).isEmpty)
    }

    // MARK: - 检查节奏与生成（Requirement 6.1、6.2、6.4、20.1）

    @Test func checksOnlyOnScheduleAndAFirstThenB() {
        var k = Tunables()
        k.wishSpawnChance = 1
        var w = Self.world()
        w.residents[.b]?.walkDistance = 2000   // B 总有 chair 可选
        var book = WishBook()
        var rng = RandomSource(seed: 1)
        // 未开始调度：不检查。
        #expect(WishDirector.plan(&book, world: &w, ctx: Self.ctx(w, k), rng: &rng).isEmpty)
        WishDirector.startScheduling(&book, now: Self.t0, constants: k)
        let before = rng
        #expect(WishDirector.plan(&book, world: &w, ctx: Self.ctx(w, at: Self.t0.addingTimeInterval(9), k),
                                  rng: &rng).isEmpty)
        #expect(rng == before)

        let at = Self.t0.addingTimeInterval(10)
        let events = WishDirector.plan(&book, world: &w, ctx: Self.ctx(w, at: at, k), rng: &rng)
        #expect(book.nextCheckAt == at.addingTimeInterval(10))
        let started = Self.startedTypes(events)
        if started.first == .flower || started.first == .chase {
            // 两人都参与的 Wish：B 本次不生成。
            #expect(started.count == 1)
        } else {
            #expect(started.count == 2)
            #expect(book.active.map(\.wisher) == [.a, .b])
        }
        // 每位居民最多 1 个 active Wish。
        #expect(book.active.flatMap { Array($0.participants) }.count == book.busy.count)
    }

    @Test func spawnChanceZeroNeverGeneratesAndSameSeedSameSequence() {
        func run(chance: Double, seed: UInt64) -> [WishEvent] {
            var k = Tunables()
            k.wishSpawnChance = chance
            var w = Self.world()
            var book = WishBook()
            var rng = RandomSource(seed: seed)
            WishDirector.startScheduling(&book, now: Self.t0, constants: k)
            var events: [WishEvent] = []
            for i in 1 ... 30 {
                events += WishDirector.plan(&book, world: &w, ctx: Self.ctx(w, at: Self.t0.addingTimeInterval(Double(i) * 10), k),
                                            rng: &rng)
            }
            return events
        }
        #expect(run(chance: 0, seed: 3).isEmpty)
        #expect(run(chance: 0.5, seed: 9) == run(chance: 0.5, seed: 9))
    }

    // MARK: - Chair_Wish（Requirement 1.2、1.4、7.1 至 7.3、7.7）

    @Test func chairWishUnlocksOnceAndPicksShortestThenEarliestPlaced() {
        var w = Self.world()
        var book = WishBook()
        var rng = RandomSource(seed: 1)
        let events = WishDirector.trigger(.chair, wisher: .a, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(events.count == 2)
        if case .started = events.first {} else { Issue.record("started 应在 decorUnlocked 之前") }
        #expect(events.last == .decorUnlocked(.chair))
        #expect(w.decors.unlocked == [.chair])
        #expect(w.residents[.a]?.goal == .hold(face: nil))

        // 没有 Chair：resolve 后进入 waiting。
        _ = WishDirector.resolve(&book, world: &w, ctx: Self.ctx(w))
        #expect(w.residents[.a]?.state == .waiting)

        // 两把等距的 Chair：取 placedSeq 较小者。
        w.decors.decors[DecorID(1)] = Self.chair(1, x: 300, seq: 5)
        w.decors.decors[DecorID(2)] = Self.chair(2, x: 500, seq: 2)
        _ = WishDirector.plan(&book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(book.active[0].decorTarget == DecorID(2))
        #expect(w.residents[.a]?.goal == .reachPoint(.ledge(1, index: 0), x: 500,
                                                       arriveWithin: Tunables().giftReachDistance))
        #expect(w.residents[.a]?.routeMetric == .horizontal)

        // 出现更近的 Chair 也不换目标。
        w.decors.decors[DecorID(3)] = Self.chair(3, x: 410, seq: 9)
        _ = WishDirector.plan(&book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(book.active[0].decorTarget == DecorID(2))

        // 目标被拖动：清除并重新选择剩下最近的一把。
        w.decors.decors[DecorID(2)]?.placement = .dragged(grabOffset: Point(x: 0, y: 0), fresh: false)
        _ = WishDirector.plan(&book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(book.active[0].decorTarget == DecorID(3))

        // 再触发一次 Chair_Wish（B）不再写 decorUnlocked。
        let again = WishDirector.trigger(.chair, wisher: .b, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(Self.startedTypes(again) == [.chair])
        #expect(again.count == 1)
    }

    @Test func chairWishArrivalSitsAndFulfillsWithoutCelebrating() {
        var w = Self.world()
        var book = WishBook()
        var rng = RandomSource(seed: 1)
        _ = WishDirector.trigger(.chair, wisher: .a, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng)
        w.decors.decors[DecorID(1)] = Self.chair(1, x: 450, seq: 1)
        _ = WishDirector.plan(&book, world: &w, ctx: Self.ctx(w), rng: &rng)
        // 模拟移动到椅子旁。
        w.residents[.a]?.attachment = .window(1, offset: 345)
        let now = Self.t0.addingTimeInterval(5)
        let events = WishDirector.resolve(&book, world: &w, ctx: Self.ctx(w, at: now))
        guard events.count == 2, case .activity(.sat(.a, DecorID(1))) = events[0],
              case let .fulfilled(done, nil) = events[1] else {
            Issue.record("事件应为 sat、fulfilled：\(events)")
            return
        }
        #expect(done.type == .chair && done.state == .fulfilled)
        let a = w.residents[.a]!
        #expect(a.state == .sitting && a.seat == DecorID(1))
        #expect(a.attachment == .window(1, offset: 350))
        #expect(w.activities[.a]?.kind == .rest)
        #expect(w.activities[.a]?.phase == .sitting(until: now.addingTimeInterval(Tunables().sitDuration)))
        #expect(book.active.isEmpty && book.lastEnded[.a] == now && book.celebrations.isEmpty)
    }

    // MARK: - Lamp_Wish（Requirement 6.12、7.6）

    @Test func lampWishDroppedWhenNightEndsAndSleepsOnArrival() {
        var w = Self.world()
        w.isNight = true
        var book = WishBook()
        var rng = RandomSource(seed: 1)
        _ = WishDirector.trigger(.lamp, wisher: .a, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(w.decors.unlocked == [.lamp])
        w.decors.decors[DecorID(1)] = Decor(id: DecorID(1), type: .lamp,
                                           placement: .attached(.window(1, offset: 340)), placedSeq: 1)
        _ = WishDirector.plan(&book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(book.active[0].decorTarget == DecorID(1))
        // 已在 Lamp_Range 内：入睡并完成，slept 在前。
        let events = WishDirector.resolve(&book, world: &w, ctx: Self.ctx(w))
        #expect(events.first == .activity(.slept(.a, DecorID(1))))
        #expect(w.residents[.a]?.state == .sleeping)
        #expect(w.activities[.a]?.phase == .sleeping)

        // 新的 Lamp_Wish：Night 结束后下一次 plan 放弃，Unlocked_Decor 和 Decor 不变。
        var w2 = Self.world()
        w2.isNight = true
        var book2 = WishBook()
        _ = WishDirector.trigger(.lamp, wisher: .b, book: &book2, world: &w2, ctx: Self.ctx(w2), rng: &rng)
        w2.isNight = false
        let later = Self.t0.addingTimeInterval(1)
        let dropped = WishDirector.plan(&book2, world: &w2, ctx: Self.ctx(w2, at: later), rng: &rng)
        guard case let .dropped(d)? = dropped.first else {
            Issue.record("应放弃：\(dropped)")
            return
        }
        #expect(d.type == .lamp && d.state == .dropped)
        #expect(book2.active.isEmpty && book2.lastEnded[.b] == later)
        #expect(w2.decors.unlocked == [.lamp])
    }

    // MARK: - Visit_Wish（Requirement 9.5 至 9.7、6.12）

    @Test func visitWishWaitsWhileHiddenDropsWhenClosedAndFulfillsOnArrival() {
        var w = Self.world()
        var book = WishBook()
        var rng = RandomSource(seed: 1)
        let started = WishDirector.trigger(.visit, wisher: .a, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(book.active.first?.visitTarget == VisitTarget(window: 3, ownerName: "App3"))
        #expect(Self.startedTypes(started) == [.visit])

        // 目标隐藏：保持 active，Wisher 等待。
        var hidden = Self.world(hidden: [3])
        hidden.residents = w.residents
        #expect(WishDirector.plan(&book, world: &hidden, ctx: Self.ctx(hidden), rng: &rng).isEmpty)
        #expect(hidden.residents[.a]?.goal == .reachWindow(3))
        _ = WishDirector.resolve(&book, world: &hidden, ctx: Self.ctx(hidden))
        #expect(hidden.residents[.a]?.state == .waiting)
        #expect(book.active.count == 1)

        // 站上目标窗沿：先 visited 再 fulfilled，Wisher 庆祝，到时转 idle。
        var there = w
        there.residents[.a] = Self.onLedge(.a, 3, x: 1300)
        let done = WishDirector.resolve(&book, world: &there, ctx: Self.ctx(there))
        #expect(done.first == .visitedWindow(.a, ownerName: "App3"))
        if case .fulfilled? = done.last {} else { Issue.record("应完成：\(done)") }
        #expect(there.residents[.a]?.state == .celebrating)
        let end = Self.t0.addingTimeInterval(StoryDirector.celebrateDuration)
        _ = WishDirector.plan(&book, world: &there, ctx: Self.ctx(there, at: end), rng: &rng)
        #expect(there.residents[.a]?.state == .idle)

        // 目标关闭：放弃。
        var book2 = WishBook()
        var w2 = Self.world()
        _ = WishDirector.trigger(.visit, wisher: .b, book: &book2, world: &w2, ctx: Self.ctx(w2), rng: &rng)
        var closed = Self.world(closed: [3])
        closed.residents = w2.residents
        let events = WishDirector.plan(&book2, world: &closed, ctx: Self.ctx(closed), rng: &rng)
        if case .dropped? = events.first {} else { Issue.record("应放弃：\(events)") }
        #expect(book2.active.isEmpty)
    }

    // MARK: - Wish_Timeout（Requirement 6.11、8.5）

    @Test func timeoutDropsOrdinaryWishButNotFlower() {
        var w = Self.world()
        var book = WishBook()
        var rng = RandomSource(seed: 1)
        _ = WishDirector.trigger(.flower, wisher: nil, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(book.flowerCount == 1 && w.story.stage != nil && w.story.round == 1)
        // 送花进行中，两人都 Busy：其他触发不生成，状态不变。
        let snapshot = (book, w.residents)
        #expect(WishDirector.trigger(.chair, wisher: .b, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng).isEmpty)
        #expect(book == snapshot.0 && w.residents == snapshot.1)

        let late = Self.t0.addingTimeInterval(Tunables().wishTimeout + 1)
        #expect(WishDirector.plan(&book, world: &w, ctx: Self.ctx(w, at: late), rng: &rng).isEmpty)
        #expect(book.active.map(\.type) == [.flower])

        var w2 = Self.world()
        var book2 = WishBook()
        _ = WishDirector.trigger(.chair, wisher: .a, book: &book2, world: &w2, ctx: Self.ctx(w2), rng: &rng)
        let atTimeout = Self.t0.addingTimeInterval(Tunables().wishTimeout)
        let events = WishDirector.plan(&book2, world: &w2, ctx: Self.ctx(w2, at: atTimeout), rng: &rng)
        if case .dropped? = events.first {} else { Issue.record("应放弃：\(events)") }
        #expect(book2.lastEnded[.a] == atTimeout)
        #expect(w2.decors.unlocked == [.chair])
    }

    // MARK: - Flower_Wish 完成（Requirement 8.4）

    @Test func flowerWishFulfilledWhenStoryReachesDone() {
        var w = Self.world()
        var book = WishBook()
        var rng = RandomSource(seed: 1)
        let started = WishDirector.trigger(.flower, wisher: .b, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(book.active.first?.wisher == .a)   // 忽略 wisher，取下一次 Giver
        #expect(started.contains(.story(.roundStarted(round: 1, giver: .a, receiver: .b))))
        let doneAt = Self.t0.addingTimeInterval(100)
        w.story.stage = .done
        w.story.doneAt = doneAt
        w.residents[.a]?.state = .celebrating
        let events = WishDirector.resolve(&book, world: &w, ctx: Self.ctx(w, at: doneAt))
        if case let .fulfilled(f, nil)? = events.first { #expect(f.type == .flower) } else {
            Issue.record("应完成：\(events)")
        }
        #expect(w.story.stage == nil)
        #expect(book.lastFlowerDoneAt == doneAt)
        #expect(book.lastEnded == [.a: doneAt, .b: doneAt])
        #expect(book.celebrations[.a] != nil)
        #expect(WishDirector.nextFlowerGiver(book) == .b)
    }

    // MARK: - Debug 触发（Requirement 17.2、17.3）

    @Test func triggerChecksOnlyItsPreconditions() {
        var w = Self.world()
        var book = WishBook(lastEnded: [.a: Self.t0])   // 冷却中也可以触发
        var rng = RandomSource(seed: 1)
        // chase：任一居民下落时不生成。
        w.residents[.b]?.state = .falling
        #expect(WishDirector.trigger(.chase, wisher: .a, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng).isEmpty)
        #expect(book.active.isEmpty)
        w.residents[.b]?.state = .idle
        let events = WishDirector.trigger(.chase, wisher: .b, book: &book, world: &w, ctx: Self.ctx(w), rng: &rng)
        #expect(Self.startedTypes(events) == [.chase])
        let chase = book.active[0]
        #expect(chase.wisher == .b && chase.chase?.phase == .ready && chase.chase?.readyAt == Self.t0)
        #expect(w.residents[.a]?.goal == .hold(face: .resident(.b)))
        #expect(w.residents[.b]?.goal == .hold(face: .resident(.a)))
        // Chase_Wish 不因超时放弃。
        let late = Self.t0.addingTimeInterval(Tunables().wishTimeout * 2)
        _ = WishDirector.plan(&book, world: &w, ctx: Self.ctx(w, at: late), rng: &rng)
        #expect(book.active.map(\.type) == [.chase])

        // visit 没有候选时不生成；非 flower 的 wisher 为 nil 时不生成。
        var w2 = Self.world(closed: [3])
        var book2 = WishBook()
        #expect(WishDirector.trigger(.visit, wisher: .a, book: &book2, world: &w2, ctx: Self.ctx(w2), rng: &rng).isEmpty)
        #expect(WishDirector.trigger(.lamp, wisher: nil, book: &book2, world: &w2, ctx: Self.ctx(w2), rng: &rng).isEmpty)
        #expect(w2.decors.unlocked.isEmpty)
    }

    // MARK: - 快进（Requirement 8.8 至 8.10）

    @Test func fastForwardEndsRoundIntervalOnlyWhenWaiting() {
        let k = Tunables()
        var w = Self.world()
        var book = WishBook()
        // 从未送过花：不变。
        #expect(WishDirector.fastForward(&book, world: &w, constants: k, now: Self.t0).isEmpty)
        #expect(book == WishBook())

        book.flowerCount = 1
        book.lastFlowerDoneAt = Self.t0.addingTimeInterval(-5)
        _ = WishDirector.fastForward(&book, world: &w, constants: k, now: Self.t0)
        #expect(book.lastFlowerDoneAt == Self.t0.addingTimeInterval(-k.roundInterval))
        #expect(book.flowerCount == 1 && book.nextCheckAt == nil)

        // 已满 Round_Interval：不再改。
        let before = book
        _ = WishDirector.fastForward(&book, world: &w, constants: k, now: Self.t0.addingTimeInterval(1))
        #expect(book == before)
    }

    // MARK: - 图标

    @Test func wishIconsAndVisitFlagArrow() {
        let visit = Wish(id: WishID(1), type: .visit, wisher: .a, createdAt: Self.t0,
                         visitTarget: VisitTarget(window: 3, ownerName: "App3"))
        let w = Self.world()
        let flagX = WishDirector.visitFlagX(window: 3, surfaces: w.surfaces)
        #expect(flagX == 1325)
        #expect(WishDirector.wishIcon(for: visit, resident: .a, residentX: 400, flagX: flagX) == .flag(arrow: .right))
        #expect(WishDirector.wishIcon(for: visit, resident: .a, residentX: 1390, flagX: flagX) == .flag(arrow: .left))
        let chase = Wish(id: WishID(2), type: .chase, wisher: .b, createdAt: Self.t0)
        #expect(WishDirector.wishIcon(for: chase, resident: .b, residentX: nil, flagX: nil) == .footprints)
        #expect(WishDirector.wishIcon(for: chase, resident: .a, residentX: nil, flagX: nil) == nil)
    }
}
