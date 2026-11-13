import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 一次追逐结局对照：两人站在窗口 1 的窗沿上，从 Debug 触发 Chase_Wish。窗沿较短（Ground 太宽，Runner 逃向远端后
/// 要十几秒才能抓到，模拟太慢），Runner 逃到端点后很快被抓到。
fileprivate struct ChaseOutcomeScenario: Sendable {
    var ledgeY: Int          // 窗口 1 上沿
    var width: Int           // 窗口 1 宽度
    var chaserFrac: Double   // Chaser 在 Surface 上的相对位置
    var runnerFrac: Double   // Runner 在 Surface 上的相对位置
    var catchDistance: Double // caught 副本使用的 Catch_Distance，控制追逐在 running 的第几帧结束
    var wisherIsA: Bool
    var seed: UInt64
    var idleFrames: Int      // 触发前的空闲帧数
}

fileprivate extension Gen where Value == ChaseOutcomeScenario {
    static var chaseOutcomeScenario: Generator<ChaseOutcomeScenario, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 250...450),
            Gen<Int>.int(in: 250...400),
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: 16...80),
            Gen<Bool>.bool,
            Gen<UInt64>.uint64(in: 1...1_000_000),
            Gen<Int>.int(in: 0...5)
        ).map {
            ChaseOutcomeScenario(ledgeY: $0, width: $1, chaserFrac: $2, runnerFrac: $3,
                                 catchDistance: $4, wisherIsA: $5, seed: $6, idleFrames: $7)
        }
    }
}

struct ChaseOutcomeTests {
    static let screen = StoryEngineTests.screen
    static let dt = 1.0 / 30
    static let mainX = 50.0
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// running 阶段最多模拟的帧数（20 秒）；caught 副本应在此之前抓到。
    static let maxRunningFrames = 600
    /// 结局之后比较的帧数：庆祝 1.2 秒，再加 0.5 秒。
    static let afterFrames = Int((StoryDirector.celebrateDuration + 0.5) / dt)

    fileprivate static func windows(_ s: ChaseOutcomeScenario) -> [WindowSnapshot] {
        [
            WindowSnapshot(id: 1, ownerName: "App1", ownerPID: 1,
                           frame: Rect(minX: mainX, minY: Double(s.ledgeY), width: Double(s.width), height: 150),
                           zIndex: 0),
            WindowSnapshot(id: 2, ownerName: "App2", ownerPID: 2,
                           frame: Rect(minX: 900, minY: 650, width: 300, height: 150), zIndex: 1),
        ]
    }

    static func attachment(x: Double) -> CoreAttachment { .window(1, offset: x - mainX) }

    /// 一个副本：独立的引擎、窗口源和时钟。两个副本的输入逐帧相同。
    final class Copy {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now = ChaseOutcomeTests.t0

        init(_ windows: [WindowSnapshot], constants: Tunables, seed: UInt64) {
            engine = WorldEngine(constants: constants, clockStart: now, screen: ChaseOutcomeTests.screen,
                                 rng: RandomSource(seed: seed))
            source = FakeWindowSource(snapshots: windows)
        }

        @discardableResult
        func step(_ commands: [Command] = []) -> StepOutput {
            now = now.addingTimeInterval(ChaseOutcomeTests.dt)
            return engine.step(FrameInput(poll: source.poll(), screen: ChaseOutcomeTests.screen,
                                          commands: commands, now: now))
        }

        var chase: ChaseState? { engine.state.wishes.active.first { $0.type == .chase }?.chase }
    }

    /// 去掉 `wish_fulfilled` 记录 detail 中的 `chase_outcome` 后的事件。
    static func withoutOutcome(_ events: [EventRecord]) -> [EventRecord] {
        events.map { e in
            var e = e
            if e.type == .wishFulfilled { e.detail["chase_outcome"] = nil }
            return e
        }
    }

