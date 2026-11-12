import Testing
@testable import WindowfolkCore

/// 任务 8.3：居民寻路、等待与路线重规划的具体例子。
struct ResidentNavigationUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    let constants = Tunables()

    func win(_ id: WindowID, z: Int, x: Double, y: Double, w: Double, h: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    func context(
        _ snaps: [WindowSnapshot], planks: [PlacedPlank] = [], target: ResidentLocation?
    ) -> WorldContext {
        var t = WindowTable()
        t.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        let surfaces = SurfaceBuilder.build(windows: snaps, planks: planks, screen: screen)
        let nav = NavGraph.build(surfaces: surfaces, planks: planks, constants: constants)
        var locations: [ResidentID: ResidentLocation] = [:]
        if let target { locations[.b] = target }
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

    func run(_ r: inout Resident, _ ctx: WorldContext, frames: Int, dt: Double = 1.0 / 30,
             each: (Resident) -> Void = { _ in }) {
        var rng = RandomSource(seed: 1)
        for _ in 0 ..< frames {
            ResidentController.update(&r, world: ctx, dt: dt, rng: &rng)
            each(r)
        }
    }

    @Test func crossesPlankAndStopsAtTarget() {
        let ctx = context(twoWindows, planks: [bridge], target: ResidentLocation(surface: .ledge(2, index: 0), x: 500))
        var r = Resident(id: .a, attachment: .window(1, offset: 50), goal: .reach(.b))
        var sawPlank = false, sawWalking = false
        run(&r, ctx, frames: 30 * 15) { r in
            if case .plank = r.attachment { sawPlank = true }
            if r.state == .walking { sawWalking = true }
        }
        #expect(sawPlank && sawWalking)
        #expect(r.attachment == .window(2, offset: 100))
        #expect(r.state == .idle)
        #expect(r.route == nil)
    }

    @Test func waitsOnLedgeFacingTargetThenLeavesWhenReachable() {
        let target = ResidentLocation(surface: .ledge(2, index: 0), x: 500)
        var r = Resident(id: .a, attachment: .window(1, offset: 50), facing: .left, goal: .reach(.b))
        run(&r, context(twoWindows, target: target), frames: 10)
        #expect(r.state == .waiting)
        #expect(r.bubble == .dots)
        #expect(r.facing == .right)
        #expect(r.attachment == .window(1, offset: 50))

        // 木板架上后，下一帧离开等待并沿新路线移动。
        run(&r, context(twoWindows, planks: [bridge], target: target), frames: 1)
        #expect(r.state == .walking)
        #expect(r.bubble == nil)
        #expect(r.route != nil)
    }

    @Test func replansIntoWaitingWhenPlankRemoved() {
        let target = ResidentLocation(surface: .ledge(2, index: 0), x: 500)
        var r = Resident(id: .a, attachment: .window(1, offset: 50), goal: .reach(.b))
        run(&r, context(twoWindows, planks: [bridge], target: target), frames: 5)
        #expect(r.route?.steps.isEmpty == false)
        run(&r, context(twoWindows, target: target), frames: 1)
        #expect(r.route == nil)
        #expect(r.state == .waiting)
    }

    @Test func groundWaitingStaysAroundNearestPoint() {
        // 目标在高处窗沿上，从 Ground 无路可达。
        let snaps = [win(1, z: 0, x: 800, y: 200, w: 200, h: 200)]
        let ctx = context(snaps, target: ResidentLocation(surface: .ledge(1, index: 0), x: 900))
        var r = Resident(id: .a, attachment: .ground(x: 100), goal: .reach(.b))
        var reached = false
        let range = constants.groundWanderRange
        run(&r, ctx, frames: 30 * 60) { r in
            #expect(r.state == .waiting)
            guard case let .ground(x) = r.attachment else { Issue.record("left ground"); return }
            if r.wander.groundPatrolling { reached = true }
            if reached { #expect(x >= 900 - range - 1e-9 && x <= 900 + range + 1e-9) }
        }
        #expect(reached)
        #expect(r.wander.groundCenter == 900)
        #expect(r.bubble == nil)
    }

    @Test func dropsFromLedgeToGroundWithTraversal() {
        // 窗沿 y = 720，Ground y = 825，高差 105 ≤ Drop_Max_Height。
        let snaps = [win(1, z: 0, x: 100, y: 720, w: 200, h: 100)]
        let ctx = context(snaps, target: ResidentLocation(surface: .ground, x: 500))
        var r = Resident(id: .a, attachment: .window(1, offset: 100), goal: .reach(.b))
        var sawDrop = false
        run(&r, ctx, frames: 30 * 15) { r in
            if r.traversal?.kind == .drop {
                sawDrop = true
                #expect(r.state == .walking)
            }
        }
        #expect(sawDrop)
        #expect(r.attachment == .ground(x: 500))
        #expect(r.state == .idle)
    }

    @Test func carryingIsSlowerThanWalking() {
        let ctx = context(twoWindows, target: ResidentLocation(surface: .ledge(1, index: 0), x: 290))
        let dt = 0.1
        var walker = Resident(id: .a, attachment: .window(1, offset: 10), goal: .reach(.b))
        var carrier = walker
        carrier.heldItem = ItemID()
        run(&walker, ctx, frames: 1, dt: dt)
        run(&carrier, ctx, frames: 1, dt: dt)
        #expect(walker.state == .walking)
        #expect(carrier.state == .carrying)
        guard case let .window(_, ow) = walker.attachment, case let .window(_, oc) = carrier.attachment else {
            Issue.record("unexpected attachment"); return
        }
        #expect(abs((ow - 10) - constants.walkSpeed * dt) < 1e-9)
        #expect(abs((oc - 10) - constants.carrySpeed * dt) < 1e-9)
    }
}
