import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 8.4：WishDirector 中追逐流程的小单元测试（ready → running、可达与不可达时的 Goal、结局与庆祝、
/// `Goal.wait`）。直接调用纯函数，不经过 WorldEngine。世界沿用 `WishDirectorUnitTests`。
struct ChaseEngineUnitTests {
    typealias W = WishDirectorUnitTests
    static let t0 = W.t0
    static let ledge1 = SurfaceID.ledge(1, index: 0)

    /// 两人都在窗口 1 上：A 在 `ax`，B 在 `bx`；从 Debug 触发一个 B 为 Wisher 的 Chase_Wish。
    static func started(ax: Double = 200, bx: Double = 600, hidden: Set<WindowID> = [])
        -> (WishBook, WorldState) {
        var w = W.world(hidden: hidden)
        w.residents[.a] = W.onLedge(.a, 1, x: ax)
        w.residents[.b] = W.onLedge(.b, 1, x: bx)
        var book = WishBook()
        var rng = RandomSource(seed: 1)
        let events = WishDirector.trigger(.chase, wisher: .b, book: &book, world: &w, ctx: W.ctx(w), rng: &rng)
        #expect(W.startedTypes(events) == [.chase])
        return (book, w)
    }

    static func plan(_ book: inout WishBook, _ w: inout WorldState, at dt: Double) -> [WishEvent] {
        var rng = RandomSource(seed: 2)
        return WishDirector.plan(&book, world: &w, ctx: W.ctx(w, at: t0.addingTimeInterval(dt)), rng: &rng)
    }

    static func resolve(_ book: inout WishBook, _ w: inout WorldState, at dt: Double) -> [WishEvent] {
        WishDirector.resolve(&book, world: &w, ctx: W.ctx(w, at: t0.addingTimeInterval(dt)))
    }

    @Test func readyHoldsUntilReadyDurationThenRuns() {
        var (book, w) = Self.started()
        _ = Self.plan(&book, &w, at: 1.99)
        #expect(book.active.first?.chase?.phase == .ready)
        #expect(w.residents[.a]?.goal == .hold(face: .resident(.b)))
        #expect(w.residents[.b]?.goal == .hold(face: .resident(.a)))
        // ready 阶段即使贴在一起也不判定 caught。
        #expect(Self.resolve(&book, &w, at: 1.99).isEmpty)

        _ = Self.plan(&book, &w, at: 2)
        let chase = book.active.first?.chase
        #expect(chase?.phase == .running)
        #expect(chase?.runningAt == Self.t0.addingTimeInterval(2))
        #expect(w.residents[.a]?.goal == .reach(.b))
        #expect(w.residents[.a]?.speedFactor == 1.6)
        #expect(w.residents[.b]?.speedFactor == 1.5)
        #expect(w.residents[.a]?.routeMetric == .horizontal)
        // Runner 逃向离 Chaser 最远的候选点：窗口 1 右端内收 8pt。
        let target = FleePoint(surface: Self.ledge1, x: 700 - Tunables().fleeEdgeInset)
        #expect(chase?.fleeTarget == target)
        #expect(w.residents[.b]?.goal == .reachPoint(Self.ledge1, x: target.x, arriveWithin: 1))
    }

    @Test func hiddenRunnerMakesChaserWaitAndRunnerHold() {
        var (book, w) = Self.started(hidden: [])
        // 把 B 放到窗口 2 上并隐藏窗口 2：视为不可达（Requirement 21.10）。
        w.residents[.b] = W.onLedge(.b, 2, x: 1000)
        var table = w.windows
        let visible = W.windows.filter { $0.id != 2 }
        table.apply(.success(eligible: visible, existingIDs: Set(W.windows.map(\.id))))
        w.windows = table
        w.surfaces = SurfaceBuilder.build(windows: table.visibleSnapshots, screen: W.screen)
        w.nav = NavGraph.build(surfaces: w.surfaces, constants: Tunables())

        _ = Self.plan(&book, &w, at: 2)
        #expect(w.residents[.a]?.goal == .wait(face: .resident(.b)))
        #expect(w.residents[.b]?.goal == .hold(face: .resident(.a)))
        #expect(book.active.first?.chase?.fleeTarget == nil)

        // `Goal.wait`：停在原地、`waiting`，不显示「...」。
        var a = w.residents[.a]!
        a.state = .running
        a.bubble = .dots
        var rng = RandomSource(seed: 3)
        let wc = StoryDirector.context(w, Tunables())
        ResidentController.update(&a, world: wc, dt: 0.1, rng: &rng)
        #expect(a.state == .waiting)
        #expect(a.bubble == nil)
        #expect(a.attachment == w.residents[.a]!.attachment)
    }

