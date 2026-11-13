import Foundation
import Testing
@testable import WindowfolkCore

@Suite("NavGraph 水平度量单元测试")
struct NavGraphHorizontalUnitTests {
    let k = Tunables()

    func h(_ id: SurfaceID, _ x0: Double, _ x1: Double, _ y: Double) -> Surface {
        Surface(id: id, start: Point(x: x0, y: y), end: Point(x: x1, y: y))
    }

    /// 窄窗沿 [90, 110]，y = 770；Ground y = 880。两端可往下跳（高差 110），x = 100 处有一架梯子。
    func dropOrLadder() -> (NavGraph, SurfaceID, LadderID) {
        let ledge = h(.ledge(1, index: 0), 90, 110, 770)
        let ground = h(.ground, 0, 1000, 880)
        let lid = LadderID(3)
        let ladder = NavLadder(id: lid, bottomSurface: .ground, bottom: Point(x: 100, y: 880),
                               topSurface: ledge.id, top: Point(x: 100, y: 770))
        return (NavGraph.build(surfaces: [ledge, ground], ladders: [ladder], constants: k), ledge.id, lid)
    }

    @Test("standard 选往下跳（10+12+10 < 110），horizontal 选梯子（0 < 20）")
    func metricsDiffer() {
        let (g, ledge, lid) = dropOrLadder()
        let std = g.route(from: ledge, at: 100, to: .ground, targetX: 100, metric: .standard)
        #expect(std?.steps.map(\.kind) == [.drop])
        let hor = g.route(from: ledge, at: 100, to: .ground, targetX: 100, metric: .horizontal)
        #expect(hor?.steps.map(\.kind) == [.ladder(lid)])

        let field = g.horizontalField(from: ledge, at: 100)
        #expect(field.length(to: .ground, x: 100) == 0)
        #expect(field.length(to: .ground, x: 300) == 200)
        #expect(field.length(to: ledge, x: 90) == 10)
    }

    @Test(".standard 与 v1 route 结果相同")
    func standardMatchesV1() {
        let (g, ledge, _) = dropOrLadder()
        for (from, x, to, tx) in [(ledge, 95.0, SurfaceID.ground, 600.0), (.ground, 600, ledge, 92)] {
            #expect(g.route(from: from, at: x, to: to, targetX: tx, metric: .standard)
                    == g.route(from: from, at: x, to: to, targetX: tx))
        }
    }

    @Test("同一 Surface 可达且长度为水平距离；不连通或起点不在图中时不可达")
    func reachability() {
        let a = h(.ledge(1, index: 0), 0, 100, 200)
        let b = h(.ledge(2, index: 0), 500, 600, 200)
        let g = NavGraph.build(surfaces: [a, b], constants: k)

        let field = g.horizontalField(from: a.id, at: 30)
        #expect(field.isReachable(a.id))
        #expect(field.length(to: a.id, x: 80) == 50)
        #expect(!field.isReachable(b.id))
        #expect(field.length(to: b.id, x: 550) == nil)
        #expect(g.route(from: a.id, at: 30, to: b.id, targetX: 550, metric: .horizontal) == nil)
        #expect(g.route(from: a.id, at: 30, to: a.id, targetX: 80, metric: .horizontal)?.steps.isEmpty == true)

        let missing = g.horizontalField(from: .ledge(9, index: 0), at: 0)
        #expect(!missing.isReachable(a.id))
    }
}
