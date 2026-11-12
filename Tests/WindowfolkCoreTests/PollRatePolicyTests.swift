import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 一个随机活动样本：时间增量（可回拨）、三项标记，以及偶尔出现的非有限时间。
private struct SampleSpec: Sendable {
    var delta: Double
    var windowsChanged: Bool
    var residentsChanged: Bool
    var dragging: Bool
    var nonFinite: Bool
}

/// 引擎级用例：0 或 1 个窗口、帧间隔、唤醒动作和拖拽保持时长。
private struct EngineCase: Sendable {
    var windowCount: Int
    var origin: Point
    var size: Double
    var dts: [Double]          // 静止阶段每帧间隔
    var action: Int            // 唤醒动作
    var pointer: Point         // 鼠标按下位置（action 为按下时）
    var holdSeconds: Double    // 拖拽保持静止的时长
}

private extension Gen where Value == SampleSpec {
    static var sampleSpec: Generator<SampleSpec, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...9),
            Gen<Double>.double(in: 0...0.8),
            Gen<Bool>.bool(0.15),
            Gen<Bool>.bool(0.15),
            Gen<Bool>.bool(0.15),
            Gen<Bool>.bool(0.03)
        ).map { kind, magnitude, w, r, d, nf in
            // 约 10% 回拨，其余前进；前进幅度偏小，以便出现长段安静
            let delta = kind == 0 ? -magnitude * 3 : magnitude * 0.5
            return SampleSpec(delta: delta, windowsChanged: w, residentsChanged: r, dragging: d, nonFinite: nf)
        }
    }
}

private extension Gen where Value == EngineCase {
    static var engineCase: Generator<EngineCase, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...1),
            // 中心点始终在主显示器内，窗口一定是 Eligible_Window
            zip(Gen<Int>.int(in: 0...100), Gen<Int>.int(in: 6...50)),
            Gen<Int>.int(in: 15...60),
            Gen<Double>.double(in: (1.0 / 30)...0.1).array(of: 30...80),
            Gen<Int>.int(in: 0...5),
            zip(Gen<Int>.int(in: 0...1439), Gen<Int>.int(in: 0...899)),
            Gen<Double>.double(in: 2.1...3.5)
        ).map { count, grid, size, dts, action, p, hold in
            EngineCase(
                windowCount: count,
                origin: Point(x: Double(grid.0) * 8, y: Double(grid.1) * 8),
                size: Double(size) * 8,
                dts: dts, action: action,
                pointer: Point(x: Double(p.0), y: Double(p.1)),
                holdSeconds: hold)
        }
    }
}

struct PollRatePolicyTests {
    /// 参考模型（Requirement 24.1 至 24.6）：取以第 i 个样本结尾、全部安静且时间有限的最长连续样本段 [j, i]，
    /// 第 i 个样本之后为 idle 当且仅当 time[i] − min(time[j...i]) ≥ 2 秒。
    /// 从段内最早的读数起算，时间回拨只会推迟而不会提前进入 idle；不安静或非有限的样本截断这一段。
    static func reference(_ samples: [ActivitySample], quiet: Double) -> [PollRate] {
        samples.indices.map { i in
            let s = samples[i]
            guard s.isQuiet, s.time.isFinite else { return .active }
            var j = i
            while j > 0, samples[j - 1].isQuiet, samples[j - 1].time.isFinite { j -= 1 }
            let earliest = samples[j...i].map(\.time).min()!
            return s.time - earliest >= quiet ? .idle : .active
        }
    }

