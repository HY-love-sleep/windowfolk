import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 17.4：主显示器分辨率或 `visibleFrame` 变化后，Ground 上的对象夹紧到新 Ground 内（Requirement 23.8），
/// 窗口上的对象保持原 offset（Requirement 23.7）。
struct DisplayChangeTests {
    /// 1440×900，Ground y = 825。
    static let large = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))
    /// 1280×800，Ground y = 725。
    static let small = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1280, height: 800),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1280, height: 700))
    /// 1440×900，Dock 在左侧（宽 80），Ground x 范围 [80, 1440]。
    static let leftDock = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 80, minY: 25, width: 1360, height: 875))

    final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        var screen: ScreenInfo
        var now = Date(timeIntervalSince1970: 3_000_000)

        init(_ windows: [WindowSnapshot] = [], screen: ScreenInfo = DisplayChangeTests.large) {
            self.screen = screen
            engine = WorldEngine(clockStart: now, screen: screen, rng: RandomSource(seed: 5), demoResident: false)
            source = FakeWindowSource(windows: windows.map { FakeWindow(snapshot: $0) })
        }

        @discardableResult
        func step(sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            now = now.addingTimeInterval(1.0 / 30)
            let out = engine.step(FrameInput(poll: source.poll(), screen: screen, now: now))
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())",
                    sourceLocation: sourceLocation)
            return out
        }
    }

    static func still(_ id: ResidentID, _ a: CoreAttachment) -> Resident {
        Resident(id: id, attachment: a, wander: WanderState(pauseRemaining: 10_000))
    }

    @Test func groundObjectsOutsideNewGroundMoveFullyOnScreen() {
        let h = Harness()
        h.engine.place(Self.still(.a, .ground(x: 1400)))
        h.engine.place(Self.still(.b, .ground(x: 500)))
        let fruit = ItemID()
        h.engine.insertItem(.fruit(id: fruit, placement: .attached(.ground(x: 1430))))
        let plank = h.engine.insertPlank(.loose(.ground(x: 1420)))
        let ladder = h.engine.insertLadder(.loose(.ground(x: 1300)))
        h.step()

        h.screen = Self.small
        let out = h.step()
        let s = h.engine.state
        let halfResident = SpriteMetrics.resident.width / 2
        #expect(s.residents[.a]?.attachment == .ground(x: 1280 - halfResident))
        // 原本就完整位于新 Ground 内的对象不动。
        #expect(s.residents[.b]?.attachment == .ground(x: 500))
        #expect(s.items[fruit]?.placement == .attached(.ground(x: 1280 - SpriteMetrics.fruit.width / 2)))
        #expect(s.planks.planks[plank] == .loose(.ground(x: 1280 - SpriteMetrics.loosePlankLength / 2)))
        #expect(s.ladders.ladders[ladder] == .loose(.ground(x: 1280 - SpriteMetrics.looseLadderLength / 2)))
        // y 跟随新的 Ground。
        #expect(out.view.residents.first { $0.id == .a }?.position == Point(x: 1280 - halfResident, y: 725))
        #expect(out.view.surfaces.first { $0.id == .ground }?.start.y == 725)
    }

    @Test func dockMovingLeftPushesGroundObjectsRight() {
        let h = Harness()
        h.engine.place(Self.still(.a, .ground(x: 10)))
        h.step()
        h.screen = Self.leftDock
        h.step()
        #expect(h.engine.state.residents[.a]?.attachment == .ground(x: 80 + SpriteMetrics.resident.width / 2))
    }

    @Test func windowAttachedObjectsKeepOffset() {
        let w = WindowSnapshot(id: 1, ownerName: "Notes", ownerPID: 42,
                               frame: Rect(minX: 200, minY: 300, width: 400, height: 300), zIndex: 0)
        let h = Harness([w])
        h.engine.place(Self.still(.a, .window(1, offset: 120)))
        let fruit = ItemID()
        h.engine.insertItem(.fruit(id: fruit, placement: .attached(.window(1, offset: 60))))
        h.step()
        h.screen = Self.small
        let out = h.step()
        #expect(h.engine.state.residents[.a]?.attachment == .window(1, offset: 120))
        #expect(h.engine.state.items[fruit]?.placement == .attached(.window(1, offset: 60)))
        #expect(out.view.residents.first { $0.id == .a }?.position == Point(x: 320, y: 300))
    }

    @Test func fallingObjectXClampedToNewGround() {
        let h = Harness()
        let fruit = ItemID()
        h.engine.insertItem(.fruit(id: fruit, placement: .falling(FallState(position: Point(x: 1400, y: 50)))))
        h.step()
        h.screen = Self.small
        h.step()
        guard case let .falling(f)? = h.engine.state.items[fruit]?.placement else {
            Issue.record("应仍在下落")
            return
        }
        #expect(f.position.x == 1280)
        for _ in 0 ..< 90 { h.step() }
        #expect(h.engine.state.items[fruit]?.placement == .attached(.ground(x: 1280)))
    }

    @Test func clampGroundXHandlesNarrowGround() {
        let tiny = ScreenInfo(frame: Rect(minX: 0, minY: 0, width: 20, height: 100),
                              visibleFrame: Rect(minX: 0, minY: 0, width: 20, height: 100))
        #expect(WorldEngine.clampGroundX(500, width: 32, screen: tiny) == 10)
        #expect(WorldEngine.clampGroundX(.nan, width: 32, screen: Self.large) == 16)
    }
}
