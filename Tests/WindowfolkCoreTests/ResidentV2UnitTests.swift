import Testing
@testable import WindowfolkCore

/// v2 任务 5.1：Resident 新字段、新 Goal（hold、reachPoint、reachWindow）、running 状态与速度倍数、
/// Walk_Distance 累计、坐着的居民命中矩形上移。
struct ResidentV2UnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    let constants = Tunables()
    let dt = 1.0 / 30

    func win(_ id: WindowID, z: Int, x: Double, y: Double, w: Double, h: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    func context(_ snaps: [WindowSnapshot], planks: [PlacedPlank] = [],
                 locations: [ResidentID: ResidentLocation] = [:]) -> WorldContext {
        var t = WindowTable()
        t.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        let surfaces = SurfaceBuilder.build(windows: snaps, planks: planks, screen: screen)
        let nav = NavGraph.build(surfaces: surfaces, planks: planks, constants: constants)
        return WorldContext(windows: t, surfaces: surfaces, screen: screen, constants: constants,
                            nav: nav, residentLocations: locations)
    }

    /// 两个上沿同高、相距 100pt 的窗口，以及架在两者之间的木板。
    var twoWindows: [WindowSnapshot] {
        [win(1, z: 0, x: 100, y: 400, w: 200, h: 200), win(2, z: 1, x: 400, y: 400, w: 200, h: 200)]
    }
    var bridge: PlacedPlank {
        PlacedPlank(id: PlankID(1), endA: PlankEnd(window: 1, offset: 200), endB: PlankEnd(window: 2, offset: 0))
    }

    func run(_ r: inout Resident, _ ctx: WorldContext, frames: Int, each: (Resident) -> Void = { _ in }) {
        var rng = RandomSource(seed: 1)
        for _ in 0 ..< frames {
            ResidentController.update(&r, world: ctx, dt: dt, rng: &rng)
            each(r)
        }
    }

    @Test func newFieldsDefaultToV1Behavior() {
        let r = Resident(id: .a, attachment: .ground(x: 10))
        #expect(r.speedFactor == 1)
        #expect(r.routeMetric == .standard)
        #expect(r.walkDistance == 0)
        #expect(r.seat == nil)
        #expect(ResidentController.movingState(r) == .walking)
    }

    @Test func speedFactorAboveOneRunsAtScaledWalkSpeed() {
        let ctx = context(twoWindows)
        var r = Resident(id: .a, attachment: .window(1, offset: 10), speedFactor: 1.6)
        r.goal = .reachPoint(.ledge(1, index: 0), x: 290, arriveWithin: 1)
        run(&r, ctx, frames: 1)
        #expect(r.state == .running)
        guard case let .window(_, offset) = r.attachment else { Issue.record("\(r.attachment)"); return }
        #expect(abs(offset - (10 + constants.walkSpeed * 1.6 * dt)) < 1e-9)

        // 持物且倍数大于 1：仍以 walkSpeed 为基准、状态为 running。
        var held = Resident(id: .a, attachment: .ground(x: 0), heldItem: ItemID(), speedFactor: 1.5)
        #expect(ResidentController.speed(held, constants) == constants.walkSpeed * 1.5)
        #expect(ResidentController.movingState(held) == .running)
        held.speedFactor = 1
        #expect(ResidentController.speed(held, constants) == constants.carrySpeed)
        #expect(ResidentController.movingState(held) == .carrying)
    }

    @Test func smallJumpAndDropAreNotRunning() {
        let ctx = context(twoWindows)
        var r = Resident(id: .a, attachment: .window(1, offset: 100), speedFactor: 1.6)
        let jump = NavEdge(from: .ledge(1, index: 0), to: .ledge(2, index: 0), kind: .smallJump,
                           exit: Point(x: 200, y: 400), entry: Point(x: 220, y: 400), cost: 8)
        ResidentController.take(jump, &r, from: Point(x: 200, y: 400), world: ctx)
        #expect(r.traversal?.kind == .smallJump)
        #expect(r.state == .walking)
    }

    @Test func reachPointStopsWithinArriveDistance() {
        let ctx = context(twoWindows, planks: [bridge])
        var r = Resident(id: .a, attachment: .window(1, offset: 20),
                         goal: .reachPoint(.ledge(2, index: 0), x: 500, arriveWithin: 20))
        run(&r, ctx, frames: 30 * 15)
        guard case let .window(id, offset) = r.attachment else { Issue.record("\(r.attachment)"); return }
        #expect(id == 2)
        #expect(abs(400 + offset - 500) <= 20)
        #expect(abs(400 + offset - 500) >= 20 - constants.walkSpeed * dt - 1e-9)   // 进入范围就停下，不走到目标点
        #expect(r.state == .idle)
        #expect(r.route == nil)
    }

    @Test func reachWindowArrivesOnFirstLedgeStep() {
        let ctx = context(twoWindows, planks: [bridge])
        var r = Resident(id: .a, attachment: .window(1, offset: 20), goal: .reachWindow(2))
        run(&r, ctx, frames: 30 * 15)
        guard case let .window(id, offset) = r.attachment else { Issue.record("\(r.attachment)"); return }
        #expect(id == 2)
        #expect(offset <= 1)                             // 一踏上窗沿就到达
        #expect(r.state == .idle)
        #expect(r.route == nil)
    }

    @Test func reachWindowUnreachableWaitsAndAlreadyThereStops() {
        var r = Resident(id: .a, attachment: .window(1, offset: 20), goal: .reachWindow(2))
        run(&r, context(twoWindows), frames: 5)
        #expect(r.state == .waiting)
        #expect(r.attachment == .window(1, offset: 20))

        var home = Resident(id: .a, state: .walking, attachment: .window(2, offset: 50), goal: .reachWindow(2))
        run(&home, context(twoWindows), frames: 3)
        #expect(home.state == .idle)
        #expect(home.attachment == .window(2, offset: 50))
    }

    @Test func reachWindowPicksShortestLedgeSegment() {
        // 窗口 2 被前方更高的窗口 3 挡住中段，分成左右两段；居民站在窗口 3 上靠右处，
        // 从两端往下跳分别落到左段和右段，右段更近。
        let snaps = [win(2, z: 1, x: 300, y: 700, w: 400, h: 125), win(3, z: 0, x: 450, y: 600, w: 100, h: 225)]
        let ctx = context(snaps)
        let ledges = ctx.surfaces.filter { $0.id.windowID == 2 }
        #expect(ledges.count == 2)
        var r = Resident(id: .a, attachment: .window(3, offset: 90), goal: .reachWindow(2))
        var picked: SurfaceID?
        run(&r, ctx, frames: 30 * 10) { r in
            if picked == nil, let route = r.route { picked = route.targetSurface }
        }
        let right = ledges.max { $0.start.x < $1.start.x }!.id
        #expect(picked == right)
        #expect(ResidentController.location(of: r, world: ctx)?.surface == right)
        #expect(r.state == .idle)
    }

    @Test func holdStaysIdleAndFacesTarget() {
        let ctx = context(twoWindows, locations: [.b: ResidentLocation(surface: .ledge(1, index: 0), x: 120)])
        var r = Resident(id: .a, state: .walking, attachment: .window(1, offset: 100), facing: .right,
                         goal: .hold(face: .resident(.b)))
        run(&r, ctx, frames: 10)
        #expect(r.state == .idle)
        #expect(r.facing == .left)
        #expect(r.attachment == .window(1, offset: 100))

        var plain = Resident(id: .a, state: .walking, attachment: .window(1, offset: 100), goal: .hold(face: nil))
        run(&plain, ctx, frames: 10)
        #expect(plain.state == .idle)
        #expect(plain.attachment == .window(1, offset: 100))
    }

    @Test func sittingAndSleepingSkipMovement() {
        let ctx = context(twoWindows)
        for state in [ResidentState.sitting, .sleeping] {
            var r = Resident(id: .a, state: state, attachment: .window(1, offset: 100),
                             goal: .reachPoint(.ledge(1, index: 0), x: 290, arriveWithin: 1))
            run(&r, ctx, frames: 30)
            #expect(r.state == state)
            #expect(r.attachment == .window(1, offset: 100))
        }
    }

    @Test func sittingResidentHitRectIsLifted() {
        #expect(SpriteMetrics.chairSeatHeight == 10)
        let p = Point(x: 200, y: 400)
        let sitting = ResidentView(id: .a, state: .sitting, position: p, facing: .right, isHidden: false)
        let idle = ResidentView(id: .b, state: .idle, position: p, facing: .right, isHidden: false)
        let view = WorldView(screen: screen, surfaces: [], showSurfaces: false, residents: [sitting, idle])
        let regions = HitTesting.regions(for: view)
        let rs = regions.first { $0.target == .resident(.a) }!.rect
        let ri = regions.first { $0.target == .resident(.b) }!.rect
        #expect(rs == SpriteMetrics.residentRect(bottomCenter: p, lift: 10))
        #expect(ri == SpriteMetrics.residentRect(bottomCenter: p))
    }

    @Test func engineAccumulatesWalkDistanceForWalkingFrames() {
        let h = BridgeHangTests.Harness([BridgeHangTests.win(1, 100, 300, 300, 300)])
        h.engine.place(Resident(id: .a, state: .walking, attachment: .window(1, offset: 100), facing: .right,
                                wander: WanderState(pauseRemaining: 10_000, walkRemaining: 100)))
        for _ in 0 ..< 10 { h.step() }
        let r = h.resident(.a)
        guard case let .window(_, offset) = r.attachment else { Issue.record("\(r.attachment)"); return }
        #expect(offset > 100)
        #expect(abs(r.walkDistance - (offset - 100)) < 1e-6)

        // idle（停顿中）不累计。
        h.engine.place(BridgeHangTests.idle(.b, window: 1, offset: 10))
        for _ in 0 ..< 10 { h.step() }
        #expect(h.resident(.b).walkDistance == 0)
    }
}
