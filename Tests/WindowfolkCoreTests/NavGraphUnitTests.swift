import Foundation
import Testing
@testable import WindowfolkCore

@Suite("NavGraph 单元测试")
struct NavGraphUnitTests {
    let k = Tunables()

    func h(_ id: SurfaceID, _ x0: Double, _ x1: Double, _ y: Double) -> Surface {
        Surface(id: id, start: Point(x: x0, y: y), end: Point(x: x1, y: y))
    }

    func kinds(_ g: NavGraph, _ a: SurfaceID, _ b: SurfaceID) -> [EdgeKind] {
        (g.edges[a] ?? []).filter { $0.to == b }.map(\.kind)
    }

    @Test("首尾相接、同 y 的两条窗沿建双向行走边")
    func walkEdge() {
        let a = h(.ledge(1, index: 0), 0, 100, 200)
        let b = h(.ledge(2, index: 0), 100, 200, 200)
        let g = NavGraph.build(surfaces: [a, b], constants: k)
        #expect(kinds(g, a.id, b.id) == [.walk])
        #expect(kinds(g, b.id, a.id) == [.walk])
    }

    @Test("小跳边：高差 ≤ 24、间隙 ≤ 16 双向；超出时没有")
    func smallJump() {
        let a = h(.ledge(1, index: 0), 0, 100, 200)
        let b = h(.ledge(2, index: 0), 110, 200, 180)
        let g = NavGraph.build(surfaces: [a, b], constants: k)
        #expect(kinds(g, a.id, b.id) == [.smallJump])
        #expect(kinds(g, b.id, a.id) == [.smallJump])

        let far = h(.ledge(3, index: 0), 120, 200, 180)
        let g2 = NavGraph.build(surfaces: [a, far], constants: k)
        #expect(kinds(g2, a.id, far.id).isEmpty)
    }

    @Test("往下跳只从高到低，落到端点正下方最近的 Surface")
    func dropEdge() {
        let high = h(.ledge(1, index: 0), 100, 200, 100)
        let mid = h(.ledge(2, index: 0), 150, 400, 180)
        let low = h(.ledge(3, index: 0), 0, 400, 210)
        let g = NavGraph.build(surfaces: [high, mid, low], constants: k)
        // 右端点 x=200 正下方最近的是 mid（y=180），左端点 x=100 正下方是 low（y=210）。
        #expect(kinds(g, high.id, mid.id) == [.drop])
        #expect(kinds(g, high.id, low.id) == [.drop])
        #expect(kinds(g, mid.id, high.id).isEmpty)
        #expect(kinds(g, low.id, high.id).isEmpty)
    }

    @Test("高差超过 Drop_Max_Height 不建往下跳边")
    func dropTooHigh() {
        let high = h(.ledge(1, index: 0), 100, 200, 100)
        let ground = h(.ground, 0, 1000, 900)
        let g = NavGraph.build(surfaces: [high, ground], constants: k)
        #expect(g.edges[high.id] == nil)
        #expect(g.route(from: high.id, at: 150, to: .ground, targetX: 500) == nil)
    }

    @Test("木板连接两个窗口的窗沿，路线经过木板")
    func plankRoute() {
        let a = h(.ledge(1, index: 0), 0, 200, 300)
        let b = h(.ledge(2, index: 0), 300, 500, 320)
        let pid = PlankID(1)
        let plank = Surface(id: .plank(pid), start: Point(x: 180, y: 300), end: Point(x: 320, y: 320))
        let placed = PlacedPlank(id: pid, endA: PlankEnd(window: 1, offset: 180), endB: PlankEnd(window: 2, offset: 20))
        let without = NavGraph.build(surfaces: [a, b], constants: k)
        #expect(without.route(from: a.id, at: 50, to: b.id, targetX: 400) == nil)

        let g = NavGraph.build(surfaces: [a, b, plank], planks: [placed], constants: k)
        #expect(kinds(g, a.id, plank.id).contains(.plank))
        #expect(kinds(g, plank.id, b.id).contains(.plank))
        let r = g.route(from: a.id, at: 50, to: b.id, targetX: 400)
        #expect(r != nil)
        if let r {
            #expect(r.steps.first?.from == a.id)
            #expect(r.steps.last?.to == b.id)
            #expect(r.steps.contains { $0.to == plank.id })
            #expect(g.isValid(r, from: a.id))
        }
    }

    @Test("梯子建双向爬梯边，把 Ground 接回窗沿")
    func ladderRoute() {
        let ledge = h(.ledge(1, index: 0), 100, 300, 700)
        let ground = h(.ground, 0, 1000, 880)
        let lid = LadderID(7)
        let ladder = NavLadder(id: lid, bottomSurface: .ground, bottom: Point(x: 150, y: 880),
                               topSurface: ledge.id, top: Point(x: 150, y: 700))
        let without = NavGraph.build(surfaces: [ledge, ground], constants: k)
        #expect(without.route(from: .ground, at: 500, to: ledge.id, targetX: 200) == nil)

        let g = NavGraph.build(surfaces: [ledge, ground], ladders: [ladder], constants: k)
        #expect(kinds(g, .ground, ledge.id) == [.ladder(lid)])
        #expect(kinds(g, ledge.id, .ground) == [.ladder(lid)])
        let r = g.route(from: .ground, at: 500, to: ledge.id, targetX: 200)
        #expect(r?.steps.map(\.kind) == [.ladder(lid)])
    }

    @Test("同一 Surface 的路线没有步骤；建图与寻路结果确定")
    func sameSurfaceAndDeterminism() {
        let a = h(.ledge(1, index: 0), 0, 100, 200)
        let b = h(.ledge(2, index: 0), 100, 200, 200)
        let c = h(.ledge(3, index: 0), 210, 300, 190)
        let g1 = NavGraph.build(surfaces: [a, b, c], constants: k)
        let g2 = NavGraph.build(surfaces: [c, b, a], constants: k)
        #expect(g1 == g2)
        #expect(g1.route(from: a.id, at: 10, to: a.id, targetX: 90)?.steps.isEmpty == true)
        #expect(g1.route(from: a.id, at: 10, to: c.id, targetX: 250) == g2.route(from: a.id, at: 10, to: c.id, targetX: 250))
        #expect(g1.isReachable(from: a.id, to: c.id))
    }

    @Test("边从图中移除后旧路线失效")
    func routeInvalidation() {
        let a = h(.ledge(1, index: 0), 0, 100, 200)
        let b = h(.ledge(2, index: 0), 100, 200, 200)
        let g = NavGraph.build(surfaces: [a, b], constants: k)
        let r = g.route(from: a.id, at: 10, to: b.id, targetX: 150)!
        #expect(g.isValid(r, from: a.id))
        let moved = h(.ledge(2, index: 0), 150, 250, 200)
        let g2 = NavGraph.build(surfaces: [a, moved], constants: k)
        #expect(!g2.isValid(r, from: a.id))
        #expect(g.topologyHash != g2.topologyHash)
    }
}
