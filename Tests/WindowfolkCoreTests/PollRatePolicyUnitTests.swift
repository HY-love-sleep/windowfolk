import Foundation
import Testing
@testable import WindowfolkCore

/// PollRatePolicy 与 WorldEngine 频率输出的单元测试（任务 17.1）。属性测试见任务 17.3。
struct PollRatePolicyUnitTests {
    private func quiet(_ t: Double) -> ActivitySample {
        ActivitySample(time: t, windowsChanged: false, residentsChanged: false, dragging: false)
    }

    @Test func startsActiveAndGoesIdleAfterTwoQuietSeconds() {
        var p = PollRatePolicy()
        #expect(p.current == .active)
        #expect(p.next(after: quiet(0)) == .active)
        #expect(p.next(after: quiet(1.9)) == .active)
        #expect(p.next(after: quiet(2.0)) == .idle)
        #expect(p.next(after: quiet(5)) == .idle)
    }

    @Test func anyActivityReturnsToActiveAndRestartsQuietTimer() {
        for flags in [(true, false, false), (false, true, false), (false, false, true)] {
            var p = PollRatePolicy()
            _ = p.next(after: quiet(0))
            #expect(p.next(after: quiet(3)) == .idle)
            let busy = ActivitySample(time: 3.1, windowsChanged: flags.0, residentsChanged: flags.1, dragging: flags.2)
            #expect(p.next(after: busy) == .active)
            #expect(p.next(after: quiet(3.2)) == .active)
            #expect(p.next(after: quiet(5.1)) == .active)
            #expect(p.next(after: quiet(5.2)) == .idle)
        }
    }

    @Test func continuousDragStaysActive() {
        var p = PollRatePolicy()
        for i in 0...100 {
            let s = ActivitySample(time: Double(i) * 0.1, windowsChanged: false, residentsChanged: false, dragging: true)
            #expect(p.next(after: s) == .active)
        }
    }

    @Test func clockGoingBackwardRestartsQuietTimer() {
        var p = PollRatePolicy()
        _ = p.next(after: quiet(10))
        #expect(p.next(after: quiet(5)) == .active)
        #expect(p.next(after: quiet(6.9)) == .active)
        #expect(p.next(after: quiet(7)) == .idle)
    }

    // MARK: - WorldEngine

    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))

    private struct Harness {
        var engine: WorldEngine
        var source: FakeWindowSource
        var now = Date(timeIntervalSince1970: 1_000_000)

        init(windows: [WindowSnapshot]) {
            engine = WorldEngine(clockStart: now, screen: PollRatePolicyUnitTests.screen,
                                 rng: RandomSource(seed: 3), demoResident: false)
            source = FakeWindowSource(windows: windows.map { FakeWindow(snapshot: $0) })
        }

        mutating func step(_ dt: Double = 0.1, pointer: [PointerEvent] = []) -> PollRate {
            now = now.addingTimeInterval(dt)
            return engine.step(FrameInput(poll: source.poll(), screen: PollRatePolicyUnitTests.screen,
                                          pointer: pointer, now: now)).nextRate
        }
    }

    private static func window(_ id: WindowID, x: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App", ownerPID: 200 + Int32(id),
                       frame: Rect(minX: x, minY: 300, width: 400, height: 300), zIndex: 0)
    }

    @Test func staticDesktopGoesIdleAndWindowMoveWakesNextPoll() {
        var h = Harness(windows: [Self.window(1, x: 100)])
        #expect(h.step() == .active)
        var rate = PollRate.active
        for _ in 0..<25 { rate = h.step() }
        #expect(rate == .idle)
        h.source.move(1, to: Point(x: 160, y: 300))
        #expect(h.step() == .active)
    }

    @Test func pointerActivityKeepsActive() {
        var h = Harness(windows: [Self.window(1, x: 100)])
        for _ in 0..<25 { _ = h.step() }
        #expect(h.step() == .idle)
        // 空白处的按下：Toolbox 之外，不开始手势，但本帧有鼠标事件。
        #expect(h.step(pointer: [.down(Point(x: 700, y: 100))]) == .active)
    }

    @Test func walkingResidentKeepsActive() {
        var h = Harness(windows: [Self.window(1, x: 100)])
        var r = Resident(id: .a, attachment: .window(1, offset: 200))
        r.state = .walking
        h.engine.place(r)
        _ = h.step()
        var sawIdle = false
        for _ in 0..<40 where h.step() == .idle {
            if let s = h.engine.state.residents[.a]?.state, WorldEngine.activeResidentStates.contains(s) {
                sawIdle = true
            }
        }
        #expect(!sawIdle)
    }
}
