import Testing
@testable import WindowfolkCore

struct ResidentUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )

    func win(_ id: WindowID, z: Int, x: Double, y: Double, w: Double, h: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    func context(_ snaps: [WindowSnapshot], hidden: Set<WindowID> = []) -> WorldContext {
        var t = WindowTable()
        t.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        let visible = snaps.filter { !hidden.contains($0.id) }
        if !hidden.isEmpty {
            t.apply(.success(eligible: visible, existingIDs: Set(snaps.map(\.id))))
        }
        return WorldContext(windows: t, surfaces: SurfaceBuilder.build(windows: visible, screen: screen),
                            screen: screen, constants: Tunables())
    }

    @Test func randomSourceIsDeterministic() {
        var a = RandomSource(seed: 42)
        var b = RandomSource(seed: 42)
        let sa = (0 ..< 20).map { _ in a.next() }
        let sb = (0 ..< 20).map { _ in b.next() }
        #expect(sa == sb)
        var c = RandomSource(seed: 7)
        for _ in 0 ..< 1000 {
            let d = c.double(in: 2, 5)
            #expect(d >= 2 && d < 5)
        }
    }

    @Test func residentStateHasTwelveCases() {
        #expect(ResidentState.allCases.count == 12)
        #expect(ResidentID.a.rawValue == "resident_a")
        #expect(ResidentID.a.other == .b)
    }

    @Test func wanderStaysOnLedgeAndTurnsAround() {
        let ctx = context([win(1, z: 0, x: 100, y: 200, w: 160, h: 300)])
        var r = Resident(id: .a, attachment: .window(1, offset: 80), wander: WanderState(pauseRemaining: 0))
        var rng = RandomSource(seed: 1)
        var sawWalking = false
        var sawLeft = false, sawRight = false
        for _ in 0 ..< 3000 {
            ResidentController.update(&r, world: ctx, dt: 1.0 / 30, rng: &rng)
            #expect(r.state == .idle || r.state == .walking)
            guard case let .window(id, offset) = r.attachment else {
                Issue.record("left window attachment: \(r.attachment)"); return
            }
            #expect(id == 1)
            #expect(offset >= 0 && offset <= 160)
            if r.state == .walking { sawWalking = true }
            if r.facing == .left { sawLeft = true } else { sawRight = true }
        }
        #expect(sawWalking && sawLeft && sawRight)
    }

    @Test func walkingIntoEndpointTurnsAround() {
        let ctx = context([win(1, z: 0, x: 100, y: 200, w: 160, h: 300)])
        var r = Resident(id: .a, state: .walking, attachment: .window(1, offset: 155), facing: .right,
                         wander: WanderState(pauseRemaining: 0, walkRemaining: 10))
        var rng = RandomSource(seed: 3)
        ResidentController.update(&r, world: ctx, dt: 0.25, rng: &rng)
        #expect(r.attachment == .window(1, offset: 160))
        #expect(r.facing == .left)
        ResidentController.update(&r, world: ctx, dt: 0.25, rng: &rng)
        #expect(r.attachment == .window(1, offset: 150))
    }

    @Test func wanderOnGroundStaysInGround() {
        let ctx = context([])
        var r = Resident(id: .b, attachment: .ground(x: 5), facing: .left,
                         wander: WanderState(pauseRemaining: 0))
        var rng = RandomSource(seed: 9)
        for _ in 0 ..< 2000 {
            ResidentController.update(&r, world: ctx, dt: 1.0 / 30, rng: &rng)
            guard case let .ground(x) = r.attachment else { Issue.record("not on ground"); return }
            #expect(x >= 0 && x <= 1440)
        }
    }

    @Test func hiddenWindowResidentDoesNotMove() {
        let ctx = context([win(1, z: 0, x: 100, y: 200, w: 160, h: 300)], hidden: [1])
        let start = Resident(id: .a, state: .walking, attachment: .window(1, offset: 40),
                             wander: WanderState(pauseRemaining: 0, walkRemaining: 10))
        var r = start
        var rng = RandomSource(seed: 1)
        for _ in 0 ..< 30 { ResidentController.update(&r, world: ctx, dt: 1.0 / 30, rng: &rng) }
        #expect(r == start)
    }

    @Test func fallingResidentLandsOnLedgeAndBecomesIdle() {
        let ctx = context([win(1, z: 0, x: 100, y: 400, w: 300, h: 300)])
        var r = Resident(id: .a, attachment: .ground(x: 0))
        ResidentController.startFalling(&r, from: Point(x: 150, y: 0), screen: screen)
        #expect(r.state == .falling)
        var rng = RandomSource(seed: 1)
        for _ in 0 ..< 120 where r.state == .falling {
            ResidentController.update(&r, world: ctx, dt: 1.0 / 30, rng: &rng)
        }
        #expect(r.state == .idle)
        #expect(r.attachment == .window(1, offset: 50))
        #expect(r.fall == nil)
    }

    @Test func sameSeedSameTrajectory() {
        let ctx = context([win(1, z: 0, x: 100, y: 200, w: 400, h: 300)])
        func run() -> Resident {
            var r = Resident(id: .a, attachment: .window(1, offset: 200), wander: WanderState(pauseRemaining: 0))
            var rng = RandomSource(seed: 1234)
            for _ in 0 ..< 600 { ResidentController.update(&r, world: ctx, dt: 1.0 / 30, rng: &rng) }
            return r
        }
        #expect(run() == run())
    }
}
