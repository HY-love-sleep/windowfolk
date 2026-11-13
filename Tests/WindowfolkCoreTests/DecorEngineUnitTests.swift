import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 3.1：Decor 接入世界更新（跟随、隐藏、关闭与失效时被动下落、落地）和 Unlocked_Decor 进入 WorldView
/// 的单元测试。屏幕 1440×900，Ground y = 825。每次 step 后 Harness 都检查无悬空不变量（含 Decor）。
struct DecorEngineUnitTests {
    typealias H = BridgeHangTests.Harness

    static func decor(_ h: H, _ id: DecorID) -> Decor { h.engine.state.decors.decors[id]! }

    static func chair(_ id: UInt64, _ placement: DecorPlacement) -> Decor {
        Decor(id: DecorID(id), type: .chair, placement: placement)
    }

    /// 推进到 Decor 不再下落为止（最多 3 秒）。
    static func settle(_ h: H, _ id: DecorID) {
        for _ in 0 ..< 90 {
            if case .falling = decor(h, id).placement { h.step() } else { return }
        }
    }

    static func isPassiveFall(_ p: DecorPlacement) -> Bool {
        if case .falling(_, byPlayer: false) = p { return true }
        return false
    }

    // MARK: - 跟随、隐藏、下落（v2 Requirement 3.9、3.12）

