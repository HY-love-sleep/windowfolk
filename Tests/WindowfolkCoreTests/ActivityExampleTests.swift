import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 5.9：自主活动的示例单元测试。补齐 `ActivityProgressUnitTests`（任务 5.6）未覆盖的时长边界与场景：
/// 拜访停留 Visit_Stay_Duration 的边界（被拜访者坐着时保持 `sitting`、不转向）、坐满 Sit_Duration 的边界、
/// 赏花停留、Local_Clock 跨过 Night_End 醒来、Lamp 被拖动后醒来再入睡、Activity_Reach_Timeout 的边界放弃。
///
/// 屏幕 1440×900，窗口 1 上沿 y = 300、x 100 → 700。时区固定为 UTC。计时边界用 `step(at:)` 把时钟直接设到
/// 边界时刻（WorldEngine 的单帧 dt 上限为 0.25 秒，跳跃式推进时居民每帧最多走 10pt）。
struct ActivityExampleTests {
    static let screen = ResidentFollowAndFallTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let dt = 1.0 / 30
    /// 1970-01-24 00:00:00 UTC。
    static let day = Date(timeIntervalSince1970: 23 * 86400)

    final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now: Date

        init(constants: Tunables = Tunables(), start: Date = ActivityExampleTests.day.addingTimeInterval(12 * 3600)) {
            now = start
            engine = WorldEngine(constants: constants, clockStart: start, screen: ActivityExampleTests.screen,
                                 rng: RandomSource(seed: 9), demoResident: false, activities: true)
            source = FakeWindowSource(windows: [
                FakeWindow(snapshot: ResidentFollowAndFallTests.win(1, x: 100, y: 300, w: 600, h: 300)),
            ])
        }

