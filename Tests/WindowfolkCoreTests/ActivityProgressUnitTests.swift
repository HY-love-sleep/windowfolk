import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 5.6：ActivityPlanner 推进接入 WorldEngine 的单元测试（昼夜判定、坐下与拖动 Chair、入睡与醒来、
/// 戳睡着的居民、拜访停留、放弃，以及默认关闭时与 v1 一致）。
/// 屏幕 1440×900，窗口 1 上沿 y = 300、x 100 → 700。时区固定为 UTC。
struct ActivityProgressUnitTests {
    static let screen = ResidentFollowAndFallTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let dt = 1.0 / 30

    final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        /// 1970-01-24 12:00:00 UTC（白天）。
        var now = Date(timeIntervalSince1970: 23 * 86400 + 12 * 3600)

        init(constants: Tunables = Tunables(), activities: Bool = true) {
            engine = WorldEngine(constants: constants, clockStart: now, screen: ActivityProgressUnitTests.screen,
                                 rng: RandomSource(seed: 5), demoResident: false, activities: activities)
            source = FakeWindowSource(windows: [
                FakeWindow(snapshot: ResidentFollowAndFallTests.win(1, x: 100, y: 300, w: 600, h: 300)),
            ])
        }

        @discardableResult
        func step(_ commands: [Command] = [], pointer: [PointerEvent] = [],
                  sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            now = now.addingTimeInterval(ActivityProgressUnitTests.dt)
            let out = engine.step(FrameInput(poll: source.poll(), screen: ActivityProgressUnitTests.screen,
                                             pointer: pointer, commands: commands, now: now,
                                             timeZone: ActivityProgressUnitTests.utc))
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())",
                    sourceLocation: sourceLocation)
            return out
        }

        /// 推进直到条件成立（最多 `frames` 帧），返回期间的全部事件。
        func run(until done: () -> Bool, frames: Int = 900, _ commands: [Command] = []) -> [EventRecord] {
            var events: [EventRecord] = []
            for _ in 0 ..< frames where !done() { events += step(commands).events }
            return events
        }

        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }

        func setActivity(_ id: ResidentID, _ kind: ActivityKind, _ target: ActivityTarget) {
            engine.state.activities[id] = Activity(kind: kind, target: target, startedAt: now)
        }
    }

    static func onLedge(_ id: ResidentID, x: Double) -> Resident {
        Resident(id: id, attachment: .window(1, offset: x - 100))
    }

    static func decor(_ id: UInt64, _ type: DecorType, x: Double) -> Decor {
        Decor(id: DecorID(id), type: type, placement: .attached(.window(1, offset: x - 100)))
    }

    // MARK: - 昼夜（Requirement 5.1、5.2、17.4）

    @Test func dayNightOverrideTakesEffectInSameFrame() {
        let h = Harness()
        h.step()
        #expect(!h.engine.state.isNight)
        h.step([.setDayNight(.night)])
        #expect(h.engine.state.isNight)
        #expect(h.engine.state.dayNightOverride == .night)
        h.step([.setDayNight(.auto)])
        #expect(!h.engine.state.isNight)
        h.now = Date(timeIntervalSince1970: 23 * 86400 + 19 * 3600 - Self.dt)   // 下一帧为 19:00:00
        h.step()
        #expect(h.engine.state.isNight)
    }

    // MARK: - 坐下与拖动 Chair（Requirement 4.9、3.8、4.13）

    @Test func restSitsOnChairAndDraggingChairStandsResidentUp() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 200))
        h.engine.insertDecor(Self.decor(1, .chair, x: 500))
        h.step()
        h.setActivity(.a, .rest, .chair(DecorID(1)))
        let events = h.run(until: { h.resident(.a).state == .sitting })
        let a = h.resident(.a)
        #expect(a.state == .sitting)
        #expect(a.seat == DecorID(1))
        #expect(a.attachment == .window(1, offset: 400))
        #expect(events.filter { $0.type == .sat }.map(\.target) == ["decor:1"])

        // 在椅子下方露出的 10pt 内按下并拖动：同一帧居民转 idle、释放 Chair，位置不变。
        let out = h.step(pointer: [.down(Point(x: 500, y: 296)), .moved(Point(x: 520, y: 260))])
        #expect(h.resident(.a).state == .idle)
        #expect(h.resident(.a).seat == nil)
        #expect(h.resident(.a).attachment == .window(1, offset: 400))
        #expect(out.view.decors.first { $0.id == DecorID(1) }?.isDragged == true)
    }

    @Test func sittingEndsAfterSitDurationAndResetsWalkDistance() {
        var k = Tunables()
        k.sitDuration = 1
        let h = Harness(constants: k)
        h.engine.place(Self.onLedge(.a, x: 400))
        h.engine.insertDecor(Self.decor(1, .chair, x: 500))
        h.step()
        h.setActivity(.a, .rest, .chair(DecorID(1)))
        _ = h.run(until: { h.resident(.a).state == .sitting })
        #expect(h.resident(.a).walkDistance > 0)
        _ = h.run(until: { h.resident(.a).state != .sitting }, frames: 60)
        #expect(h.resident(.a).state != .sitting)
        #expect(h.resident(.a).seat == nil)
        #expect(h.resident(.a).walkDistance == 0)
    }

    // MARK: - 入睡、戳、醒来（Requirement 5.4、5.6、5.7、5.8、5.9）

    @Test func sleepsNearLampPokeOnlyQuestionThenWakesWhenNightEnds() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 200))
        h.engine.insertDecor(Self.decor(1, .lamp, x: 600))
        // Night 且 sleep 可执行时直接选 sleep（Requirement 4.4）。
        var events = h.step([.setDayNight(.night)]).events
        #expect(h.engine.state.activities[.a]?.kind == .sleep)
        events += h.run(until: { h.resident(.a).state == .sleeping })
        #expect(h.resident(.a).state == .sleeping)
        #expect(events.filter { $0.type == .slept }.count == 1)
        let x = h.step().view.residents.first { $0.id == .a }!.position!.x
        #expect(600 - x <= 80)
        #expect(h.resident(.a).bubble == .zzz)

        // 戳：只显示「?」，不跳跃，不醒来。
        let rv = h.step(pointer: [.down(Point(x: x, y: 290)), .up(Point(x: x, y: 290))])
        let poke = h.resident(.a).poke
        #expect(poke?.jumpRemaining == 0)
        #expect((poke?.bubbleRemaining ?? 0) >= Tunables().pokeBubbleDuration - Self.dt - 1e-9)
        #expect(h.resident(.a).state == .sleeping)
        #expect(!rv.events.contains { $0.type == .woke })

        // 切回白天：同一帧醒来，写 woke(night_ended)，Zzz 消失。
        let out = h.step([.setDayNight(.day)])
        #expect(h.resident(.a).state != .sleeping)
        #expect(h.resident(.a).walkDistance == 0)
        #expect(h.resident(.a).bubble != .zzz)
        let woke = out.events.filter { $0.type == .woke }
        #expect(woke.count == 1)
        #expect(woke.first?.detail["reason"] == "night_ended")
    }

    @Test func draggingLampWakesSleeper() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 560))
        h.engine.insertDecor(Self.decor(1, .lamp, x: 600))
        h.step([.setDayNight(.night)])
        _ = h.run(until: { h.resident(.a).state == .sleeping }, frames: 10)
        #expect(h.resident(.a).state == .sleeping)
        let out = h.step(pointer: [.down(Point(x: 600, y: 290)), .moved(Point(x: 640, y: 250))])
        #expect(h.resident(.a).state == .idle)
        #expect(out.events.filter { $0.type == .woke }.first?.detail["reason"] == "lamp_moved")
    }

    @Test func closingWindowUnderSleeperWritesSurfaceGone() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 560))
        h.engine.insertDecor(Self.decor(1, .lamp, x: 600))
        h.step([.setDayNight(.night)])
        _ = h.run(until: { h.resident(.a).state == .sleeping }, frames: 10)
        #expect(h.resident(.a).state == .sleeping)
        h.source.close(1)
        let out = h.step()
        #expect(h.resident(.a).state == .falling)
        #expect(h.engine.state.activities[.a] == nil)
        #expect(out.events.filter { $0.type == .woke }.first?.detail["reason"] == "surface_gone")
    }

    // MARK: - 拜访（Requirement 4.8）

    @Test func visitStaysThenWritesVisitedAndHostResumes() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 200))
        h.engine.place(Self.onLedge(.b, x: 400))
        h.step()
        h.setActivity(.a, .visitNeighbor, .resident(.b))
        h.engine.state.activities[.b] = Activity(
            kind: .wander, target: .none, startedAt: h.now, wanderUntil: h.now.addingTimeInterval(1000))
        _ = h.run(until: {
            if case .staying = h.engine.state.activities[.a]?.phase { return true }
            return false
        })
        #expect(h.resident(.a).bubble == .heart)
        #expect(h.resident(.b).bubble == .heart)
        #expect(h.engine.state.activities[.b]?.pausedUntil != nil)
        #expect(h.resident(.b).goal == .hold(face: .resident(.a)))
        let events = h.run(until: { h.engine.state.activities[.a]?.kind != .visitNeighbor }, frames: 200)
        let visited = events.filter { $0.type == .visited }
        #expect(visited.count == 1)
        #expect(visited.first?.actor == "resident_a")
        #expect(visited.first?.target == "resident_b")
        #expect(visited.first?.detail["source"] == "visit_neighbor")
        #expect(h.resident(.b).bubble != .heart)
        #expect(h.engine.state.activities[.b]?.kind == .wander)
        #expect(h.engine.state.activities[.b]?.pausedUntil == nil)
    }

    // MARK: - 放弃（Requirement 4.11）

    @Test func reachTimeoutAbandonsWithoutWaitingOrBubble() {
        var k = Tunables()
        k.activityReachTimeout = 1
        let h = Harness(constants: k)
        h.engine.place(Self.onLedge(.a, x: 110))
        h.engine.insertDecor(Self.decor(1, .chair, x: 690))
        h.step()
        h.setActivity(.a, .rest, .chair(DecorID(1)))
        let started = h.now
        for _ in 0 ..< 31 { h.step() }
        // 1 秒内未到达：已放弃原 Activity（新选出的 Activity 开始时间晚于原来的）。
        #expect(h.engine.state.activities[.a].map { $0.startedAt > started } == true)
        #expect(h.resident(.a).state != .waiting)
        #expect(h.resident(.a).bubble == nil)
        // 放弃后同一帧已选出下一个 Activity。
        #expect(h.engine.state.activities[.a] != nil)
    }

    // MARK: - 每位空闲居民都有 Activity（Requirement 4.1）与 v1 兼容

    @Test func idleResidentsAlwaysHaveAnActivity() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 200))
        h.engine.place(Self.onLedge(.b, x: 600))
        for _ in 0 ..< 300 {
            h.step()
            for id in ResidentID.allCases {
                let r = h.resident(id)
                if r.state == .falling || r.state == .hanging {
                    #expect(h.engine.state.activities[id] == nil)
                } else {
                    #expect(h.engine.state.activities[id] != nil)
                }
            }
        }
    }

    /// 回归（Property 9 反例，按 `ActivityEngineTests` 的缩小反例重放）：两扇窗口重叠，关闭窗口 1 后站在窗口 2 上的
    /// 都都在 `plan` 之后才开始下落；帧末不得仍保留 `wander`（Requirement 4.1、4.11）。
    @Test func fallingStartedAfterPlanDropsActivityInSameFrame() {
        typealias E = ActivityEngineTests
        let s = E.Scenario(
            windows: [E.WindowSpec(x: 0, y: 240, w: 200), E.WindowSpec(x: 0, y: 200, w: 200)],
            residents: [E.Placement(surface: 2, frac: 8), E.Placement(surface: 0, frac: 0)],
            decors: [E.DecorSpec(isLamp: false, at: E.Placement(surface: 3, frac: 2))],
            story: false, startHour: 0, seed: 0, ops: [])
        let sim = E.Sim(s)
        for _ in 0 ..< 33 { sim.step() }
        #expect(sim.engine.state.activities[.a] != nil)
        sim.source.close(1)
        var fell = false
        for _ in 0 ..< 5 {
            sim.step()
            let r = sim.engine.state.residents[.a]!
            guard r.state == .falling || r.state == .hanging else { continue }
            fell = true
            #expect(sim.engine.state.activities[.a] == nil, "state \(r.state)")
        }
        #expect(fell)
    }

    @Test func activitiesDisabledByDefaultKeepsV1Behavior() {
        let h = Harness(activities: false)
        h.engine.place(Self.onLedge(.a, x: 200))
        for _ in 0 ..< 30 { h.step() }
        #expect(h.engine.state.activities.isEmpty)
        #expect(h.resident(.a).goal == Goal.none)
    }

    @Test func activeResidentStatesIncludeRunning() {
        #expect(WorldEngine.activeResidentStates.contains(.running))
        #expect(!WorldEngine.activeResidentStates.contains(.sitting))
        #expect(!WorldEngine.activeResidentStates.contains(.sleeping))
    }
}
