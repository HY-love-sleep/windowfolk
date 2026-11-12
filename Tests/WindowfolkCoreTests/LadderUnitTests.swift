import Testing
@testable import WindowfolkCore

struct LadderUnitTests {
    // Ground y = 825
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

    @Test func snapTopClampsPointerXToNearestLedge() {
        let w = win(1, z: 0, x: 100, y: 700, w: 300, h: 100)
        let surfaces = SurfaceBuilder.build(windows: [w], screen: screen)
        let snap = LadderRules.snapTop(pointer: Point(x: 450, y: 690), ledges: surfaces)
        #expect(snap?.0 == Point(x: 400, y: 700))
        #expect(snap?.1 == .ledge(1, index: 0))
        #expect(LadderRules.snapTop(pointer: Point(x: 10, y: 10),
                                    ledges: SurfaceBuilder.build(windows: [], screen: screen)) == nil)
    }

    @Test func bottomIsFirstLedgeOrGroundBelow() {
        let high = win(1, z: 0, x: 100, y: 500, w: 300, h: 100)
        let low = win(2, z: 1, x: 200, y: 650, w: 300, h: 100)
        let surfaces = SurfaceBuilder.build(windows: [high, low], screen: screen)
        // x = 250 在低窗沿范围内
        let b1 = LadderRules.bottom(below: Point(x: 250, y: 500), surfaces: surfaces)
        #expect(b1?.0 == Point(x: 250, y: 650))
        #expect(b1?.1 == .ledge(2, index: 0))
        // x = 150 不在低窗沿范围内，落到 Ground
        let b2 = LadderRules.bottom(below: Point(x: 150, y: 500), surfaces: surfaces)
        #expect(b2?.0 == Point(x: 150, y: 825))
        #expect(b2?.1 == .ground)
    }

    @Test func previewValidityByLength() {
        let near = win(1, z: 0, x: 100, y: 700, w: 300, h: 100)   // 距 Ground 125
        let far = win(2, z: 1, x: 600, y: 400, w: 300, h: 100)    // 距 Ground 425
        let surfaces = SurfaceBuilder.build(windows: [near, far], screen: screen)
        #expect(LadderRules.preview(pointer: Point(x: 200, y: 690), surfaces: surfaces, constants: k).validity == .valid)
        #expect(LadderRules.preview(pointer: Point(x: 700, y: 390), surfaces: surfaces, constants: k).validity == .tooLong)
        let none = LadderRules.preview(pointer: Point(x: 5, y: 5),
                                       surfaces: SurfaceBuilder.build(windows: [], screen: screen), constants: k)
        #expect(none.top == nil && none.validity == .missingLedge)
        #expect(LadderRules.validity(top: Point(x: 0, y: 100), bottom: Point(x: 0, y: 300), constants: k) == .valid)
        #expect(LadderRules.validity(top: Point(x: 0, y: 100), bottom: Point(x: 0, y: 300.5), constants: k) == .tooLong)
    }

    @Test func placedLadderValidityAndRefresh() {
        let w = win(1, z: 0, x: 100, y: 700, w: 300, h: 100)
        var t = table([w])
        var surfaces = SurfaceBuilder.build(windows: [w], screen: screen)
        let ladder = PlacedLadder(id: LadderID(1), top: PlankEnd(window: 1, offset: 50),
                                  bottomSurface: .ground, bottom: Point(x: 150, y: 825))
        #expect(LadderRules.validity(of: ladder, windows: t, surfaces: surfaces, constants: k) == .valid)

        // 窗口上移：下端重算，长度超限
        var moved = w
        moved.frame.minY = 500
        moved.frame.minX = 300
        t.apply(.success(eligible: [moved], existingIDs: [1]))
        surfaces = SurfaceBuilder.build(windows: [moved], screen: screen)
        let r = LadderRules.refreshed(ladder, windows: t, surfaces: surfaces)
        #expect(r?.bottom == Point(x: 350, y: 825))
        #expect(LadderRules.validity(of: ladder, windows: t, surfaces: surfaces, constants: k) == .tooLong)

        // 隐藏：暂停校验
        t.apply(.success(eligible: [], existingIDs: [1]))
        #expect(LadderRules.validity(of: ladder, windows: t, surfaces: [], constants: k) == nil)

        // 关闭：失效
        t.apply(.success(eligible: [], existingIDs: []))
        #expect(LadderRules.validity(of: ladder, windows: t, surfaces: [], constants: k) == .missingLedge)
    }

    @Test func topLedgeCoveredInvalidates() {
        let back = win(1, z: 1, x: 100, y: 700, w: 300, h: 100)
        let front = win(2, z: 0, x: 50, y: 650, w: 400, h: 200)   // 完全遮住 back 的上沿
        let t = table([front, back])
        let surfaces = SurfaceBuilder.build(windows: [front, back], screen: screen)
        let ladder = PlacedLadder(id: LadderID(1), top: PlankEnd(window: 1, offset: 50),
                                  bottomSurface: .ground, bottom: Point(x: 150, y: 825))
        #expect(LadderRules.validity(of: ladder, windows: t, surfaces: surfaces, constants: k) == .missingLedge)
        #expect(ladder.navLadder(windows: t, surfaces: surfaces) == nil)
    }

    @Test func navGraphGetsBidirectionalLadderEdgesAndLookup() {
        let w = win(1, z: 0, x: 100, y: 700, w: 300, h: 100)
        let t = table([w])
        let surfaces = SurfaceBuilder.build(windows: [w], screen: screen)
        var store = LadderStore()
        let id = store.makeID()
        store.ladders[id] = .placed(PlacedLadder(id: id, top: PlankEnd(window: 1, offset: 50),
                                                 bottomSurface: .ground, bottom: Point(x: 150, y: 825)))
        let id2 = store.makeID()
        store.ladders[id2] = .loose(.ground(x: 600))
        let navs = store.navLadders(windows: t, surfaces: surfaces)
        #expect(navs.count == 1)
        #expect(navs.first?.topSurface == .ledge(1, index: 0))

        let g = NavGraph.build(surfaces: surfaces, ladders: navs, constants: k)
        let up = g.edges[.ground]?.filter { $0.kind == .ladder(id) } ?? []
        let down = g.edges[.ledge(1, index: 0)]?.filter { $0.kind == .ladder(id) } ?? []
        #expect(up.count == 1 && down.count == 1)
        #expect(up.first?.cost == 125)

        let lookup = store.lookup(windows: t)
        #expect(lookup.point(onLadder: id, height: 25) == Point(x: 150, y: 800))
        #expect(lookup.point(onLadder: id, height: 999) == Point(x: 150, y: 700))
        #expect(lookup.point(onLadder: id2, height: 0) == nil)
    }
}