        /// 把时钟设到 `t` 后推进一帧。
        @discardableResult
        func step(at t: Date, _ commands: [Command] = [], pointer: [PointerEvent] = [],
                  sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            now = t
            let out = engine.step(FrameInput(poll: source.poll(), screen: ActivityExampleTests.screen,
                                             pointer: pointer, commands: commands, now: now,
                                             timeZone: ActivityExampleTests.utc))
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())",
                    sourceLocation: sourceLocation)
            return out
        }

        @discardableResult
        func step(_ commands: [Command] = [], pointer: [PointerEvent] = [],
                  sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            step(at: now.addingTimeInterval(ActivityExampleTests.dt), commands, pointer: pointer,
                 sourceLocation: sourceLocation)
        }

        /// 推进直到条件成立（最多 `frames` 帧），返回期间的全部事件。
        func run(until done: () -> Bool, frames: Int = 900) -> [EventRecord] {
            var events: [EventRecord] = []
            for _ in 0 ..< frames where !done() { events += step().events }
            return events
        }

        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }
        func activity(_ id: ResidentID) -> Activity? { engine.state.activities[id] }

        /// 居民在窗口 1 上的屏幕 x。
        func x(_ id: ResidentID) -> Double {
            guard case let .window(_, offset) = resident(id).attachment else { return .nan }
            return 100 + offset
        }

        func setActivity(_ id: ResidentID, _ kind: ActivityKind, _ target: ActivityTarget) {
            engine.state.activities[id] = Activity(kind: kind, target: target, startedAt: now)
        }

        func isStaying(_ id: ResidentID) -> Bool {
            if case .staying = activity(id)?.phase { return true }
            return false
        }
    }

    static func onLedge(_ id: ResidentID, x: Double) -> Resident {
        Resident(id: id, attachment: .window(1, offset: x - 100))
    }

    static func decor(_ id: UInt64, _ type: DecorType, x: Double) -> Decor {
        Decor(id: DecorID(id), type: type, placement: .attached(.window(1, offset: x - 100)))
    }

    static func bloomFlower(x: Double, plantedAt: Date) -> Item {
        Item(kind: .flower(storyRound: 1), placement: .attached(.window(1, offset: x - 100)),
             growth: FlowerGrowth(plantedAt: plantedAt, reached: .bloom))
    }

    // MARK: - 拜访停留（Requirement 4.8）

    @Test func visitStaysExactlyVisitStayDurationAndSittingHostKeepsSitting() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 200))
        h.engine.place(Self.onLedge(.b, x: 380))
        h.engine.insertDecor(Self.decor(1, .chair, x: 400))
        h.step()
        // 嘟嘟离 Chair 很近，首帧可能已自己选了 rest 并坐下；否则指定 rest。
        if h.resident(.b).state != .sitting { h.setActivity(.b, .rest, .chair(DecorID(1))) }
        _ = h.run(until: { h.resident(.b).state == .sitting })
        #expect(h.resident(.b).state == .sitting)
        let hostFacing = h.resident(.b).facing
        var hostSitUntil: Date?
        if case let .sitting(t)? = h.activity(.b)?.phase { hostSitUntil = t }
        #expect(hostSitUntil != nil)

        h.setActivity(.a, .visitNeighbor, .resident(.b))
        _ = h.run(until: { h.isStaying(.a) })
        #expect(h.isStaying(.a))
        let arrived = h.now
        let stay = Tunables().visitStayDuration
        #expect(h.resident(.a).facing == (h.x(.b) > h.x(.a) ? .right : .left))
        #expect(h.resident(.a).bubble == .heart)
        // 被拜访者坐着：保持 sitting 和座位，不转向，也显示心形；坐的计时随暂停后移。
        #expect(h.resident(.b).state == .sitting)
        #expect(h.resident(.b).seat == DecorID(1))
        #expect(h.resident(.b).facing == hostFacing)
        #expect(h.resident(.b).bubble == .heart)
        if case let .sitting(t)? = h.activity(.b)?.phase, let hostSitUntil {
            #expect(abs(t.timeIntervalSince(hostSitUntil) - stay) < 1e-6)
        } else {
            Issue.record("host lost sitting phase: \(String(describing: h.activity(.b)))")
        }

        // 停留未满：不写 visited，两人原地不动。
        let ax = h.x(.a)
        let early = h.step(at: arrived.addingTimeInterval(stay - 0.1))
        #expect(!early.events.contains { $0.type == .visited })
        #expect(h.isStaying(.a))
        #expect(h.x(.a) == ax)
        #expect(h.resident(.b).state == .sitting)

        // 恰好满 Visit_Stay_Duration：写 1 条 visited，拜访结束，被拜访者继续坐着，心形消失。
        let done = h.step(at: arrived.addingTimeInterval(stay))
        let visited = done.events.filter { $0.type == .visited }
        #expect(visited.count == 1)
        #expect(visited.first?.actor == "resident_a")
        #expect(visited.first?.target == "resident_b")
        #expect(h.activity(.a)?.kind != .visitNeighbor)
        #expect(h.resident(.a).bubble != .heart)
        #expect(h.resident(.b).bubble != .heart)
        #expect(h.resident(.b).state == .sitting)
        #expect(h.activity(.b)?.kind == .rest)
        #expect(h.activity(.b)?.pausedUntil == nil)
    }

    // MARK: - 坐满 Sit_Duration（Requirement 4.9）

    @Test func sittingEndsExactlyAtSitDurationReleasingChairAndResettingWalkDistance() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 440))
        h.engine.insertDecor(Self.decor(1, .chair, x: 500))
        h.step()
        h.setActivity(.a, .rest, .chair(DecorID(1)))
        let events = h.run(until: { h.resident(.a).state == .sitting })
        #expect(events.filter { $0.type == .sat }.count == 1)
        let sat = h.now
        let sit = Tunables().sitDuration
        #expect(h.resident(.a).walkDistance > 0)
        #expect(h.x(.a) == 500)

        h.step(at: sat.addingTimeInterval(sit - 0.1))
        #expect(h.resident(.a).state == .sitting)
        #expect(h.resident(.a).seat == DecorID(1))
        #expect(h.resident(.a).walkDistance > 0)

        h.step(at: sat.addingTimeInterval(sit))
        #expect(h.resident(.a).state == .idle)
        #expect(h.resident(.a).seat == nil)
        #expect(h.resident(.a).walkDistance == 0)
        #expect(h.activity(.a)?.kind != .rest)
        // 1 秒内选出下一个 Activity（Requirement 4.2）。
        h.step()
        #expect(h.activity(.a) != nil)
    }

    // MARK: - 赏花（Requirement 4.10）

    @Test func admireFlowerFacesFlowerWithFlowerBubbleForVisitStayDuration() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 600))
        let flower = Self.bloomFlower(x: 450, plantedAt: h.now.addingTimeInterval(-3600))
        h.engine.insertItem(flower)
        h.step()
        h.setActivity(.a, .admireFlower, .flower(flower.id))
        _ = h.run(until: { h.isStaying(.a) })
        #expect(h.isStaying(.a))
        #expect(h.activity(.a)?.kind == .admireFlower)
        let arrived = h.now
        let stay = Tunables().visitStayDuration
        let ax = h.x(.a)
        #expect(abs(ax - 450) <= Tunables().giftReachDistance)
        #expect(h.resident(.a).facing == .left)
        #expect(h.resident(.a).bubble == .flower)
        #expect(h.resident(.a).state == .idle)

        h.step(at: arrived.addingTimeInterval(stay - 0.1))
        #expect(h.isStaying(.a))
        #expect(h.resident(.a).bubble == .flower)
        #expect(h.x(.a) == ax)

        h.step(at: arrived.addingTimeInterval(stay))
        #expect(h.activity(.a)?.kind != .admireFlower)
        #expect(h.resident(.a).bubble != .flower)
        // 花还在原处，没有被拿走。
        #expect(h.engine.state.items[flower.id]?.placement == flower.placement)
    }

    // MARK: - 入睡与醒来（Requirement 5.4、5.7、5.8）

    @Test func localClockCrossingNightEndWakesSleeper() {
        // 05:59:58 UTC，昼夜覆盖为「自动」：按 Local_Clock 判定为 Night。
        let h = Harness(start: Self.day.addingTimeInterval(6 * 3600 - 2))
        h.engine.place(Self.onLedge(.a, x: 560))
        h.engine.insertDecor(Self.decor(1, .lamp, x: 600))
        var events = h.step().events
        #expect(h.engine.state.isNight)
        #expect(h.activity(.a)?.kind == .sleep)
        events += h.run(until: { h.resident(.a).state == .sleeping }, frames: 30)
        #expect(h.resident(.a).state == .sleeping)
        #expect(events.filter { $0.type == .slept }.count == 1)

        // 05:59:59 仍是 Night，继续睡。
        let still = h.step(at: Self.day.addingTimeInterval(6 * 3600 - 1))
        #expect(h.resident(.a).state == .sleeping)
        #expect(!still.events.contains { $0.type == .woke })

        // 06:00:00 Night 结束：1 秒内（此处同一帧）醒来，写 woke(night_ended)，Walk_Distance 归零。
        let out = h.step(at: Self.day.addingTimeInterval(6 * 3600))
        #expect(!h.engine.state.isNight)
        #expect(h.resident(.a).state != .sleeping)
        #expect(h.resident(.a).walkDistance == 0)
        #expect(h.resident(.a).bubble != .zzz)
        let woke = out.events.filter { $0.type == .woke }
        #expect(woke.count == 1)
        #expect(woke.first?.actor == "resident_a")
        #expect(woke.first?.detail["reason"] == "night_ended")
        #expect(!out.events.contains { $0.type == .slept })
        // 已选出下一个 Activity，白天不再是 sleep。
        h.step()
        #expect(h.activity(.a) != nil)
        #expect(h.activity(.a)?.kind != .sleep)
    }

    @Test func autoOverrideOnDaytimeWakesSleeper() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 560))
        h.engine.insertDecor(Self.decor(1, .lamp, x: 600))
        h.step([.setDayNight(.night)])
        _ = h.run(until: { h.resident(.a).state == .sleeping }, frames: 30)
        #expect(h.resident(.a).state == .sleeping)
        // 白天时刻把覆盖改回「自动」：Night 结束。
        let out = h.step([.setDayNight(.auto)])
        #expect(h.resident(.a).state != .sleeping)
        #expect(out.events.filter { $0.type == .woke }.map { $0.detail["reason"] } == ["night_ended"])
    }

    @Test func draggedLampWakesSleeperThenReplacedLampSleepsAgainWithOneSleptEach() {
        let h = Harness()
        h.engine.place(Self.onLedge(.a, x: 450))
        h.engine.insertDecor(Self.decor(1, .lamp, x: 600))
        var events = h.step([.setDayNight(.night)]).events
        events += h.run(until: { h.resident(.a).state == .sleeping })
        #expect(h.resident(.a).state == .sleeping)
        #expect(h.resident(.a).walkDistance > 0)
        #expect(events.filter { $0.type == .slept }.count == 1)

        // 开始拖动 Lamp：同一帧醒来（1 秒内），Walk_Distance 归零，写 woke(lamp_moved)。
        let grab = h.step(pointer: [.down(Point(x: 600, y: 290)), .moved(Point(x: 620, y: 250))])
        #expect(h.resident(.a).state != .sleeping)
        #expect(h.resident(.a).walkDistance == 0)
        #expect(grab.events.filter { $0.type == .woke }.map { $0.detail["reason"] } == ["lamp_moved"])
        // 拖动中 Lamp 不可作 sleep 目标：1 秒内选出其他 Activity，不写 slept。
        var dragging: [EventRecord] = []
        for _ in 0 ..< 30 { dragging += h.step(pointer: [.moved(Point(x: 620, y: 250))]).events }
        #expect(h.activity(.a) != nil)
        #expect(h.activity(.a)?.kind != .sleep)
        #expect(!dragging.contains { $0.type == .slept })
        #expect(h.resident(.a).state != .sleeping)

        // 放回窗沿：之后居民再次入睡，只再写 1 条 slept。
        h.step(pointer: [.moved(Point(x: 600, y: 285)), .up(Point(x: 600, y: 285))])
        #expect(h.engine.state.decors.decors[DecorID(1)]?.placement == .attached(.window(1, offset: 500)))
        h.engine.state.activities[.a] = nil
        let again = h.run(until: { h.resident(.a).state == .sleeping })
        #expect(h.resident(.a).state == .sleeping)
        #expect(again.filter { $0.type == .slept }.count == 1)
    }

    // MARK: - Activity_Reach_Timeout（Requirement 4.11、5.5）

    @Test func admireFlowerAbandonedExactlyAtReachTimeoutWithoutBubble() {
        var k = Tunables()
        k.walkSpeed = 1
        let h = Harness(constants: k)
        h.engine.place(Self.onLedge(.a, x: 110))
        let flower = Self.bloomFlower(x: 690, plantedAt: h.now.addingTimeInterval(-3600))
        h.engine.insertItem(flower)
        h.step()
        h.setActivity(.a, .admireFlower, .flower(flower.id))
        let started = h.now
        let timeout = k.activityReachTimeout

        h.step()
        #expect(h.activity(.a)?.kind == .admireFlower)
        h.step(at: started.addingTimeInterval(timeout - 0.1))
        #expect(h.activity(.a)?.kind == .admireFlower)
        #expect(h.activity(.a)?.startedAt == started)

        // 到达 Activity_Reach_Timeout：同一帧放弃并选出下一个，不进入 waiting，不显示任何气泡。
        h.step(at: started.addingTimeInterval(timeout))
        let next = h.activity(.a)
        #expect(next != nil)
        #expect(next.map { $0.startedAt > started } == true)
        #expect(h.resident(.a).state != .waiting)
        #expect(h.resident(.a).bubble == nil)
    }

    @Test func sleepAbandonedAtReachTimeoutWithoutSleptOrBubble() {
        var k = Tunables()
        k.walkSpeed = 1
        let h = Harness(constants: k)
        h.engine.place(Self.onLedge(.a, x: 110))
        h.engine.insertDecor(Self.decor(1, .lamp, x: 690))
        var events = h.step([.setDayNight(.night)]).events
        #expect(h.activity(.a)?.kind == .sleep)
        let started = h.activity(.a)!.startedAt
        let timeout = k.activityReachTimeout

        events += h.step(at: started.addingTimeInterval(timeout - 0.1)).events
        #expect(h.activity(.a)?.startedAt == started)

        events += h.step(at: started.addingTimeInterval(timeout)).events
        // 放弃原 sleep：不写 slept，不进入 sleeping 或 waiting，无气泡；Night 中 sleep 仍可执行，重新选中 sleep。
        #expect(!events.contains { $0.type == .slept })
        #expect(h.resident(.a).state != .sleeping)
        #expect(h.resident(.a).state != .waiting)
        #expect(h.resident(.a).bubble == nil)
        #expect(h.activity(.a).map { $0.startedAt > started } == true)
        #expect(h.activity(.a)?.kind == .sleep)
    }
}
