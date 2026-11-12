import Foundation
import Testing
@testable import WindowfolkCore

/// 物件拖放（任务 11.2，Requirement 11）。
struct ItemDragUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    let k = Tunables()

    func win(_ id: WindowID, z: Int, x: Double, y: Double, w: Double, h: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    /// 窗口 1 [100, 400] y=300（前），窗口 2 [300, 700] y=310（后，[300, 400] 被窗口 1 遮挡），
    /// 窗口 3 [500, 700] y=290（最前）。
    var snaps: [WindowSnapshot] {
        [win(3, z: 0, x: 500, y: 290, w: 200, h: 200),
         win(1, z: 1, x: 100, y: 300, w: 300, h: 200),
         win(2, z: 2, x: 300, y: 310, w: 400, h: 200)]
    }

    func table(_ snaps: [WindowSnapshot]) -> WindowTable {
        var t = WindowTable()
        t.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        return t
    }

    func release(_ p: Point) -> ItemPlacement {
        InteractionController.itemRelease(
            at: p, surfaces: SurfaceBuilder.build(windows: snaps, screen: screen),
            windows: table(snaps), screen: screen, constants: k)
    }

    // MARK: - 松手去处

    @Test func releaseAttachesToLedgeWithinSnapDistance() {
        #expect(release(Point(x: 250, y: 280)) == .attached(.window(1, offset: 150)))
        #expect(release(Point(x: 250, y: 300)) == .attached(.window(1, offset: 150)))   // 恰好在窗沿上
        guard case .falling = release(Point(x: 250, y: 275)) else { Issue.record("25pt above should fall"); return }
    }

    @Test func releasePicksNearestLedgeBelow() {
        // x=600：窗口 3 y=290，窗口 2 在 [500, 700] 被窗口 3 遮挡（窗口 3 覆盖 y=310），只剩窗口 3。
        #expect(release(Point(x: 600, y: 280)) == .attached(.window(3, offset: 100)))
        // x=450：只有窗口 2 的窗沿（y=310）。
        #expect(release(Point(x: 450, y: 295)) == .attached(.window(2, offset: 150)))
    }

    @Test func releaseOverCoveredLedgeFalls() {
        // x=350：窗口 2 的上沿在这里被窗口 1 遮挡；窗口 1 的窗沿 y=300 在松开点上方。
        guard case let .falling(f) = release(Point(x: 350, y: 301)) else { Issue.record("should fall"); return }
        #expect(f.position == Point(x: 350, y: 301))
    }

    @Test func releaseOffScreenClampsX() {
        guard case let .falling(f) = release(Point(x: -50, y: 100)) else { Issue.record("should fall"); return }
        #expect(f.position.x == 0)
        let wide = [win(9, z: 0, x: 1300, y: 300, w: 200, h: 200)]
        let p = InteractionController.itemRelease(
            at: Point(x: 2000, y: 290), surfaces: SurfaceBuilder.build(windows: wide, screen: screen),
            windows: table(wide), screen: screen, constants: k)
        #expect(p == .attached(.window(9, offset: 140)))
    }

    // MARK: - 手势

    func context(items: ItemStore) -> InteractionContext {
        let surfaces = SurfaceBuilder.build(windows: snaps, screen: screen)
        var regions: [HitRegion] = []
        for id in items.sortedIDs {
            guard let it = items[id], case let .attached(a) = it.placement,
                  let p = AttachmentResolver.screenPosition(a, windows: table(snaps), screen: screen) else { continue }
            regions.append(HitRegion(target: .item(id), rect: SpriteMetrics.itemRect(kind: it.kind, bottomCenter: p)))
        }
        return InteractionContext(screen: screen, windows: table(snaps), surfaces: surfaces, hitRegions: regions)
    }

    @Test func dragGroundItemKeepsGrabOffsetAndAttachesOnRelease() {
        let id = ItemID()
        var items = ItemStore(items: [id: .fruit(id: id, placement: .attached(.ground(x: 900)))])
        let ctx = context(items: items)
        var g = Gesture.none, planks = PlankStore(), ladders = LadderStore()
        var residents: [ResidentID: Resident] = [:]
        func handle(_ e: PointerEvent) -> [InteractionOutcome] {
            InteractionController.handle(e, gesture: &g, context: ctx, planks: &planks, ladders: &ladders,
                                         items: &items, residents: &residents, constants: k)
        }
        let press = Point(x: 903, y: screen.groundY - 5)
        #expect(handle(.down(press)).isEmpty)
        #expect(handle(.moved(Point(x: 905, y: press.y))).isEmpty)       // 未超过阈值
        #expect(items[id]?.placement == .attached(.ground(x: 900)))
        #expect(handle(.moved(Point(x: 603, y: 400))) == [.dragStarted(.item(id))])
        #expect(items[id]?.placement == .dragged(grabOffset: Point(x: 3, y: -5)))
        #expect(InteractionController.draggedItemPosition(id, gesture: g) == Point(x: 600, y: 405))
        // 物件底边中点 (450, 295)：窗口 2 的窗沿在下方 15pt。
        #expect(handle(.up(Point(x: 453, y: 290))) == [.itemAttached(id)])
        #expect(items[id]?.placement == .attached(.window(2, offset: 150)))
        #expect(g == .none)
    }

    @Test func releaseWithoutLedgeDrops() {
        let id = ItemID()
        var items = ItemStore(items: [id: .flowerPot(id: id, placement: .attached(.ground(x: 900)))])
        let ctx = context(items: items)
        var g = Gesture.none, planks = PlankStore(), ladders = LadderStore()
        var residents: [ResidentID: Resident] = [:]
        let press = Point(x: 900, y: screen.groundY - 2)
        let out = [PointerEvent.down(press), .moved(Point(x: 1000, y: 100)), .up(Point(x: 1000, y: 100))].flatMap {
            InteractionController.handle($0, gesture: &g, context: ctx, planks: &planks, ladders: &ladders,
                                         items: &items, residents: &residents, constants: k)
        }
        #expect(out == [.dragStarted(.item(id)), .itemDropped(id)])
        guard case let .falling(f)? = items[id]?.placement else { Issue.record("should fall"); return }
        #expect(f.position == Point(x: 1000, y: 102))
    }

    @Test func heldItemIgnoresPressAndDrag() {
        let id = ItemID()
        var items = ItemStore(items: [id: .fruit(id: id, placement: .held(.a))])
        let before = items
        // 即使命中区域里有它（例如过期的命中矩形），也不能拖起。
        let p = Point(x: 900, y: 800)
        let ctx = InteractionContext(
            screen: screen, windows: table(snaps), surfaces: SurfaceBuilder.build(windows: snaps, screen: screen),
            hitRegions: [HitRegion(target: .item(id), rect: SpriteMetrics.itemRect(kind: .fruit, bottomCenter: p))])
        var g = Gesture.none, planks = PlankStore(), ladders = LadderStore()
        var residents: [ResidentID: Resident] = [:]
        let out = [PointerEvent.down(Point(x: 900, y: 795)), .moved(Point(x: 950, y: 700)), .up(Point(x: 950, y: 700))]
            .flatMap {
                InteractionController.handle($0, gesture: &g, context: ctx, planks: &planks, ladders: &ladders,
                                             items: &items, residents: &residents, constants: k)
            }
        #expect(out.isEmpty)
        #expect(items == before)
    }

    // MARK: - WorldEngine

    @Test func engineDragsGroundItemAndBlocksPickup() {
        let engine = WorldEngine(clockStart: Date(timeIntervalSince1970: 0), screen: screen,
                                 rng: RandomSource(seed: 1), demoResident: false)
        engine.place(Resident(id: .a, attachment: .ground(x: 200)))
        let id = ItemID()
        engine.insertItem(.flowerPot(id: id, placement: .attached(.ground(x: 900))))
        var t = 0.0
        func step(_ pointer: [PointerEvent] = []) -> StepOutput {
            t += 1.0 / 30
            return engine.step(FrameInput(poll: .success(eligible: snaps, existingIDs: Set(snaps.map(\.id))),
                                          screen: screen, pointer: pointer, now: Date(timeIntervalSince1970: t)))
        }
        let v0 = step().view
        #expect(v0.hitRegions.contains { $0.target == .item(id) })

        let press = Point(x: 900, y: screen.groundY - 4)
        let out = step([.down(press), .moved(Point(x: 1000, y: 500))])
        #expect(out.interactions == [.dragStarted(.item(id))])
        let dragged = out.view.items.first { $0.id == id }
        #expect(dragged?.isDragged == true)
        #expect(dragged?.position == Point(x: 1000, y: 504))
        #expect(!out.view.hitRegions.contains { $0.target == .item(id) })
        // 拖动中的物件不能被居民拿起（Requirement 11.9）。
        #expect(engine.give(engine.state.items[id]!, to: .a) == false)

        let up = step([.up(Point(x: 250, y: 290))])
        #expect(up.interactions == [.itemAttached(id)])
        #expect(engine.state.items[id]?.placement == .attached(.window(1, offset: 150)))
    }
}