    @Test func ledgeDecorFollowsWindowMove() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        h.engine.insertDecor(Self.chair(1, .attached(.window(1, offset: 50))))
        h.step()
        h.source.move(1, to: Point(x: 400, y: 250))
        let out = h.step()
        #expect(Self.decor(h, DecorID(1)).placement == .attached(.window(1, offset: 50)))
        #expect(out.view.decors.first { $0.id == DecorID(1) }?.position == Point(x: 450, y: 250))
    }

    @Test func hiddenWindowKeepsDecorAndClosedWhileHiddenFallsPassively() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        h.engine.insertDecor(Self.chair(1, .attached(.window(1, offset: 70))))
        h.step()
        h.source.hide(1)
        for _ in 0 ..< 30 {
            let out = h.step()
            #expect(!out.view.decors.contains { $0.id == DecorID(1) })
        }
        #expect(Self.decor(h, DecorID(1)).placement == .attached(.window(1, offset: 70)))
        h.source.close(1)
        h.step()
        guard case let .falling(f, byPlayer) = Self.decor(h, DecorID(1)).placement else {
            Issue.record("应下落"); return
        }
        #expect(!byPlayer)
        #expect(f.position.x == 170)
    }

    @Test func closingWindowDropsDecorToGroundAndMarksPlaced() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        h.engine.insertDecor(Self.chair(1, .attached(.window(1, offset: 60))))
        h.step()
        h.source.close(1)
        let out = h.step()
        #expect(Self.isPassiveFall(Self.decor(h, DecorID(1)).placement))
        #expect(out.view.decors.first?.isFalling == true)
        Self.settle(h, DecorID(1))
        #expect(Self.decor(h, DecorID(1)).placement == .attached(.ground(x: 160)))
        #expect(Self.decor(h, DecorID(1)).placedSeq > 0)
    }

    @Test func fullyCoveredLedgeDropsDecorToLowerLedge() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200), BridgeHangTests.win(3, 100, 600, 300, 150)])
        h.engine.insertDecor(Self.chair(1, .attached(.window(1, offset: 100))))
        h.step()
        h.source.add(BridgeHangTests.win(2, 50, 250, 400, 200))
        h.source.bringToFront(2)
        h.step()
        #expect(Self.isPassiveFall(Self.decor(h, DecorID(1)).placement))
        Self.settle(h, DecorID(1))
        #expect(Self.decor(h, DecorID(1)).placement == .attached(.window(3, offset: 100)))
    }

    @Test func failingPlankDropsDecorOnItPassively() {
        let (h, pid) = BridgeHangTests.bridgeScene()
        h.engine.insertDecor(Self.chair(1, .attached(.plank(pid, t: 0.5))))
        var out = h.step()
        #expect(out.view.decors.first { $0.id == DecorID(1) }?.position == Point(x: 450, y: 300))
        h.source.move(2, to: Point(x: 900, y: 300))
        out = h.step()
        #expect(out.failedPlanks == [pid])
        guard case let .falling(f, byPlayer) = Self.decor(h, DecorID(1)).placement else {
            Issue.record("应下落"); return
        }
        #expect(!byPlayer)
        #expect(f.position.x == 450)
        Self.settle(h, DecorID(1))
        #expect(Self.decor(h, DecorID(1)).placement == .attached(.ground(x: 450)))
    }

    @Test func fallingDecorLandsOnPlacedPlank() {
        let (h, pid) = BridgeHangTests.bridgeScene()
        h.engine.insertDecor(Self.chair(1, .falling(FallState(position: Point(x: 450, y: 100)), byPlayer: false)))
        h.step()
        Self.settle(h, DecorID(1))
        #expect(Self.decor(h, DecorID(1)).placement == .attached(.plank(pid, t: 0.5)))
    }

    @Test func unsupportedDecorFallsPassivelyAndLandsOnGround() {
        let h = H([])
        h.engine.insertDecor(Self.chair(1, .attached(.ground(x: 5000))))
        h.step()
        // Ground 之外的 Decor 违反无悬空不变量，本帧末转为被动下落，x 夹紧到屏幕内。
        #expect(Self.isPassiveFall(Self.decor(h, DecorID(1)).placement))
        Self.settle(h, DecorID(1))
        guard case let .attached(.ground(x)) = Self.decor(h, DecorID(1)).placement else {
            Issue.record("应落在 Ground 上"); return
        }
        #expect(x <= BridgeHangTests.screen.frame.maxX)
    }

    // MARK: - 不影响通路（v2 Requirement 3.11）

    @Test func decorsDoNotChangeNavGraphOrSurfaces() {
        let windows = [BridgeHangTests.win(1, 100, 300, 300, 200), BridgeHangTests.win(2, 500, 300, 300, 200)]
        let plain = H(windows)
        let decorated = H(windows)
        for (i, offset) in [10.0, 10, 150, 299].enumerated() {
            decorated.engine.insertDecor(Self.chair(UInt64(i + 1), .attached(.window(1, offset: offset))))
        }
        decorated.engine.insertDecor(Self.chair(9, .attached(.ground(x: 450))))
        let a = plain.step(), b = decorated.step()
        #expect(a.view.surfaces == b.view.surfaces)
        #expect(plain.engine.state.nav == decorated.engine.state.nav)
        #expect(b.view.decors.count == 5)
    }

    // MARK: - Unlocked_Decor 进入 WorldView 与命中区域（v2 Requirement 2.1、2.2）

    @Test func unlockedDecorDrivesToolboxLayoutAndHitRegions() {
        let h = H([])
        h.engine.unlockDecor(.lamp)
        h.engine.unlockDecor(.chair)
        let view = h.step().view
        let unlocked: Set<DecorType> = [.chair, .lamp]
        #expect(view.unlockedDecor == unlocked)
        #expect(view.toolbox == ToolboxLayout.frame(screen: view.screen, unlocked: unlocked))
        #expect(view.toolbox.width == ToolboxLayout.zoneWidth * 4)

        let zones = view.hitRegions.compactMap { r -> ToolboxZone? in
            if case let .toolbox(z) = r.target { return z }
            return nil
        }
        #expect(zones == [.plank, .ladder, .decor(.chair), .decor(.lamp)])
        #expect(HitTesting.regions(for: view).filter {
            if case .toolbox = $0.target { return true }
            return false
        } == view.hitRegions.filter {
            if case .toolbox = $0.target { return true }
            return false
        })

        // 外框向左变宽后，Plank 区中心仍命中 Plank 区。
        let plank = ToolboxLayout.zoneFrame(.plank, screen: view.screen, unlocked: unlocked)!
        let center = Point(x: plank.midX, y: plank.midY)
        #expect(HitTesting.hitTest(center, world: view) == .toolbox(.plank))
        let context = InteractionContext(
            screen: view.screen, windows: WindowTable(), surfaces: view.surfaces, hitRegions: view.hitRegions,
            unlockedDecor: view.unlockedDecor)
        #expect(InteractionController.hitTest(center, context: context) == .toolbox(.plank))
    }

    @Test func emptyUnlockedDecorKeepsV1Toolbox() {
        let h = H([])
        let view = h.step().view
        #expect(view.unlockedDecor.isEmpty)
        #expect(view.toolboxShake == nil)
        #expect(view.toolbox == ToolboxLayout.frame(screen: view.screen, unlocked: []))
    }
}
