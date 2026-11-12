import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 9.3：WorldEngine 接入梯子校验、下落与建图的单元测试。
/// 屏幕 1440×900，Ground y = 825；窗口 1 上沿 y = 700，梯子从 (250, 700) 到 Ground，长 125pt。
struct LadderEngineTests {
    typealias H = BridgeHangTests.Harness
    static let groundY = ResidentFollowAndFallTests.groundY

    static func scene() -> (H, LadderID) {
        let h = H([BridgeHangTests.win(1, 100, 700, 300, 150)])
        let lid = h.engine.insertLadder(.placed(PlacedLadder(
            id: LadderID(0), top: PlankEnd(window: 1, offset: 150),
            bottomSurface: .ground, bottom: Point(x: 250, y: groundY))))
        return (h, lid)
    }

    static func hasLadderEdge(_ nav: NavGraph, _ lid: LadderID) -> Bool {
        nav.allEdges.contains { $0.kind == .ladder(lid) }
    }

    /// 让都都从 Ground 爬梯去找窗沿上的嘟嘟，推进到都都正在爬梯为止。
    static func climbingScene() -> (H, LadderID) {
        let (h, lid) = scene()
        h.engine.place(Resident(id: .a, attachment: .ground(x: 600), wander: WanderState(pauseRemaining: 10_000)))
        h.engine.place(BridgeHangTests.idle(.b, window: 1, offset: 20))
        h.step([.debugSeek])
        for _ in 0 ..< 900 where h.resident(.a).state != .climbing { h.step() }
        // 再爬一会儿，离开梯子下端。
        for _ in 0 ..< 15 { h.step() }
        return (h, lid)
    }

