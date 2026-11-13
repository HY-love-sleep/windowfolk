import Foundation
import Testing
@testable import WindowfolkCore

@Suite("ChaseRules 单元测试")
struct ChaseRulesUnitTests {
    let k = Tunables()

    func h(_ id: SurfaceID, _ x0: Double, _ x1: Double, _ y: Double) -> Surface {
        Surface(id: id, start: Point(x: x0, y: y), end: Point(x: x1, y: y))
    }

    @Test("候选点：长线段两端内收，短线段取中点，不可达 Surface 不出候选，按 (SurfaceID, x) 排序")
    func candidatePoints() {
        let ground = h(.ground, 0, 1000, 880)
        let short = h(.ledge(1, index: 0), 500, 516, 700)    // 长度 16 = 2 × 8 → 中点（梯子可达）
        let far = h(.ledge(2, index: 0), 2000, 2100, 100)    // 不连通
        let ladder = NavLadder(id: LadderID(1), bottomSurface: .ground, bottom: Point(x: 508, y: 880),
                               topSurface: short.id, top: Point(x: 508, y: 700))
        let g = NavGraph.build(surfaces: [ground, short, far], ladders: [ladder], constants: k)
        let field = g.horizontalField(from: .ground, at: 100)
        #expect(field.isReachable(short.id))

        let c = ChaseRules.candidates(runnerField: field, surfaces: [far, short, ground], inset: 8)
        #expect(c == [FleePoint(surface: .ground, x: 8), FleePoint(surface: .ground, x: 992),
                      FleePoint(surface: short.id, x: 508)])
    }

    @Test("Flee_Target：Chaser 距离最远者优先，不可达视为最远，并列取 Runner 更近、再取 x 较小")
    func selection() {
        let ground = h(.ground, 0, 1000, 880)
        let g = NavGraph.build(surfaces: [ground], constants: k)
        let runnerField = g.horizontalField(from: .ground, at: 500)
        let pts = ChaseRules.candidates(runnerField: runnerField, surfaces: [ground], inset: 8)

        // Chaser 在 400：到 8 是 392，到 992 是 592 → 选 992。
        let chaser = g.horizontalField(from: .ground, at: 400)
        #expect(ChaseRules.selectFleeTarget(pts, chaserField: chaser, runnerField: runnerField)
                == FleePoint(surface: .ground, x: 992))

        // Chaser 在 500：两点都 492；Runner 在 600 时 992 更近。
        let mid = g.horizontalField(from: .ground, at: 500)
        let r600 = g.horizontalField(from: .ground, at: 600)
        #expect(ChaseRules.selectFleeTarget(pts, chaserField: mid, runnerField: r600)
                == FleePoint(surface: .ground, x: 992))
        // 两项都并列 → x 较小。
        #expect(ChaseRules.selectFleeTarget(pts, chaserField: mid, runnerField: runnerField)
                == FleePoint(surface: .ground, x: 8))

        // Chaser 不可达的候选视为最远。
        let island = h(.ledge(2, index: 0), 2000, 2100, 100)
        let lone = FleePoint(surface: island.id, x: 2050)
        #expect(ChaseRules.selectFleeTarget(pts + [lone], chaserField: chaser, runnerField: runnerField) == lone)

        #expect(ChaseRules.selectFleeTarget([], chaserField: chaser, runnerField: runnerField) == nil)
    }

    @Test("抓到判定：同一 Surface、距离 ≤ 16（含边界），排除空中状态、隐藏窗口和没有位置")
    func caught() {
        let a = ResidentLocation(surface: .ground, x: 100)
        func caught(_ r: ResidentLocation?, _ cs: ResidentState = .running, _ rs: ResidentState = .running,
                    hidden: Set<ResidentID> = []) -> Bool {
            ChaseRules.isCaught(chaser: a, runner: r, chaserState: cs, runnerState: rs, hidden: hidden, distance: 16)
        }
        #expect(caught(ResidentLocation(surface: .ground, x: 116)))
        #expect(caught(ResidentLocation(surface: .ground, x: 84), .waiting, .idle))
        #expect(!caught(ResidentLocation(surface: .ground, x: 116.5)))
        #expect(!caught(ResidentLocation(surface: .ledge(1, index: 0), x: 100)))
        #expect(!caught(nil))
        for s in [ResidentState.falling, .hanging, .climbing] {
            #expect(!caught(ResidentLocation(surface: .ground, x: 100), s, .running))
            #expect(!caught(ResidentLocation(surface: .ground, x: 100), .running, s))
        }
        #expect(!caught(ResidentLocation(surface: .ground, x: 100), hidden: [.b]))
        #expect(!caught(ResidentLocation(surface: .ground, x: 100), hidden: [.a]))
    }
}
