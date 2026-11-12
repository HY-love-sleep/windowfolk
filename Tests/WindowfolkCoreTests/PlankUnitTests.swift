import Testing
@testable import WindowfolkCore

struct PlankUnitTests {
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

    // 左窗口 [100, 400] y=300，右窗口 [500, 800] y=320
    var left: WindowSnapshot { win(1, z: 0, x: 100, y: 300, w: 300, h: 200) }
    var right: WindowSnapshot { win(2, z: 1, x: 500, y: 320, w: 300, h: 200) }

    @Test func snapPicksNearestLedgesOfTwoWindows() throws {
        let ledges = SurfaceBuilder.build(windows: [left, right], screen: screen)
        let s = try #require(PlankRules.snap(pointer: Point(x: 430, y: 290), ledges: ledges))
        #expect(s.windowA == 1 && s.endA == Point(x: 400, y: 300))
        #expect(s.windowB == 2 && s.endB == Point(x: 500, y: 320))
    }

    @Test func snapNeedsTwoWindows() {
        let ledges = SurfaceBuilder.build(windows: [left], screen: screen)
        #expect(PlankRules.snap(pointer: Point(x: 430, y: 290), ledges: ledges) == nil)
    }

    @Test func validityRules() {
        let ledges = SurfaceBuilder.build(windows: [left, right], screen: screen)
        func v(_ a: Point, _ wa: WindowID, _ b: Point, _ wb: WindowID) -> PlankValidity {
            PlankRules.validity(endA: a, windowA: wa, endB: b, windowB: wb, ledges: ledges, constants: k)
        }
        #expect(v(Point(x: 400, y: 300), 1, Point(x: 500, y: 320), 2) == .valid)
        #expect(v(Point(x: 300, y: 300), 1, Point(x: 500, y: 320), 2) == .tooFar)       // 200 > 160
        #expect(v(Point(x: 200, y: 300), 1, Point(x: 300, y: 300), 1) == .sameWindow)
        #expect(v(Point(x: 450, y: 300), 1, Point(x: 500, y: 320), 2) == .missingLedge) // 超出左窗沿
        let steep = SurfaceBuilder.build(windows: [left, win(2, z: 1, x: 500, y: 400, w: 300, h: 200)],
                                         screen: screen)
        #expect(PlankRules.validity(endA: Point(x: 400, y: 300), windowA: 1, endB: Point(x: 500, y: 400),
                                    windowB: 2, ledges: steep, constants: k) == .tooSteep)
    }

    @Test func placedPlankSurfaceFollowsWindowsAndHiddenSuspendsValidation() {
        let plank = PlacedPlank(id: PlankID(7), endA: PlankEnd(window: 2, offset: 0),
                                endB: PlankEnd(window: 1, offset: 300))
        var t = table([left, right])
        let surfaces = SurfaceBuilder.build(windows: t.visibleSnapshots, planks: [plank], screen: screen)
        let ps = surfaces.last!
        #expect(ps.id == .plank(PlankID(7)))
        #expect(ps.start == Point(x: 400, y: 300) && ps.end == Point(x: 500, y: 320))
        #expect(PlankRules.validity(of: plank, windows: t, ledges: surfaces, constants: k) == .valid)

        var store = PlankStore()
        store.planks[plank.id] = .placed(plank)
        let mid = AttachmentResolver.screenPosition(.plank(plank.id, t: 0.5), windows: t,
                                                    planks: store.lookup(windows: t), ladders: NoLadders(),
                                                    screen: screen)
        #expect(mid == Point(x: 450, y: 310))
        #expect(AttachmentResolver.attachment(landingOn: ps, atX: 425, windows: t) == .plank(plank.id, t: 0.25))

        // 右窗口隐藏：木板不出现在 Surface 中，校验暂停
        t.apply(.success(eligible: [left], existingIDs: [1, 2]))
        let hiddenSurfaces = SurfaceBuilder.build(windows: t.visibleSnapshots, planks: [plank], screen: screen)
        #expect(!hiddenSurfaces.contains { $0.id == .plank(plank.id) })
        #expect(PlankRules.validity(of: plank, windows: t, ledges: hiddenSurfaces, constants: k) == nil)

        // 右窗口关闭：失效
        t.apply(.success(eligible: [left], existingIDs: [1]))
        #expect(PlankRules.validity(of: plank, windows: t, ledges: hiddenSurfaces, constants: k) == .missingLedge)
    }

    @Test func surfaceIDOrdering() {
        #expect(SurfaceID.ground < .ledge(1, index: 0))
        #expect(SurfaceID.ledge(99, index: 3) < .plank(PlankID(0)))
        #expect(SurfaceID.plank(PlankID(1)) < .plank(PlankID(2)))
        #expect(!(SurfaceID.plank(PlankID(0)) < .ground))
    }
}