    @Test func validLadderStaysPlacedAndJoinsNavAndView() {
        let (h, lid) = Self.scene()
        let out = h.step()
        guard case let .placed(l)? = h.engine.state.ladders.ladders[lid] else {
            Issue.record("梯子应保持架设"); return
        }
        #expect(l.bottomSurface == .ground && l.bottom == Point(x: 250, y: Self.groundY))
        #expect(out.failedLadders.isEmpty)
        #expect(Self.hasLadderEdge(h.engine.state.nav, lid))
        #expect(out.view.ladders == [LadderView(
            id: lid, shape: .placed(top: Point(x: 250, y: 700), bottom: Point(x: 250, y: Self.groundY)))])
        #expect(out.view.hitRegions.contains { $0.target == .ladder(lid) })
    }

    @Test func bottomFollowsTopWhenWindowMoves() {
        let (h, lid) = Self.scene()
        h.step()
        h.source.move(1, to: Point(x: 300, y: 680))
        let out = h.step()
        let l = h.engine.state.ladders.ladders[lid]?.placed
        #expect(l?.bottom == Point(x: 450, y: Self.groundY))
        #expect(out.view.ladders.first?.shape == .placed(top: Point(x: 450, y: 680),
                                                          bottom: Point(x: 450, y: Self.groundY)))
    }

    @Test func tooLongLadderFailsAndLandsOnGround() {
        let (h, lid) = Self.scene()
        h.step()
        h.source.move(1, to: Point(x: 100, y: 500))   // 竖直距离 325 > Ladder_Length
        let out = h.step()
        #expect(out.failedLadders == [lid])
        #expect(!Self.hasLadderEdge(h.engine.state.nav, lid))
        guard case .falling? = h.engine.state.ladders.ladders[lid] else {
            Issue.record("失效的梯子应下落"); return
        }
        for _ in 0 ..< 90 { h.step() }
        #expect(h.engine.state.ladders.ladders[lid] == .loose(.ground(x: 250)))
    }

    @Test func closingTopWindowFailsLadder() {
        let (h, lid) = Self.scene()
        h.step()
        h.source.close(1)
        let out = h.step()
        #expect(out.failedLadders == [lid])
        guard case let .falling(f)? = h.engine.state.ladders.ladders[lid] else {
            Issue.record("失效的梯子应下落"); return
        }
        #expect(f.position.x == 250)
    }

    @Test func hiddenTopWindowKeepsLadderButHidesIt() {
        let (h, lid) = Self.scene()
        h.step()
        h.source.hide(1)
        let hidden = h.step()
        #expect(hidden.failedLadders.isEmpty)
        #expect(h.engine.state.ladders.ladders[lid]?.placed != nil)
        #expect(hidden.view.ladders.isEmpty)
        #expect(!hidden.view.hitRegions.contains { $0.target == .ladder(lid) })
        #expect(!Self.hasLadderEdge(h.engine.state.nav, lid))
        h.source.show(1)
        let shown = h.step()
        #expect(shown.view.ladders.count == 1)
        #expect(Self.hasLadderEdge(h.engine.state.nav, lid))
    }

    @Test func residentClimbsLadderToReachTarget() {
        let (h, _) = Self.scene()
        h.engine.place(Resident(id: .a, attachment: .ground(x: 600), wander: WanderState(pauseRemaining: 10_000)))
        h.engine.place(BridgeHangTests.idle(.b, window: 1, offset: 20))
        h.step([.debugSeek])
        var climbed = false
        for _ in 0 ..< 900 {
            h.step()
            if h.resident(.a).state == .climbing { climbed = true }
            if case .window(1, _) = h.resident(.a).attachment, h.resident(.a).route == nil { break }
        }
        #expect(climbed)
        guard case .window(1, _) = h.resident(.a).attachment else {
            Issue.record("都都应爬上窗口 1：\(h.resident(.a).attachment)"); return
        }
    }

    @Test func climbingResidentFallsWithoutHangingWhenLadderFails() {
        let (h, lid) = Self.climbingScene()
        guard case let .ladder(onLadder, height) = h.resident(.a).attachment, onLadder == lid,
              h.resident(.a).state == .climbing else {
            Issue.record("都都应在梯子上：\(h.resident(.a).state) \(h.resident(.a).attachment)"); return
        }
        h.source.move(1, to: Point(x: 100, y: 500))
        let out = h.step()
        #expect(out.failedLadders == [lid])
        let a = h.resident(.a)
        #expect(a.state == .falling)
        // 从失效那一刻的屏幕坐标下落（x 为梯子上端 x，y 为下端减去爬过的高度，允许一帧位移）。
        if case let .free(p) = a.attachment {
            #expect(p.x == 250)
            #expect(abs(p.y - (Self.groundY - height)) <= 5)
        } else {
            Issue.record("下落中的居民应为 free：\(a.attachment)")
        }
        // 窗沿上的嘟嘟不受影响。
        #expect(h.resident(.b).state != .falling)
        for _ in 0 ..< 90 { h.step() }
        #expect(h.resident(.a).state != .falling)
    }

    @Test func closingWindowDropsClimbingResident() {
        let (h, lid) = Self.climbingScene()
        #expect(h.resident(.a).state == .climbing)
        h.source.close(1)
        let out = h.step()
        #expect(out.failedLadders == [lid])
        #expect(h.resident(.a).state == .falling)
        #expect(h.resident(.b).state == .falling)
    }

    @Test func looseLadderOnLedgeFollowsWindowAndFallsOnClose() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 300)])
        let lid = h.engine.insertLadder(.loose(.window(1, offset: 100)))
        let first = h.step()
        #expect(first.view.ladders == [LadderView(id: lid, shape: .loose(bottomCenter: Point(x: 200, y: 300)))])
        #expect(first.view.hitRegions.contains { $0.target == .ladder(lid) })
        h.source.move(1, to: Point(x: 200, y: 320))
        let moved = h.step()
        #expect(moved.view.ladders.first?.shape == .loose(bottomCenter: Point(x: 300, y: 320)))
        h.source.close(1)
        h.step()
        guard case .falling? = h.engine.state.ladders.ladders[lid] else {
            Issue.record("窗口关闭后梯子应下落"); return
        }
        for _ in 0 ..< 90 { h.step() }
        #expect(h.engine.state.ladders.ladders[lid] == .loose(.ground(x: 300)))
    }
}
