import Testing
@testable import WindowfolkCore

struct InteractionControllerUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    let k = Tunables()

    func win(_ id: WindowID, z: Int, x: Double, y: Double, w: Double, h: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    /// 左窗口 [100, 400] y=300，右窗口 [500, 800] y=320；一位居民站在左窗沿 x=250。
    func makeContext(_ snaps: [WindowSnapshot]? = nil) -> (InteractionContext, [ResidentID: Resident]) {
        let snaps = snaps ?? [win(1, z: 0, x: 100, y: 300, w: 300, h: 200),
                              win(2, z: 1, x: 500, y: 320, w: 300, h: 200)]
        var t = WindowTable()
        t.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        let surfaces = SurfaceBuilder.build(windows: snaps, screen: screen)
        let resident = Resident(id: .a, state: .walking, attachment: .window(1, offset: 150))
        let view = WorldView(screen: screen, surfaces: surfaces, showSurfaces: false, residents: [
            ResidentView(id: .a, state: .walking, position: Point(x: 250, y: 300), facing: .right,
                         isHidden: false, heldItem: nil, bubble: nil, poke: nil),
        ])
        let ctx = InteractionContext(screen: screen, windows: t, surfaces: surfaces,
                                     hitRegions: HitTesting.regions(for: view))
        return (ctx, [.a: resident])
    }

    var plankZoneCenter: Point {
        let f = ToolboxLayout.zoneFrame(.plank, screen: screen)
        return f.center
    }

    @discardableResult
    func run(_ events: [PointerEvent], _ g: inout Gesture, _ ctx: InteractionContext,
             _ planks: inout PlankStore, _ residents: inout [ResidentID: Resident]) -> [InteractionOutcome] {
        events.flatMap {
            InteractionController.handle($0, gesture: &g, context: ctx, planks: &planks,
                                         residents: &residents, constants: k)
        }
    }

    @Test func clickOnToolboxCreatesNothing() {
        let (ctx, r0) = makeContext()
        var residents = r0, planks = PlankStore(), g = Gesture.none
        let p = plankZoneCenter
        run([.down(p), .moved(Point(x: p.x + 3, y: p.y)), .up(Point(x: p.x + 4, y: p.y))],
            &g, ctx, &planks, &residents)
        #expect(planks.planks.isEmpty)
        #expect(g == .none)
    }

    @Test func greenDropPlacesPlankRedDropFalls() throws {
        let (ctx, r0) = makeContext()
        var residents = r0, planks = PlankStore(), g = Gesture.none
        let p = plankZoneCenter
        let target = Point(x: 450, y: 290)
        run([.down(p), .moved(target)], &g, ctx, &planks, &residents)
        let pv = try #require(InteractionController.preview(gesture: g, context: ctx, constants: k))
        #expect(pv.isValid)
        let out = run([.up(target)], &g, ctx, &planks, &residents)
        let placed = try #require(planks.planks[PlankID(1)]?.placed)
        #expect(out == [.plankPlaced(PlankID(1))])
        #expect(placed.endA == PlankEnd(window: 1, offset: 300))
        #expect(placed.endB == PlankEnd(window: 2, offset: 0))

        // 第二块：只有一个窗口，无法吸附 → 红色，下落。
        let (ctx1, _) = makeContext([win(1, z: 0, x: 100, y: 300, w: 300, h: 200)])
        let far = Point(x: 900, y: 100)
        run([.down(p), .moved(far)], &g, ctx1, &planks, &residents)
        let red = try #require(InteractionController.preview(gesture: g, context: ctx1, constants: k))
        #expect(!red.isValid && red.geometry == .loosePlank(bottomCenter: far))
        let out2 = run([.up(far)], &g, ctx1, &planks, &residents)
        #expect(out2 == [.plankDropped(PlankID(2))])
        guard case let .falling(f)? = planks.planks[PlankID(2)] else { Issue.record("not falling"); return }
        #expect(f.position == far)
    }

    @Test func draggingLoosePlankKeepsGrabOffset() throws {
        let (ctx0, r0) = makeContext()
        var residents = r0, g = Gesture.none
        var planks = PlankStore(planks: [PlankID(5): .loose(.ground(x: 300))], nextID: 6)
        var ctx = ctx0
        ctx.hitRegions.append(HitRegion(target: .plank(PlankID(5)),
                                        rect: SpriteMetrics.loosePlankRect(bottomCenter: Point(x: 300, y: 825))))
        run([.down(Point(x: 310, y: 822)), .moved(Point(x: 700, y: 100))], &g, ctx, &planks, &residents)
        #expect(planks.planks[PlankID(5)] == .dragged)
        guard case let .dragging(.plank(id), grab, _) = g else { Issue.record("not dragging"); return }
        #expect(id == PlankID(5) && grab == Point(x: 10, y: -3))
    }

    @Test func dragOnResidentIsSwallowed() {
        let (ctx, r0) = makeContext()
        var residents = r0, planks = PlankStore(), g = Gesture.none
        run([.down(Point(x: 250, y: 290)), .moved(Point(x: 280, y: 290))], &g, ctx, &planks, &residents)
        #expect(g == .swallowed)
        run([.up(Point(x: 280, y: 290))], &g, ctx, &planks, &residents)
        #expect(residents == r0)
    }

    @Test func pokeJumpsOnlyInAllowedStatesAndRepokeResetsBubble() {
        var r = Resident(id: .a, state: .walking, attachment: .window(1, offset: 150))
        InteractionController.poke(&r, constants: k)
        #expect(r.poke == PokeState(jumpRemaining: 0.4, bubbleRemaining: 1.5))
        #expect(InteractionController.advancePoke(&r, dt: 0.2))
        #expect(abs(InteractionController.jumpLift(r.poke, constants: k) - 12) < 1e-9)
        InteractionController.poke(&r, constants: k)
        #expect(r.poke == PokeState(jumpRemaining: 0.2, bubbleRemaining: 1.5))
        InteractionController.advancePoke(&r, dt: 2)
        #expect(r.poke == nil)
        #expect(r.state == .walking && r.attachment == .window(1, offset: 150))

        var h = Resident(id: .b, state: .hanging, attachment: .free(Point(x: 1, y: 2)), hangElapsed: 0.7)
        InteractionController.poke(&h, constants: k)
        #expect(h.poke == PokeState(jumpRemaining: 0, bubbleRemaining: 1.5))
        #expect(h.hangElapsed == 0.7 && h.state == .hanging)
    }

    @Test func clickOnResidentPokes() {
        let (ctx, r0) = makeContext()
        var residents = r0, planks = PlankStore(), g = Gesture.none
        let out = run([.down(Point(x: 250, y: 290)), .up(Point(x: 252, y: 290))], &g, ctx, &planks, &residents)
        #expect(out == [.poked(.a)])
        #expect(residents[.a]?.poke?.jumpRemaining == k.pokeJumpDuration)
    }
}
