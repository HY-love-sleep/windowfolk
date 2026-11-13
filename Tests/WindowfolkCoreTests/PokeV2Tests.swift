import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 戳居民扩展状态属性测试（任务 8.9）。
// - Property 16：戳居民的扩展状态（Requirement 5.9、20.9、21.8）。
//
// 每个用例同时运行两台输入相同的 WorldEngine：「点击」模拟按生成的时间序列点击居民，「对照」模拟不点击。
// 两种场景：
// - 睡觉：屏幕 1440×900，窗口 1（x 100 → 700、上沿 y 300），窗沿上放一盏 Lamp，昼夜覆盖为「夜晚」，
//   两位居民自主走到 Lamp 旁进入 `sleeping` 后开始点击；
// - 追逐：沿用 `ChaseTests` 的世界（窗口 1、2 首尾相接、上沿 y 400），从 Debug 触发 Chase_Wish 后开始点击，
//   覆盖 `ready`（2 秒）和 `running`。
// 每帧 0.2 秒（不超过 WorldEngine 的单帧上限 0.25 秒），控制单测耗时。时区固定为 UTC。

// MARK: - 生成器

/// 每帧的点击：`none` 不点，`a` / `b` 点一位，`both` 同一帧先点 A 再点 B。
fileprivate enum PokeClick: Int, Sendable, CustomStringConvertible {
    case none, a, b, both

    var targets: [ResidentID] {
        switch self {
        case .none: []
        case .a: [.a]
        case .b: [.b]
        case .both: [.a, .b]
        }
    }

    var description: String { ["-", "A", "B", "AB"][rawValue] }
}

fileprivate struct PokeCase: Sendable, CustomStringConvertible {
    /// true 为追逐场景，false 为睡觉场景。
    var chase: Bool
    /// 两位居民在窗沿上的比例位置。
    var fracA: Double
    var fracB: Double
    /// 睡觉场景中 Lamp 在窗沿上的比例位置。
    var lampFrac: Double
    /// 追逐场景的 Wisher。
    var wisher: ResidentID
    /// 点击在居民命中矩形内的比例位置。
    var u: Double
    var v: Double
    /// 开始点击后每一帧的点击。
    var clicks: [PokeClick]

    var description: String {
        (chase ? "chase wisher \(wisher)" : "sleep lamp \(lampFrac)")
            + ", A \(fracA), B \(fracB), hit (\(u), \(v)), clicks \(clicks.map(\.description).joined(separator: " "))"
    }
}

fileprivate extension Gen where Value == PokeCase {
    static var pokeCase: Generator<PokeCase, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...1),
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: 0...1),
            Gen<Int>.int(in: 0...1),
            Gen<Double>.double(in: 0.1...0.9),
            Gen<Double>.double(in: 0.1...0.9),
            // 约一半的帧不点击，使「?」气泡既有重置也有自然结束。
            Gen<Int>.int(in: 0...5).map { PokeClick(rawValue: max(0, $0 - 2)) ?? .none }.array(of: 40)
        ).map { chase, fa, fb, lamp, wisher, u, v, clicks in
            PokeCase(chase: chase == 1, fracA: fa, fracB: fb, lampFrac: lamp, wisher: wisher == 0 ? .a : .b,
                     u: u, v: v, clicks: clicks)
        }
    }
}

// MARK: - 模拟

/// 一台 WorldEngine 及其输入。点击模拟和对照模拟各一台，按相同的帧时间推进。
fileprivate final class PokeSim {
    static let dt = 0.2
    static let utc = TimeZone(secondsFromGMT: 0)!

    let engine: WorldEngine
    var source: FakeWindowSource
    var now: Date
    let screen: ScreenInfo

    init(engine: WorldEngine, windows: [WindowSnapshot], now: Date, screen: ScreenInfo) {
        self.engine = engine
        source = FakeWindowSource(snapshots: windows)
        self.now = now
        self.screen = screen
    }

    func step(_ commands: [Command] = [], pointer: [PointerEvent] = []) -> StepOutput {
        now = now.addingTimeInterval(Self.dt)
        return engine.step(FrameInput(poll: source.poll(), screen: screen, pointer: pointer,
                                      commands: commands, now: now, timeZone: Self.utc))
    }
}

// MARK: - 属性测试

