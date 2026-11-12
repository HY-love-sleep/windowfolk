import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 8.4：WorldEngine 接入通路图、桥上悬挂与第二位居民的单元测试。
struct BridgeHangTests {
    static let screen = ResidentFollowAndFallTests.screen
    static func win(_ id: WindowID, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WindowSnapshot {
        ResidentFollowAndFallTests.win(id, x: x, y: y, w: w, h: h)
    }
    static let dt = 1.0 / 30

    final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now = Date(timeIntervalSince1970: 2_000_000)

        init(_ windows: [WindowSnapshot], demo: Bool = false) {
            engine = WorldEngine(clockStart: now, screen: BridgeHangTests.screen,
                                 rng: RandomSource(seed: 11), demoResident: demo)
            source = FakeWindowSource(windows: windows.map { FakeWindow(snapshot: $0) })
        }

        @discardableResult
        func step(_ commands: [Command] = [], sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            now = now.addingTimeInterval(BridgeHangTests.dt)
            let out = engine.step(FrameInput(poll: source.poll(), screen: BridgeHangTests.screen,
                                             commands: commands, now: now))
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())",
                    sourceLocation: sourceLocation)
            return out
        }

        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }
        func position(_ id: ResidentID, _ out: StepOutput) -> Point? {
            out.view.residents.first { $0.id == id }?.position
        }
    }

    /// 两个窗口上沿 y = 300，之间 100pt 的间隙，架一块木板（x 400 → 500）。
    static func bridgeScene() -> (Harness, PlankID) {
        let h = Harness([win(1, 100, 300, 300, 300), win(2, 500, 300, 300, 300)])
        let pid = h.engine.insertPlank(.placed(PlacedPlank(
            id: PlankID(0), endA: PlankEnd(window: 1, offset: 300), endB: PlankEnd(window: 2, offset: 0))))
        return (h, pid)
    }

    /// 不会自己闲逛的居民（很长的停顿）。`Attachment` 与 Testing.Attachment 重名，所以分开写两个构造函数。
    static func idle(_ id: ResidentID, window: WindowID, offset: Double, held: ItemID? = nil) -> Resident {
        Resident(id: id, attachment: .window(window, offset: offset), heldItem: held,
                 wander: WanderState(pauseRemaining: 10_000))
    }

    static func idle(_ id: ResidentID, plank: PlankID, t: Double, held: ItemID? = nil) -> Resident {
        Resident(id: id, attachment: .plank(plank, t: t), heldItem: held,
                 wander: WanderState(pauseRemaining: 10_000))
    }

    // MARK: - 桥上悬挂（Requirement 13.1 至 13.4、13.7）

    @Test func residentOnFailingPlankHangsThenFalls() {
        let (h, pid) = Self.bridgeScene()
        let item = ItemID()
        h.engine.place(Self.idle(.a, plank: pid, t: 0.5, held: item))
        h.engine.place(Self.idle(.b, window: 1, offset: 300))     // 木板端点所在的窗沿上
        var out = h.step()
        #expect(h.position(.a, out) == Point(x: 450, y: 300))

        // 把右窗口拖远：木板超长失效。
        h.source.move(2, to: Point(x: 900, y: 300))
        out = h.step()
        #expect(out.failedPlanks == [pid])
        #expect(h.resident(.a).state == .hanging)
        #expect(h.resident(.a).heldItem == item)
        #expect(h.position(.a, out) == Point(x: 450, y: 300))
        // 窗沿上的居民不受影响。
        #expect(h.resident(.b).state == .idle)
        #expect(h.resident(.b).attachment == .window(1, offset: 300))

        var frames = 0
        while h.resident(.a).state == .hanging, frames < 200 {
            out = h.step()
            frames += 1
            if h.resident(.a).state == .hanging {
                #expect(h.position(.a, out) == Point(x: 450, y: 300))
                #expect(h.resident(.a).route == nil)
            }
        }
        let hung = Double(frames) * Self.dt
        #expect(abs(hung - Tunables().hangDuration) <= 0.1, "hung \(hung)s")
        #expect(h.resident(.a).state == .falling)
        #expect(h.resident(.a).heldItem == item)

        for _ in 0 ..< 90 where h.resident(.a).state == .falling { h.step() }
        #expect(h.resident(.a).attachment == .ground(x: 450))
        #expect(h.resident(.a).heldItem == item)
    }

    @Test func everyResidentOnPlankHangsFromSameFrame() {
        let (h, pid) = Self.bridgeScene()
        h.engine.place(Self.idle(.a, plank: pid, t: 0.25))
        h.engine.place(Self.idle(.b, plank: pid, t: 0.75))
        h.step()
        h.source.close(2)
        h.step()
        #expect(h.resident(.a).state == .hanging && h.resident(.b).state == .hanging)
        for _ in 0 ..< 60 { h.step() }
        #expect(h.resident(.a).state != .hanging && h.resident(.b).state != .hanging)
    }

    // MARK: - 通路图与「让都都去找嘟嘟」（Requirement 12.1、5.5、26.2）

    @Test func debugSeekCrossesBridgeToResidentB() {
        let (h, pid) = Self.bridgeScene()
        h.engine.place(Self.idle(.a, window: 1, offset: 100))     // x 200
        h.engine.place(Self.idle(.b, window: 2, offset: 150))     // x 650
        h.step()
        #expect(h.engine.state.nav.nodes[.plank(pid)] != nil)

        h.step([.debugSeek])
        #expect(h.resident(.a).goal == .reach(.b))
        var crossed = false
        for _ in 0 ..< 600 {
            h.step()
            if case .plank = h.resident(.a).attachment { crossed = true }
            if case .window(2, _) = h.resident(.a).attachment, h.resident(.a).route == nil { break }
        }
        #expect(crossed)
        guard case let .window(2, offset) = h.resident(.a).attachment else {
            Issue.record("A did not reach window 2: \(h.resident(.a).attachment)")
            return
        }
        #expect(abs(offset - 150) <= ResidentController.arriveTolerance + 1e-9)
    }

    @Test func hiddenWindowIsExcludedFromNavGraph() {
        let (h, pid) = Self.bridgeScene()
        h.engine.place(Self.idle(.a, window: 1, offset: 100))
        h.step()
        #expect(h.engine.state.nav.nodes[.ledge(2, index: 0)] != nil)
        h.source.hide(2)
        h.step()
        #expect(h.engine.state.nav.nodes[.ledge(2, index: 0)] == nil)
        #expect(h.engine.state.nav.nodes[.plank(pid)] == nil)
        h.source.show(2)
        h.step()
        #expect(h.engine.state.nav.nodes[.plank(pid)] != nil)
    }

    @Test func seekWaitsWhenUnreachable() {
        let h = Harness([Self.win(1, 100, 300, 300, 300), Self.win(2, 900, 300, 300, 300)])
        h.engine.place(Self.idle(.a, window: 1, offset: 100))
        h.engine.place(Self.idle(.b, window: 2, offset: 100))
        h.step([.debugSeek])
        h.step()
        #expect(h.resident(.a).state == .waiting)
        #expect(h.resident(.a).bubble == .dots)
    }

    // MARK: - 演示居民

    @Test func demoPlacesBothResidentsOnDifferentWindows() {
        let h = Harness([Self.win(1, 100, 300, 300, 300), Self.win(2, 900, 300, 300, 300)], demo: true)
        h.step()
        guard case let .window(wa, _) = h.resident(.a).attachment,
              case let .window(wb, _) = h.resident(.b).attachment else {
            Issue.record("expected both on windows")
            return
        }
        #expect(wa != wb)
    }

    @Test func demoWithoutWindowsPlacesBothOnGround() {
        let h = Harness([], demo: true)
        h.step()
        guard case let .ground(xa) = h.resident(.a).attachment,
              case let .ground(xb) = h.resident(.b).attachment else {
            Issue.record("expected both on ground")
            return
        }
        #expect(xa != xb)
    }
}