    // Feature: v1, Property 41: 轮询频率策略
    // **Validates: Requirements 24.2, 24.3, 24.4, 24.5, 24.6, 29.2**
    @Test func pollRatePolicyMatchesReference() async {
        await propertyCheck(count: 100, input: Gen.sampleSpec.array(of: 0...80)) { specs in
            var t = 1_000.0
            let samples: [ActivitySample] = specs.map { spec in
                t += spec.delta
                return ActivitySample(
                    time: spec.nonFinite ? .nan : t,
                    windowsChanged: spec.windowsChanged,
                    residentsChanged: spec.residentsChanged,
                    dragging: spec.dragging)
            }
            let expected = Self.reference(samples, quiet: PollRatePolicy.defaultQuietDuration)

            var policy = PollRatePolicy()
            #expect(policy.current == .active)   // 启动时为 active（Requirement 24.1）
            for (i, s) in samples.enumerated() {
                let rate = policy.next(after: s)
                #expect(rate == expected[i], "sample \(i): \(s)")
                #expect(policy.current == rate)
                // 任一活动标记（含拖拽）都让下一周期为 active（Requirement 24.3 至 24.6）
                if !s.isQuiet { #expect(rate == .active) }
            }
        }
    }

    // MARK: - 引擎级

    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))

    private struct Harness {
        var engine: WorldEngine
        var source: FakeWindowSource
        var now = Date(timeIntervalSince1970: 1_000_000)

        init(windows: [WindowSnapshot]) {
            engine = WorldEngine(clockStart: now, screen: PollRatePolicyTests.screen,
                                 rng: RandomSource(seed: 7), demoResident: false)
            source = FakeWindowSource(windows: windows.map { FakeWindow(snapshot: $0) })
        }

        mutating func step(_ dt: Double, pointer: [PointerEvent] = []) -> PollRate {
            now = now.addingTimeInterval(dt)
            return engine.step(FrameInput(poll: source.poll(), screen: PollRatePolicyTests.screen,
                                          pointer: pointer, now: now)).nextRate
        }
    }

    // Feature: v1, Property 41: 轮询频率策略
    // **Validates: Requirements 24.2, 24.3, 24.4, 24.5, 24.6, 29.2**
    @Test func engineIdlesOnStaticDesktopAndWakesOnActivity() async {
        await propertyCheck(count: 100, input: Gen.engineCase) { c in
            let w = WindowSnapshot(
                id: 1, ownerName: "App", ownerPID: 321,
                frame: Rect(minX: c.origin.x, minY: c.origin.y, width: c.size, height: c.size), zIndex: 0)
            var h = Harness(windows: c.windowCount == 1 ? [w] : [])

            // 启动帧（窗口首次出现、尚无上一帧画面）为 active（Requirement 24.1）
            #expect(h.step(c.dts[0]) == .active)

            // 静止桌面：从第一个安静帧起满 2 秒恰好转为 idle，此前保持 active（Requirement 24.2、29.2）
            var quietStart: Date?
            var sawIdle = false
            for dt in c.dts.dropFirst() {
                let rate = h.step(dt)
                let start = quietStart ?? h.now
                quietStart = start
                let expected: PollRate = h.now.timeIntervalSince(start) >= 2 ? .idle : .active
                #expect(rate == expected, "t=\(h.now.timeIntervalSince(start))")
                if rate == .idle { sawIdle = true }
            }
            guard sawIdle else { return }   // dts 总长不足 2 秒时只检查上面的 active 部分

            // 唤醒：任一窗口变化或鼠标事件，紧接着的输出为 active（Requirement 24.3、24.5）
            let dt = 1.0 / 30
            let rate: PollRate
            switch c.windowCount == 0 && c.action < 4 ? 4 + c.action % 2 : c.action {
            case 0:
                h.source.move(1, to: Point(x: c.origin.x + 16, y: c.origin.y))
                rate = h.step(dt)
            case 1:
                h.source.resize(1, to: (c.size + 8, c.size))
                rate = h.step(dt)
            case 2:
                h.source.hide(1)
                rate = h.step(dt)
            case 3:
                h.source.close(1)
                rate = h.step(dt)
            case 4:
                h.source.add(WindowSnapshot(
                    id: 2, ownerName: "Other", ownerPID: 654,
                    frame: Rect(minX: 600, minY: 200, width: 200, height: 200), zIndex: 0))
                rate = h.step(dt)
            default:
                rate = h.step(dt, pointer: [.down(c.pointer), .up(c.pointer)])
            }
            #expect(rate == .active)

            // 拖拽进行中鼠标静止超过 2 秒仍为 active（Requirement 24.6）
            var g = Harness(windows: c.windowCount == 1 ? [w] : [])
            for d in c.dts { _ = g.step(d) }
            let box = ToolboxLayout.zoneFrame(.plank, screen: Self.screen)
            let press = Point(x: box.minX + box.width / 2, y: box.minY + box.height / 2)
            #expect(g.step(dt, pointer: [.down(press), .moved(Point(x: press.x - 40, y: press.y - 200))]) == .active)
            #expect(g.engine.state.gesture.isActive)
            var elapsed = 0.0
            while elapsed < c.holdSeconds {
                elapsed += 0.1
                #expect(g.step(0.1) == .active)
            }
        }
    }
}