@Suite struct PokeV2PropertyTests {
    /// 睡觉场景：屏幕 1440×900，窗口 1 x 100 → 700、上沿 y 300。白天 12:00 UTC，昼夜覆盖改为「夜晚」。
    static let sleepScreen = ActivityProgressUnitTests.screen
    static let sleepWindows = [ResidentFollowAndFallTests.win(1, x: 100, y: 300, w: 600, h: 300)]
    static let sleepStart = Date(timeIntervalSince1970: 23 * 86400 + 12 * 3600)
    /// 追逐场景：沿用 `ChaseTests`（UTC 08:00，不是 Night）。
    static let chaseScreen = StoryEngineTests.screen
    static let chaseWindows = StoryEngineTests.touching
    static let chaseStart = Date(timeIntervalSince1970: 1_800_000_000)

    /// 比较用：去掉只与「?」气泡有关的字段（`poke` 和显示用的 `bubble`），其余字段（Resident_State、位置、
    /// 朝向、Goal、路线、Walk_Distance 等）都参与比较。
    static func stripped(_ r: Resident?) -> Resident? {
        guard var r else { return nil }
        r.poke = nil
        r.bubble = nil
        return r
    }

    static func chaseState(_ e: WorldEngine) -> ChaseState? {
        e.state.wishes.active.first { $0.type == .chase }?.chase
    }

    /// 在居民命中矩形内按比例 (u, v) 取点；若该点被其他对象遮住，改为在矩形内逐点寻找命中该居民的点。
    static func hitPoint(for id: ResidentID, regions: [HitRegion], u: Double, v: Double) -> Point? {
        guard let rect = regions.first(where: { $0.target == .resident(id) })?.rect else { return nil }
        func at(_ fu: Double, _ fv: Double) -> Point {
            Point(x: rect.minX + rect.width * fu, y: rect.minY + rect.height * fv)
        }
        var candidates = [at(u, v)]
        for i in 1 ... 9 { for j in 1 ... 9 { candidates.append(at(Double(i) / 10, Double(j) / 10)) } }
        return candidates.first { HitTesting.hitTest($0, regions: regions) == .resident(id) }
    }

    /// 建立两台相同的模拟，推进到点击开始的那一刻；场景前提不成立时返回 nil。
    fileprivate static func setUp(_ c: PokeCase) -> (clicked: PokeSim, control: PokeSim, regions: [HitRegion])? {
        func make() -> (PokeSim, StepOutput)? {
            if c.chase {
                let e = WorldEngine(clockStart: chaseStart, screen: chaseScreen, rng: RandomSource(seed: 7))
                let sim = PokeSim(engine: e, windows: chaseWindows, now: chaseStart, screen: chaseScreen)
                _ = sim.step()   // 开局：分配 Home_Window 并放置居民
                e.place(Resident(id: .a, attachment: .window(1, offset: 200 * c.fracA)))
                e.place(Resident(id: .b, attachment: .window(2, offset: 200 * c.fracB)))
                let out = sim.step([.triggerWish(.chase, c.wisher)])
                guard chaseState(e)?.phase == .ready else { return nil }
                return (sim, out)
            }
            let e = WorldEngine(clockStart: sleepStart, screen: sleepScreen, rng: RandomSource(seed: 5),
                                demoResident: false, activities: true)
            let sim = PokeSim(engine: e, windows: sleepWindows, now: sleepStart, screen: sleepScreen)
            e.place(Resident(id: .a, attachment: .window(1, offset: 20 + 560 * c.fracA)))
            e.place(Resident(id: .b, attachment: .window(1, offset: 20 + 560 * c.fracB)))
            e.insertDecor(Decor(id: DecorID(1), type: .lamp,
                                placement: .attached(.window(1, offset: 100 + 400 * c.lampFrac))))
            var out = sim.step([.setDayNight(.night)])
            var frames = 0
            while frames < 200, [ResidentID.a, .b].contains(where: { e.state.residents[$0]?.state != .sleeping }) {
                out = sim.step()
                frames += 1
            }
            guard e.state.residents.values.allSatisfy({ $0.state == .sleeping }) else { return nil }
            return (sim, out)
        }
        guard let (clicked, out) = make(), let (control, _) = make() else { return nil }
        return (clicked, control, out.view.hitRegions)
    }

