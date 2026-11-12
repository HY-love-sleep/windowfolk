import Testing
@testable import WindowfolkCore

/// 任务 9.2：梯子拖放与爬梯状态的具体例子。
struct LadderInteractionUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    let k = Tunables()

    func win(_ id: WindowID, z: Int, x: Double, y: Double, w: Double, h: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    func table(_ snaps: [WindowSnapshot]) -> WindowTable {
        var t = WindowTable()
        t.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        return t
    }

    func context(_ snaps: [WindowSnapshot], extra: [HitRegion] = []) -> InteractionContext {
        let surfaces = SurfaceBuilder.build(windows: snaps, screen: screen)
        let view = WorldView(screen: screen, surfaces: surfaces, showSurfaces: false)
        return InteractionContext(screen: screen, windows: table(snaps), surfaces: surfaces,
                                  hitRegions: extra + HitTesting.regions(for: view))
    }

    var ladderZone: Point { ToolboxLayout.zoneFrame(.ladder, screen: screen).center }

    @discardableResult
    func run(_ events: [PointerEvent], _ g: inout Gesture, _ ctx: InteractionContext,
             _ ladders: inout LadderStore) -> [InteractionOutcome] {
        var planks = PlankStore()
        var residents: [ResidentID: Resident] = [:]
        return events.flatMap {
            InteractionController.handle($0, gesture: &g, context: ctx, planks: &planks, ladders: &ladders,
                                         residents: &residents, constants: k)
        }
    }

    /// 窗口上沿 y=700，下方 Ground y=825：竖直距离 125 ≤ 200，绿色并架设。
    @Test func greenDropPlacesLadder() throws {
        let ctx = context([win(1, z: 0, x: 100, y: 700, w: 300, h: 200)])
        var g = Gesture.none, ladders = LadderStore()
        let target = Point(x: 150, y: 690)
        let started = run([.down(ladderZone), .moved(target)], &g, ctx, &ladders)
        #expect(started == [.dragStarted(.newLadder)])
        let pv = try #require(InteractionController.preview(gesture: g, context: ctx, constants: k))
        #expect(pv.isValid)
        #expect(pv.geometry == .snappedLadder(top: Point(x: 150, y: 700), bottom: Point(x: 150, y: 825),
                                              topSurface: .ledge(1, index: 0)))
        let out = run([.up(target)], &g, ctx, &ladders)
        #expect(out == [.ladderPlaced(LadderID(1))])
        let placed = try #require(ladders.ladders[LadderID(1)]?.placed)
        #expect(placed.top == PlankEnd(window: 1, offset: 50))
        #expect(placed.bottomSurface == .ground && placed.bottom == Point(x: 150, y: 825))
        #expect(g == .none)
    }

    /// 上沿 y=300，到 Ground 525 > 200：红色，从上端稍高处下落。
    @Test func redDropFallsFromTop() throws {
        let ctx = context([win(1, z: 0, x: 100, y: 300, w: 300, h: 200)])
        var g = Gesture.none, ladders = LadderStore()
        let target = Point(x: 200, y: 280)
        run([.down(ladderZone), .moved(target)], &g, ctx, &ladders)
        let pv = try #require(InteractionController.preview(gesture: g, context: ctx, constants: k))
        #expect(!pv.isValid)
        let out = run([.up(target)], &g, ctx, &ladders)
        #expect(out == [.ladderDropped(LadderID(1))])
        guard case let .falling(f)? = ladders.ladders[LadderID(1)] else { Issue.record("not falling"); return }
        #expect(f.position == Point(x: 200, y: 300 - InteractionController.releaseLift))
    }

    /// 没有任何窗沿：预览平放跟随指针、红色，松手从该处下落。
    @Test func noLedgeFollowsPointerRed() throws {
        let ctx = context([])
        var g = Gesture.none, ladders = LadderStore()
        let target = Point(x: 600, y: 400)
        run([.down(ladderZone), .moved(target)], &g, ctx, &ladders)
        let pv = try #require(InteractionController.preview(gesture: g, context: ctx, constants: k))
        #expect(!pv.isValid && pv.geometry == .looseLadder(bottomCenter: target))
        #expect(run([.up(target)], &g, ctx, &ladders) == [.ladderDropped(LadderID(1))])
    }

    /// 点击 Ladder 取物区不新建梯子（Requirement 8.8）。
    @Test func clickCreatesNothing() {
        let ctx = context([])
        var g = Gesture.none, ladders = LadderStore()
        run([.down(ladderZone), .up(Point(x: ladderZone.x + 2, y: ladderZone.y))], &g, ctx, &ladders)
        #expect(ladders.ladders.isEmpty)
    }

    /// 拖起落在 Ground 上的梯子，保持抓取偏移，松手绿色时重新架设（Requirement 10.10）。
    @Test func dragLooseLadderAndReplace() throws {
        let snaps = [win(1, z: 0, x: 100, y: 700, w: 300, h: 200)]
        var ladders = LadderStore()
        let id = ladders.makeID()
        ladders.ladders[id] = .loose(.ground(x: 800))
        let rect = SpriteMetrics.looseLadderRect(bottomCenter: Point(x: 800, y: 825))
        let ctx = context(snaps, extra: [HitRegion(target: .ladder(id), rect: rect)])
        var g = Gesture.none
        let press = Point(x: 805, y: 820)
        let out = run([.down(press), .moved(Point(x: 600, y: 600))], &g, ctx, &ladders)
        #expect(out == [.dragStarted(.ladder(id))])
        #expect(ladders.ladders[id] == .dragged)
        guard case let .dragging(_, grab, _) = g else { Issue.record("not dragging"); return }
        #expect(grab == Point(x: 5, y: -5))
        #expect(run([.up(Point(x: 200, y: 690))], &g, ctx, &ladders) == [.ladderPlaced(id)])
        #expect(ladders.ladders[id]?.placed?.top == PlankEnd(window: 1, offset: 100))
    }

    // MARK: - 爬梯

    /// 居民从 Ground 沿梯子爬上窗沿：途中为 `climbing` 且附着在梯子上，到达后在窗沿上停下。
    @Test func climbsLadderToLedge() throws {
        let snaps = [win(1, z: 0, x: 100, y: 700, w: 300, h: 200)]
        let t = table(snaps)
        let surfaces = SurfaceBuilder.build(windows: snaps, screen: screen)
        var store = LadderStore()
        let lid = store.makeID()
        store.ladders[lid] = .placed(PlacedLadder(id: lid, top: PlankEnd(window: 1, offset: 50),
                                                  bottomSurface: .ground, bottom: Point(x: 150, y: 825)))
        let nav = NavGraph.build(surfaces: surfaces, ladders: store.navLadders(windows: t, surfaces: surfaces),
                                 constants: k)
        let ctx = WorldContext(windows: t, surfaces: surfaces, screen: screen, constants: k, nav: nav,
                               residentLocations: [.b: ResidentLocation(surface: .ledge(1, index: 0), x: 300)],
                               ladders: store.lookup(windows: t))
        var r = Resident(id: .a, attachment: .ground(x: 300), goal: .reach(.b))
        var rng = RandomSource(seed: 1)
        var sawClimb = false
        for _ in 0 ..< 30 * 20 {
            ResidentController.update(&r, world: ctx, dt: 1.0 / 30, rng: &rng)
            if r.state == .climbing {
                sawClimb = true
                guard case let .ladder(id, h) = r.attachment else {
                    Issue.record("climbing without ladder attachment: \(r.attachment)"); return
                }
                #expect(id == lid && h >= 0 && h <= 125)
            }
        }
        #expect(sawClimb)
        #expect(r.state == .idle)
        #expect(r.attachment == .window(1, offset: 200))
    }

    /// 爬梯途中梯子消失：从当前高度竖直下落，不经过 `hanging`（Requirement 13.5 的兜底）。
    @Test func ladderGoneMidClimbFalls() {
        let snaps = [win(1, z: 0, x: 100, y: 700, w: 300, h: 200)]
        let t = table(snaps)
        let surfaces = SurfaceBuilder.build(windows: snaps, screen: screen)
        let lid = LadderID(1)
        let edge = NavEdge(from: .ground, to: .ledge(1, index: 0), kind: .ladder(lid),
                           exit: Point(x: 150, y: 825), entry: Point(x: 150, y: 700), cost: 125)
        var r = Resident(id: .a, state: .climbing, attachment: .ladder(lid, height: 50))
        r.traversal = Traversal(kind: .climb, from: Point(x: 150, y: 825), to: Point(x: 150, y: 700),
                                duration: 4, edge: edge)
        let ctx = WorldContext(windows: t, surfaces: surfaces, screen: screen, constants: k)
        var rng = RandomSource(seed: 1)
        ResidentController.update(&r, world: ctx, dt: 1.0 / 30, rng: &rng)
        #expect(r.state == .falling)
        #expect(r.attachment == .free(Point(x: 150, y: 775)))
    }
}