    @Test func caughtFulfillsAndBothCelebrateWithHearts() {
        var (book, w) = Self.started(ax: 400, bx: 410)
        _ = Self.plan(&book, &w, at: 2)
        let events = Self.resolve(&book, &w, at: 2)
        guard case let .fulfilled(wish, outcome)? = events.first else {
            Issue.record("应得出结局")
            return
        }
        #expect(events.count == 1)
        #expect(wish.type == .chase && wish.state == .fulfilled)
        #expect(outcome == .caught)
        #expect(book.active.isEmpty)
        #expect(book.lastEnded[.a] == Self.t0.addingTimeInterval(2))
        #expect(book.lastEnded[.b] == Self.t0.addingTimeInterval(2))
        for id in [ResidentID.a, .b] {
            #expect(w.residents[id]?.state == .celebrating)
            #expect(w.residents[id]?.bubble == .heart)
            #expect(w.residents[id]?.speedFactor == 1)
            #expect(w.residents[id]?.routeMetric == .standard)
        }
        // 结局只得出一次。
        #expect(Self.resolve(&book, &w, at: 2.1).isEmpty)
        // 庆祝结束的同一帧心形气泡消失。
        _ = Self.plan(&book, &w, at: 2 + StoryDirector.celebrateDuration)
        for id in [ResidentID.a, .b] {
            #expect(w.residents[id]?.state == .idle)
            #expect(w.residents[id]?.bubble == nil)
        }
    }

    @Test func escapedAfterChaseDurationWhenFarApart() {
        var (book, w) = Self.started(ax: 200, bx: 600)
        _ = Self.plan(&book, &w, at: 2)
        #expect(Self.resolve(&book, &w, at: 61.9).isEmpty)
        let events = Self.resolve(&book, &w, at: 62)
        #expect(events.count == 1)
        if case let .fulfilled(_, outcome)? = events.first { #expect(outcome == .escaped) }
        #expect(w.residents[.a]?.state == .celebrating && w.residents[.b]?.state == .celebrating)
    }

    /// 回归（Property 55 反例）：带 `face` 的 `Goal.hold`/`Goal.wait` 在落到 Surface 的同一帧就面朝对方
    /// （v2 Requirement 20.8）；无 `face` 的 Goal 落地时保持原朝向（v1 行为）。
    @Test func landingFacesOtherOnSameFrame() {
        var w = W.world()
        w.residents[.a] = W.onLedge(.a, 1, x: 200)
        w.residents[.b] = W.onLedge(.b, 1, x: 600)
        var wc = StoryDirector.context(w, Tunables())
        wc.residentLocations = [.b: ResidentLocation(surface: Self.ledge1, x: 600)]
        guard let ledge = wc.surface(Self.ledge1) else {
            Issue.record("找不到窗口 1 的窗沿")
            return
        }
        let landing = Point(x: 200, y: ledge.start.y)
        let cases: [(Goal, Facing)] = [
            (.hold(face: .resident(.b)), .right),
            (.wait(face: .resident(.b)), .right),
            (.hold(face: nil), .left),
            (.none, .left),
            (.reach(.b), .left),
        ]
        for (goal, expected) in cases {
            var a = w.residents[.a]!
            a.goal = goal
            a.facing = .left
            a.state = .falling
            a.attachment = .free(Point(x: 200, y: ledge.start.y - 5))
            ResidentController.land(&a, on: ledge, at: landing, world: wc)
            #expect(a.state == .idle, "\(goal)")
            #expect(a.facing == expected, "\(goal)")
        }
        // x 相等时保持原朝向。
        var a = w.residents[.a]!
        a.goal = .hold(face: .resident(.b))
        a.facing = .left
        ResidentController.land(&a, on: ledge, at: Point(x: 600, y: ledge.start.y), world: wc)
        #expect(a.facing == .left)
    }

    /// WorldEngine 中的完整流程：触发后 2 秒进入 running，两人以 `running` 跑动，最终得出一个结局并写一条含
    /// `chase_outcome` 的 `wish_fulfilled`；追逐中的两人点击不跳跃。
    @Test func engineRunsChaseToOutcome() {
        let h = StoryEngineTests.Harness(StoryEngineTests.touching)
        h.step()
        h.step([.triggerWish(.chase, .b)])
        #expect(h.engine.state.wishes.active.map(\.type) == [.chase])
        #expect(h.engine.jumpBlockedResidents() == [.a, .b])
        var sawRunning = false
        var fulfilled: [EventRecord] = []
        for _ in 0 ..< 70 * 30 {
            let out = h.step()
            if h.resident(.a).state == .running || h.resident(.b).state == .running { sawRunning = true }
            fulfilled += out.events.filter { $0.type == .wishFulfilled }
            if !fulfilled.isEmpty { break }
        }
        #expect(sawRunning)
        #expect(fulfilled.count == 1)
        #expect(fulfilled.first?.detail["wish_type"] == "chase")
        #expect(["caught", "escaped"].contains(fulfilled.first?.detail["chase_outcome"] ?? ""))
        #expect(h.engine.state.wishes.active.isEmpty)
        #expect(h.resident(.a).speedFactor == 1 && h.resident(.b).speedFactor == 1)
        #expect(h.engine.jumpBlockedResidents().isEmpty)
    }
}