    // Feature: V2, Property 16: 戳居民的扩展状态
    // For any 处于 sleeping 的居民，或 Chase_Wish 进行中（ready 或 running）的 Chaser 和 Runner，以及任意点击
    // 时间序列：每次点击后「?」气泡剩余时间为 1.5 秒，不产生跳跃；该居民的 Resident_State、位置、朝向、Goal、
    // 路线、Walk_Distance、Chase_Phase、Flee_Target 和追逐计时与没有点击的对照模拟相同；不产生 woke 记录。
    // **Validates: Requirements 5.9, 20.9, 21.8**
    @Test func pokeOnlyShowsQuestionForSleepingAndChasingResidents() async {
        await propertyCheck(count: 100, input: Gen.pokeCase) { c in
            guard let (clicked, control, initialRegions) = Self.setUp(c) else {
                Issue.record("场景前提不成立（\(c)）")
                return
            }
            let k = Tunables()
            var regions = initialRegions
            for (frame, click) in c.clicks.enumerated() {
                // 只在被点击的居民属于扩展状态时点击：睡着，或 Chase_Wish 在 ready / running 中。
                let blocked = clicked.engine.jumpBlockedResidents()
                if c.chase, let phase = Self.chaseState(clicked.engine)?.phase {
                    #expect([ChasePhase.ready, .running].contains(phase), "frame \(frame) \(phase)（\(c)）")
                    #expect(blocked == [.a, .b], "frame \(frame) 追逐中的 jumpBlocked \(blocked)（\(c)）")
                }
                var pointer: [PointerEvent] = []
                var targets: [ResidentID] = []
                for id in click.targets {
                    guard let r = clicked.engine.state.residents[id],
                          c.chase ? Self.chaseState(clicked.engine) != nil : r.state == .sleeping,
                          let p = Self.hitPoint(for: id, regions: regions, u: c.u, v: c.v)
                    else { continue }
                    #expect(blocked.contains(id), "frame \(frame) \(id) 应只显示「?」（\(c)）")
                    // `poke(jumpAllowed:)` 本身：气泡剩余 1.5 秒（或重置为 1.5 秒），不跳跃，其余字段不变。
                    var poked = r
                    InteractionController.poke(&poked, constants: k, jumpAllowed: !blocked.contains(id))
                    #expect(poked.poke?.jumpRemaining == 0, "frame \(frame) \(id) 跳跃（\(c)）")
                    #expect(poked.poke?.bubbleRemaining == k.pokeBubbleDuration, "frame \(frame) \(id)（\(c)）")
                    #expect(Self.stripped(poked) == Self.stripped(r), "frame \(frame) \(id) poke 改变了居民（\(c)）")
                    pointer += [.down(p), .up(p)]
                    targets.append(id)
                }

                let out = clicked.step(pointer: pointer)
                let ref = control.step()
                regions = out.view.hitRegions

                for id in targets {
                    #expect(out.interactions.contains(.poked(id)), "frame \(frame) 点击未命中 \(id)（\(c)）")
                    // 点击在本帧开始时处理，随后本帧推进一次计时 dt。dt 由相邻两帧的 Date 相减得到，
                    // 带有约 1e-7 的浮点误差。
                    let p = clicked.engine.state.residents[id]?.poke
                    #expect(p?.jumpRemaining == 0, "frame \(frame) \(id) 跳跃 \(String(describing: p))（\(c)）")
                    #expect(abs((p?.bubbleRemaining ?? -1) - (k.pokeBubbleDuration - PokeSim.dt)) < 1e-6,
                            "frame \(frame) \(id) 气泡剩余 \(String(describing: p))（\(c)）")
                }
                for id in [ResidentID.a, .b] {
                    let got = clicked.engine.state.residents[id], want = control.engine.state.residents[id]
                    #expect((got?.poke?.jumpRemaining ?? 0) == 0, "frame \(frame) \(id) 跳跃（\(c)）")
                    #expect(Self.stripped(got) == Self.stripped(want),
                            "frame \(frame) \(id) 与对照不同：\(String(describing: got)) vs \(String(describing: want))（\(c)）")
                }
                #expect(clicked.engine.state.wishes == control.engine.state.wishes,
                        "frame \(frame) Wish（含 Chase_Phase、Flee_Target、追逐计时）与对照不同（\(c)）")
                #expect(clicked.engine.state.activities == control.engine.state.activities,
                        "frame \(frame) Activity 与对照不同（\(c)）")
                #expect(out.events == ref.events, "frame \(frame) 事件与对照不同（\(c)）")
                #expect(!out.events.contains { $0.type == .woke } || ref.events.contains { $0.type == .woke },
                        "frame \(frame) 点击产生了 woke（\(c)）")
                if !c.chase {
                    #expect(!out.events.contains { $0.type == .woke }, "frame \(frame) 睡觉场景写入 woke（\(c)）")
                }
            }
        }
    }
}
