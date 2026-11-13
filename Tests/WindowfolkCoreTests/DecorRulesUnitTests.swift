import Foundation
import Testing
@testable import WindowfolkCore

/// Decor 松手判定与 Chair 占用（任务 2.2，Requirement 3.2 至 3.5）。
struct DecorRulesUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    let k = Tunables()
    let toolbox = Rect(minX: 1360, minY: 773, width: 72, height: 52)

    /// 窗口 1 [100, 400] y=300；木板 7 从 (400, 300) 到 (600, 320)。
    var snaps: [WindowSnapshot] {
        [WindowSnapshot(id: 1, ownerName: "App", ownerPID: 1,
                        frame: Rect(minX: 100, minY: 300, width: 300, height: 200), zIndex: 0)]
    }
    var plank: Surface { Surface(id: .plank(PlankID(7)), start: Point(x: 400, y: 300), end: Point(x: 600, y: 320)) }

    func table() -> WindowTable {
        var t = WindowTable()
        t.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        return t
    }

    func release(_ p: Point, grab: Point = Point(x: 0, y: 0), fresh: Bool = false,
                 extra: [Surface]? = nil) -> DecorRelease {
        let surfaces = SurfaceBuilder.build(windows: snaps, screen: screen) + (extra ?? [plank])
        return DecorRules.release(at: p, grabOffset: grab, fresh: fresh, toolbox: toolbox,
                                  surfaces: surfaces, windows: table(), screen: screen, constants: k)
    }

    @Test func distanceToRect() {
        let r = Rect(minX: 0, minY: 0, width: 10, height: 10)
        #expect(DecorRules.distance(Point(x: 5, y: 5), to: r) == 0)
        #expect(DecorRules.distance(Point(x: 10, y: 0), to: r) == 0)
        #expect(DecorRules.distance(Point(x: 13, y: 14), to: r) == 5)
        #expect(DecorRules.distance(Point(x: -2, y: 5), to: r) == 2)
    }

    @Test func toolboxReturnWinsOverSnap() {
        // 指针在 Toolbox 边缘外 24pt 以内，正下方即使有 Surface 也收回。
        #expect(release(Point(x: 1340, y: 790), fresh: true) == .discard)
        #expect(release(Point(x: 1340, y: 790), fresh: false) == .remove)
        #expect(release(Point(x: 1400, y: 800), fresh: true) == .discard)
    }

    @Test func snapsToLedgeAndPlank() {
        #expect(release(Point(x: 250, y: 280)) == .attach(.window(1, offset: 150), surface: .windowLedge))
        #expect(release(Point(x: 250, y: 300)) == .attach(.window(1, offset: 150), surface: .windowLedge))
        // 木板在 x=500 处 y=310。
        #expect(release(Point(x: 500, y: 290)) == .attach(.plank(PlankID(7), t: 0.5), surface: .plank))
        // 吸附与下落按 pointer - grabOffset 计算。
        #expect(release(Point(x: 260, y: 270), grab: Point(x: 10, y: -10))
                == .attach(.window(1, offset: 150), surface: .windowLedge))
    }

    @Test func picksNearestThenHigher() {
        // 木板 8 在 [200, 300] y=290，在窗沿 y=300 之上。
        let higher = Surface(id: .plank(PlankID(8)), start: Point(x: 200, y: 290), end: Point(x: 300, y: 290))
        #expect(release(Point(x: 250, y: 280), extra: [higher]) == .attach(.plank(PlankID(8), t: 0.5), surface: .plank))
        // 松开点在木板 8 下方：只剩窗沿。
        #expect(release(Point(x: 250, y: 295), extra: [higher]) == .attach(.window(1, offset: 150), surface: .windowLedge))
    }

    @Test func fallsWhenNothingWithinSnapDistance() {
        guard case let .fall(f) = release(Point(x: 250, y: 275)) else { Issue.record("should fall"); return }
        #expect(f.position == Point(x: 250, y: 275))
        #expect(f.velocityY == 0)
        // Ground 不参与吸附。
        guard case .fall = release(Point(x: 800, y: 820)) else { Issue.record("ground must not snap"); return }
        guard case let .fall(g) = release(Point(x: -30, y: 100)) else { Issue.record("should fall"); return }
        #expect(g.position.x == 0)
    }

    @Test func freeChair() {
        let chair = Decor(id: DecorID(1), type: .chair, placement: .attached(.ground(x: 10)))
        #expect(DecorRules.isFreeChair(chair, seats: [:]))
        #expect(!DecorRules.isFreeChair(chair, seats: [.a: DecorID(1)]))
        #expect(DecorRules.isFreeChair(chair, seats: [.a: DecorID(2)]))
        var dragged = chair
        dragged.placement = .dragged(grabOffset: Point(x: 0, y: 0), fresh: false)
        #expect(!DecorRules.isFreeChair(dragged, seats: [:]))
        var falling = chair
        falling.placement = .falling(Physics.startFall(at: Point(x: 10, y: 10), screen: screen), byPlayer: true)
        #expect(!DecorRules.isFreeChair(falling, seats: [:]))
        let lamp = Decor(id: DecorID(3), type: .lamp, placement: .attached(.ground(x: 10)))
        #expect(!DecorRules.isFreeChair(lamp, seats: [:]))
    }
}