    // Feature: V2, Property 60: 两种结局看起来相同
    /// 两个副本只在 Catch_Distance 与 Chase_Duration 上不同：caught 副本用生成的 Catch_Distance、Chase_Duration
    /// 设为极大；escaped 副本 Catch_Distance 为 -1（永不抓到）。两者逐帧输入相同，running 期间状态相同；caught 副本
    /// 抓到的那一帧，escaped 副本在 step 前把追逐开始时间提前，使它在同一帧满 Chase_Duration 得出 `escaped`。
    /// 从结局帧起的每一帧：两副本的 `WorldView`（居民 Resident_State、气泡、位置等）、居民完整状态、庆祝结束时间与
    /// 心形集合都相同；事件记录只在 `wish_fulfilled` 的 `chase_outcome` 上不同。
    ///
    /// **Validates: Requirements 22.4**
    @Test func caughtAndEscapedLookTheSame() async {
        await propertyCheck(count: 100, input: Gen.chaseOutcomeScenario) { s in
            // ready 阶段与本属性无关，两个副本都缩短为 0.5 秒以控制模拟时长。
            var base = Tunables()
            base.chaseReadyDuration = 0.5
            var kc = base
            kc.catchDistance = s.catchDistance
            kc.chaseDuration = 1e9
            var ke = base
            ke.catchDistance = -1
            let windows = Self.windows(s)
            let c = Copy(windows, constants: kc, seed: s.seed)
            let e = Copy(windows, constants: ke, seed: s.seed)
            func both(_ commands: [Command] = []) -> (StepOutput, StepOutput) {
                (c.step(commands), e.step(commands))
            }

            _ = both()   // 分配 Home_Window
            let lo = Self.mainX
            let hi = Self.mainX + Double(s.width)
            let inset = 20.0
            let cx = lo + inset + (hi - lo - 2 * inset) * s.chaserFrac
            // Runner 与 Chaser 至少相距 Catch_Distance + 10pt，使 caught 副本不会在进入 running 的那一帧就抓到
            // （那一帧 escaped 副本的追逐开始时间刚被设为当前时刻，无法提前）。
            let span = hi - lo - 2 * inset
            let minGap = s.catchDistance + 10
            var rx = lo + inset + span * s.runnerFrac
            if abs(rx - cx) < minGap {
                rx = cx + minGap <= hi - inset ? cx + minGap : cx - minGap
            }
            for copy in [c, e] {
                copy.engine.place(Resident(id: ChaseRules.chaser, attachment: Self.attachment(x: cx)))
                copy.engine.place(Resident(id: ChaseRules.runner, attachment: Self.attachment(x: rx)))
            }
            for _ in 0 ..< s.idleFrames { _ = both() }
            _ = both([.triggerWish(.chase, s.wisherIsA ? .a : .b)])
            guard c.chase != nil, e.chase != nil else {
                Issue.record("Chase_Wish 未触发")
                return
            }

            // ready 与 running：逐帧推进，直到 caught 副本得出结局。
            var outcomeOut: (StepOutput, StepOutput)?
            var sawRunning = false
            let readyFrames = Int(base.chaseReadyDuration / Self.dt) + 2
            for _ in 0 ..< readyFrames + Self.maxRunningFrames {
                let oc = c.step()
                if c.chase == nil {
                    // caught 副本本帧得出结局：escaped 副本把追逐开始时间提前 Chase_Duration，在同一帧得出 escaped。
                    if let i = e.engine.state.wishes.active.firstIndex(where: { $0.type == .chase }) {
                        e.engine.state.wishes.active[i].chase?.runningAt =
                            e.now.addingTimeInterval(Self.dt - ke.chaseDuration - 1)
                    }
                    outcomeOut = (oc, e.step())
                    break
                }
                let oe = e.step()
                if c.chase?.phase == .running { sawRunning = true }
                // 结局之前两副本完全相同（逐帧检查，用 if 避免每帧展开 #expect）。
                if oc.view != oe.view || c.engine.state.residents != e.engine.state.residents || e.chase == nil {
                    Issue.record("结局之前两副本不同")
                    return
                }
            }
            guard let (oc, oe) = outcomeOut else {
                Issue.record("caught 副本在 \(Self.maxRunningFrames) 帧 running 内没有抓到")
                return
            }
            #expect(sawRunning)
            #expect(e.chase == nil)

            // 结局帧：两条 wish_fulfilled 记录，chase_outcome 分别为 caught 与 escaped，其余相同。
            let fc = oc.events.filter { $0.type == .wishFulfilled }
            let fe = oe.events.filter { $0.type == .wishFulfilled }
            #expect(fc.count == 1 && fe.count == 1)
            #expect(fc.first?.detail["chase_outcome"] == "caught")
            #expect(fe.first?.detail["chase_outcome"] == "escaped")
            #expect(Self.withoutOutcome(oc.events) == Self.withoutOutcome(oe.events))
            // 抓到时两人都可以庆祝：同帧 celebrating 加心形气泡。
            for v in oc.view.residents {
                #expect(v.state == .celebrating && v.bubble == .heart, "\(v.id): \(v.state) \(String(describing: v.bubble))")
            }

            // 从结局帧起的每一帧都相同。
            var outs = (oc, oe)
            for frame in 0 ... Self.afterFrames {
                if frame > 0 { outs = both() }
                let (a, b) = outs
                #expect(a.view == b.view, "frame \(frame) after outcome")
                #expect(Self.withoutOutcome(a.events) == Self.withoutOutcome(b.events), "frame \(frame)")
                #expect(a.storyEvents == b.storyEvents)
                #expect(c.engine.state.residents == e.engine.state.residents, "frame \(frame)")
                #expect(c.engine.state.wishes.celebrations == e.engine.state.wishes.celebrations)
                #expect(c.engine.state.wishes.celebrationHearts == e.engine.state.wishes.celebrationHearts)
                #expect(c.engine.state.wishes.active == e.engine.state.wishes.active)
            }
            // 庆祝已结束：不再有居民庆祝，庆祝记录与心形集合已清空。之后的心形气泡只可能来自拜访邻居的停留
            // （Requirement 4.8，两人刚追逐完常常相邻，Activity_Planner 选出 visit_neighbor 后同帧到达）。
            #expect(c.engine.state.wishes.celebrations.isEmpty)
            #expect(c.engine.state.wishes.celebrationHearts.isEmpty)
            let visitStaying = c.engine.state.activities.values.contains { a in
                if a.kind == .visitNeighbor, case .staying = a.phase { return true }
                return false
            }
            for v in outs.0.view.residents {
                #expect(v.state != .celebrating, "\(v.id): \(v.state)")
                #expect(v.bubble != .heart || visitStaying, "\(v.id): 庆祝结束后仍有心形气泡")
            }
        }
    }
}
