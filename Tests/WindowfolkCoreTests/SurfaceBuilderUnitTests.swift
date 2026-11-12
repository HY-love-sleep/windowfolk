import Testing
@testable import WindowfolkCore

struct SurfaceBuilderUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )

    func win(_ id: WindowID, z: Int, x: Double, y: Double, w: Double, h: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    @Test func emptyInputGivesOnlyGround() {
        let s = SurfaceBuilder.build(windows: [], screen: screen)
        #expect(s.count == 1)
        #expect(s[0].id == .ground)
        #expect(s[0].start == Point(x: 0, y: 825))
        #expect(s[0].end == Point(x: 1440, y: 825))
    }

    @Test func frontWindowSplitsLedgeBehind() {
        let back = win(1, z: 1, x: 100, y: 200, w: 600, h: 300)
        let front = win(2, z: 0, x: 300, y: 150, w: 200, h: 200)   // 覆盖 y=200
        let ledges = SurfaceBuilder.ledges(for: [back, front])
        #expect(ledges.map(\.id) == [.ledge(1, index: 0), .ledge(1, index: 1), .ledge(2, index: 0)])
        #expect(ledges[0].xRange == Interval(lo: 100, hi: 300))
        #expect(ledges[1].xRange == Interval(lo: 500, hi: 700))
        #expect(ledges.allSatisfy { $0.start.y == ($0.id.windowID == 1 ? 200 : 150) })
    }

    @Test func frontWindowEdgeExactlyAtLedgeYCovers() {
        let back = win(1, z: 1, x: 100, y: 200, w: 400, h: 300)
        let bottomTouch = win(2, z: 0, x: 0, y: 100, w: 1000, h: 100)  // maxY == 200
        #expect(SurfaceBuilder.ledges(for: [back, bottomTouch]).allSatisfy { $0.id.windowID == 2 })
    }

    @Test func frontWindowNotCoveringYDoesNotCut() {
        let back = win(1, z: 1, x: 100, y: 200, w: 400, h: 300)
        let below = win(2, z: 0, x: 0, y: 250, w: 1000, h: 100)
        let ledges = SurfaceBuilder.ledges(for: [back, below]).filter { $0.id.windowID == 1 }
        #expect(ledges.count == 1)
        #expect(ledges[0].xRange == Interval(lo: 100, hi: 500))
    }

    @Test func backWindowDoesNotCutFront() {
        let front = win(1, z: 0, x: 100, y: 200, w: 400, h: 300)
        let back = win(2, z: 1, x: 0, y: 100, w: 1000, h: 500)
        let ledges = SurfaceBuilder.ledges(for: [front, back]).filter { $0.id.windowID == 1 }
        #expect(ledges.count == 1)
    }

    @Test func outputIndependentOfInputOrder() {
        let ws = [win(1, z: 2, x: 0, y: 300, w: 800, h: 200),
                  win(2, z: 0, x: 200, y: 250, w: 100, h: 100),
                  win(3, z: 1, x: 500, y: 280, w: 200, h: 300)]
        #expect(SurfaceBuilder.build(windows: ws, screen: screen)
                == SurfaceBuilder.build(windows: ws.reversed(), screen: screen))
    }
}
