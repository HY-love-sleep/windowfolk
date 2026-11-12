import Testing
@testable import WindowfolkCore

@Suite("Physics 单元测试")
struct PhysicsUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    let g = Tunables().fallGravity

    func ledge(_ w: WindowID, _ lo: Double, _ hi: Double, y: Double) -> Surface {
        Surface(id: .ledge(w, index: 0), start: Point(x: lo, y: y), end: Point(x: hi, y: y))
    }

    /// 逐帧推进直到落地，返回落点和用时。
    func fall(from p: Point, surfaces: [Surface], dt: Double = 1.0 / 30) -> (Surface, FallState, Double)? {
        var s = Physics.startFall(at: p, screen: screen)
        var t = 0.0
        while t < 10 {
            let prevY = s.position.y
            t += dt
            if let landed = Physics.advance(&s, dt: dt, surfaces: surfaces, gravity: g) {
                return (landed, s, t)
            }
            #expect(s.position.y > prevY)
        }
        return nil
    }

    @Test func landsOnHighestSurfaceBelowStart() throws {
        let ground = SurfaceBuilder.ground(screen: screen)
        let high = ledge(1, 100, 300, y: 200)
        let low = ledge(2, 100, 300, y: 500)
        let (landed, s, t) = try #require(fall(from: Point(x: 150, y: 50), surfaces: [ground, low, high]))
        #expect(landed.id == high.id)
        #expect(s.position == Point(x: 150, y: 200))
        #expect(s.velocityY == 0)
        #expect(t <= 2)
    }

    @Test func surfaceAtStartIsNotLandingSurface() throws {
        let ground = SurfaceBuilder.ground(screen: screen)
        let start = ledge(1, 100, 300, y: 200)
        let (landed, _, _) = try #require(fall(from: Point(x: 150, y: 200), surfaces: [ground, start]))
        #expect(landed.id == .ground)
    }

    @Test func surfaceNotCoveringXIsIgnored() throws {
        let ground = SurfaceBuilder.ground(screen: screen)
        let side = ledge(1, 400, 600, y: 300)
        let (landed, s, _) = try #require(fall(from: Point(x: 150, y: 0), surfaces: [ground, side]))
        #expect(landed.id == .ground)
        #expect(s.position.y == screen.groundY)
    }

    @Test func startXIsClampedToScreen() throws {
        let ground = SurfaceBuilder.ground(screen: screen)
        #expect(Physics.startFall(at: Point(x: -50, y: 0), screen: screen).position.x == 0)
        let (_, s, _) = try #require(fall(from: Point(x: 2000, y: 0), surfaces: [ground]))
        #expect(s.position.x == 1440)
        #expect(s.position.y == screen.groundY)
    }

    @Test func largeDtStillLandsOnFirstSurface() throws {
        let ground = SurfaceBuilder.ground(screen: screen)
        let high = ledge(1, 0, 300, y: 100)
        var s = Physics.startFall(at: Point(x: 50, y: 0), screen: screen)
        s.velocityY = 5000
        let landed = Physics.advance(&s, dt: 0.25, surfaces: [ground, high], gravity: g)
        #expect(landed?.id == high.id)
        #expect(s.position.y == 100)
    }

    @Test func fullScreenFallWithinTwoSeconds() {
        #expect((2 * 3000 / g).squareRoot() <= 2)
    }
}
