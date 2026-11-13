import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 8.11：追逐的示例测试，经过完整 WorldEngine（剧情与自主活动启用，时区 UTC，起始 UTC 08:00，不是 Night）。
///
/// `ChaseEngineUnitTests` 已直接调用 WishDirector 覆盖 ready 边界、Hidden_Window 时的 `Goal.wait`、两种结局与
/// 庆祝、落地朝向；这里补齐只能在逐帧模拟中观察的部分：ready 中下落不暂停计时、running 中下落与 Hidden_Window
/// 期间计时继续、60 秒到时与抓到同帧取 `caught`、未庆祝的居民恢复后选择 Activity 且 Walk_Distance 保留。
///
/// 每帧 0.125 秒（二进制可精确表示，帧时刻按帧号直接算出，没有累计误差）：Chase_Ready_Duration 为 16 帧，
/// Chase_Duration 为 480 帧。Ground 在 y 825；窗沿在 y 300 至 500，居民在 Ground 上时没有路线可达窗沿。
struct ChaseExampleTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let dt = 0.125
    static let c = Tunables()
    /// 1 秒内的帧数。
    static let oneSecond = Int(1 / dt)

    static func win(_ id: WindowID, x: Double, y: Double, w: Double = 200, h: Double = 200) -> WindowSnapshot {
        StoryEngineTests.win(id, x: x, y: y, w: w, h: h)
    }

    /// 窗口 1（x 100 → 300）与窗口 2（x 300 → 500）首尾相接，上沿 y 400。
    static let touching = StoryEngineTests.touching

    final class Sim {
        let engine: WorldEngine
        var source: FakeWindowSource
        var frame = 0
        /// 至今所有 `wish_fulfilled` 记录及其所在帧的时刻。
        var fulfilled: [(Date, EventRecord)] = []

        init(_ windows: [WindowSnapshot]) {
            engine = WorldEngine(clockStart: ChaseExampleTests.t0, screen: ChaseExampleTests.screen,
                                 rng: RandomSource(seed: 11))
            source = FakeWindowSource(snapshots: windows)
        }

        var now: Date { ChaseExampleTests.t0.addingTimeInterval(Double(frame) * ChaseExampleTests.dt) }

        @discardableResult
        func step(_ commands: [Command] = [], sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            frame += 1
            let out = engine.step(FrameInput(poll: source.poll(), screen: ChaseExampleTests.screen,
                                             commands: commands, now: now, timeZone: ChaseExampleTests.utc))
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())",
                    sourceLocation: sourceLocation)
            for e in out.events where e.type == .wishFulfilled { fulfilled.append((now, e)) }
            return out
        }

        /// 逐帧推进，直到本帧时刻等于 `t`（`t` 必须是帧时刻）。
        func step(until t: Date, sourceLocation: SourceLocation = #_sourceLocation) {
            while now < t { step(sourceLocation: sourceLocation) }
            #expect(now == t, sourceLocation: sourceLocation)
        }

        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }
        var chase: ChaseState? { engine.state.wishes.active.first { $0.type == .chase }?.chase }

        /// 开局一帧后放好两人，下一帧从 Debug 触发 Chase_Wish（Wisher 为 B）；返回 ready 开始时间。
        func start(a: Resident, b: Resident, sourceLocation: SourceLocation = #_sourceLocation) -> Date {
            step(sourceLocation: sourceLocation)
            engine.place(a)
            engine.place(b)
            step([.triggerWish(.chase, .b)], sourceLocation: sourceLocation)
            #expect(chase?.phase == .ready, sourceLocation: sourceLocation)
            #expect(chase?.readyAt == now, sourceLocation: sourceLocation)
            return now
        }

        /// 触发并推进到 running；返回追逐开始时间。
        func startRunning(a: Resident, b: Resident, sourceLocation: SourceLocation = #_sourceLocation) -> Date {
            let readyAt = start(a: a, b: b, sourceLocation: sourceLocation)
            let runningAt = readyAt.addingTimeInterval(ChaseExampleTests.c.chaseReadyDuration)
            step(until: runningAt, sourceLocation: sourceLocation)
            #expect(chase?.phase == .running, sourceLocation: sourceLocation)
            #expect(chase?.runningAt == runningAt, sourceLocation: sourceLocation)
            return runningAt
        }

        /// 只有一条 `wish_fulfilled`，在 `t` 那一帧写入，Chase_Outcome 为 `outcome`。
        func expectSingleOutcome(_ outcome: String, at t: Date, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(fulfilled.count == 1, "\(fulfilled.map(\.1))", sourceLocation: sourceLocation)
            #expect(fulfilled.first?.0 == t, sourceLocation: sourceLocation)
            #expect(fulfilled.first?.1.detail["wish_type"] == "chase", sourceLocation: sourceLocation)
            #expect(fulfilled.first?.1.detail["chase_outcome"] == outcome, sourceLocation: sourceLocation)
            #expect(engine.state.wishes.active.isEmpty, sourceLocation: sourceLocation)
        }

        /// 让居民从 `from` 开始下落（朝向 `facing`）。
        func drop(_ id: ResidentID, from p: Point, facing: Facing) {
            var r = resident(id)
            r.state = .falling
            r.attachment = .free(p)
            r.fall = FallState(position: p)
            r.route = nil
            r.traversal = nil
            r.facing = facing
            engine.place(r)
        }
    }

    // MARK: - ready（Requirement 20.4、20.8）

    /// ready 中 Chaser 从窗沿上方下落：落地那一帧停在落点、`idle` 并面朝 Runner；下落不暂停 Chase_Ready_Duration，
    /// 仍在触发后恰好 2 秒的那一帧进入 running（前一帧仍是 ready）。
    @Test func fallDuringReadyLandsFacingOtherAndKeepsReadyTimer() {
        let sim = Sim(Self.touching)
        let readyAt = sim.start(
            a: Resident(id: .a, attachment: .window(1, offset: 50), facing: .left),   // x 150
            b: Resident(id: .b, attachment: .window(2, offset: 150), facing: .left))  // x 450
        // 从窗口 1 窗沿上方 100pt、朝左开始下落（Runner 在右边）。
        sim.drop(.a, from: Point(x: 150, y: 300), facing: .left)

        var sawFalling = false
        var landed = false
        let lastReadyFrame = readyAt.addingTimeInterval(Self.c.chaseReadyDuration - Self.dt)
        while sim.now < lastReadyFrame {
            sim.step()
            #expect(sim.chase?.phase == .ready)
            let a = sim.resident(.a)
            if a.state == .falling {
                sawFalling = true
            } else if sawFalling {
                if !landed {
                    // 落地的同一帧（Requirement 20.8）。
                    #expect(a.state == .idle)
                    #expect(a.attachment == .window(1, offset: 50))
                    #expect(a.facing == .right)
                }
                landed = true
            }
        }
        #expect(sawFalling && landed)
        #expect(sim.resident(.a).attachment == .window(1, offset: 50))
        #expect(sim.resident(.a).facing == .right)

        sim.step()
        #expect(sim.chase?.phase == .running)
        #expect(sim.chase?.runningAt == readyAt.addingTimeInterval(Self.c.chaseReadyDuration))
    }

    // MARK: - running 中的计时（Requirement 21.9、21.10、22.2）

    /// running 中 Runner 所在窗口关闭、下落到下方窗口：下落期间追逐继续，落地后 1 秒内按第 3、6 条继续
    /// （Chaser 在 Ground 上不可达：Chaser `waiting`、Runner `idle` 面朝 Chaser）；计时不暂停，恰好满 60 秒得出
    /// `escaped`。
    @Test func fallDuringRunningKeepsChaseTimer() {
        let windows = [
            Self.win(1, x: 300, y: 300, w: 200, h: 100),   // Runner 所在的窗口（y 300 → 400）
            Self.win(2, x: 250, y: 500, w: 300, h: 200),   // 下方的窗口，上沿 y 500
        ]
        let sim = Sim(windows)
        let runningAt = sim.startRunning(
            a: Resident(id: .a, attachment: .ground(x: 1000)),
            b: Resident(id: .b, attachment: .window(1, offset: 100)))   // x 400
        #expect(sim.resident(.a).goal == .wait(face: .resident(.b)))

        sim.step(until: runningAt.addingTimeInterval(10))
        sim.source.close(1)
        var sawFalling = false
        var landedAt: Int?
        for _ in 0 ..< 3 * Self.oneSecond {
            sim.step()
            #expect(sim.chase?.phase == .running)
            let b = sim.resident(.b)
            if b.state == .falling { sawFalling = true; continue }
            if sawFalling, case .window(2, _) = b.attachment {
                landedAt = sim.frame
                break
            }
        }
        guard let landedAt else {
            Issue.record("Runner 应落到窗口 2 的窗沿上（\(sim.resident(.b).attachment)）")
            return
        }
        #expect(sawFalling)
        // 落地后 1 秒内继续追逐（Requirement 21.9）。
        while sim.frame < landedAt + Self.oneSecond { sim.step() }
        #expect(sim.resident(.b).goal == .hold(face: .resident(.a)))
        #expect(sim.resident(.b).state == .idle)
        #expect(sim.resident(.a).state == .waiting)

        let end = runningAt.addingTimeInterval(Self.c.chaseDuration)
        sim.step(until: end.addingTimeInterval(-Self.dt))
        #expect(sim.fulfilled.isEmpty)
        #expect(sim.chase?.phase == .running)
        sim.step()
        sim.expectSingleOutcome("escaped", at: end)
    }

    /// running 中 Runner 所在窗口成为 Hidden_Window 15 秒：期间 Runner 原地暂停、Chaser `waiting`；恢复后 0.5 秒内
    /// 两人按第 3、6 条行动；计时不暂停，恰好满 60 秒得出 `escaped`。
    @Test func hiddenWindowDuringRunningKeepsChaseTimer() {
        let sim = Sim(Self.touching)
        let runningAt = sim.startRunning(
            a: Resident(id: .a, attachment: .ground(x: 1000)),
            b: Resident(id: .b, attachment: .window(2, offset: 100)))   // x 400

        sim.step(until: runningAt.addingTimeInterval(5))
        let before = sim.resident(.b).attachment
        sim.source.hide(2)
        while sim.now < runningAt.addingTimeInterval(20) {
            sim.step()
            #expect(sim.chase?.phase == .running)
            #expect(sim.resident(.b).attachment == before)
            #expect(sim.resident(.a).goal == .wait(face: .resident(.b)))
            #expect(sim.resident(.a).state == .waiting)
        }
        sim.source.show(2)
        for _ in 0 ..< Int(Self.c.chaseReplanInterval / Self.dt) { sim.step() }
        #expect(sim.resident(.b).goal == .hold(face: .resident(.a)))
        #expect(sim.resident(.b).state == .idle)
        #expect(sim.resident(.a).state == .waiting)

        let end = runningAt.addingTimeInterval(Self.c.chaseDuration)
        sim.step(until: end.addingTimeInterval(-Self.dt))
        #expect(sim.fulfilled.isEmpty)
        sim.step()
        sim.expectSingleOutcome("escaped", at: end)
    }

    // MARK: - 结局（Requirement 22.2）

    /// 满 60 秒的那一帧同时满足抓到条件（两人在 Ground 上相距 4pt）：取 `caught`，只写一条 `wish_fulfilled`。
    @Test func caughtWinsWhenChaseDurationEndsOnSameFrame() {
        let sim = Sim(Self.touching)
        let runningAt = sim.startRunning(
            a: Resident(id: .a, attachment: .ground(x: 1000)),
            b: Resident(id: .b, attachment: .window(2, offset: 100)))
        let end = runningAt.addingTimeInterval(Self.c.chaseDuration)
        sim.step(until: end.addingTimeInterval(-Self.dt))
        #expect(sim.fulfilled.isEmpty)
        #expect(sim.resident(.a).attachment == .ground(x: 1000))

        // 下一帧之前把 Runner 放到 Chaser 旁边：这一帧内两人各移动不超过 8pt，帧末相距仍不超过 Catch_Distance。
        var b = sim.resident(.b)
        b.state = .idle
        b.attachment = .ground(x: 1004)
        b.route = nil
        b.traversal = nil
        sim.engine.place(b)
        sim.step()
        sim.expectSingleOutcome("caught", at: end)
        sim.step()
        #expect(sim.fulfilled.count == 1)
    }

    // MARK: - 未庆祝的居民（Requirement 22.3、22.6）

    enum Absence: String, CaseIterable, Sendable {
        /// 结局时 Runner 附着在 Hidden_Window 上。
        case hidden
        /// 结局时 Runner 正在下落。
        case falling
    }

    /// 结局时 Runner 不能庆祝（附着在 Hidden_Window 上，或正在下落）：只有 Chaser 庆祝。Runner 恢复（窗口重新显示
    /// 或落地）后 1 秒内选出下一个 Activity，速度倍数恢复为 1、之后不再 `running`，Walk_Distance 不归零。
    @Test(arguments: Absence.allCases)
    func uncelebratedResidentPicksActivityAfterRecoveryKeepingWalkDistance(_ absence: Absence) {
        let sim = Sim(Self.touching)
        let runningAt: Date
        switch absence {
        case .hidden:
            // 两人在窗沿上可达：running 头 1 秒都在跑，随后隐藏 Runner 所在的窗口 2 直到结局之后。
            runningAt = sim.startRunning(
                a: Resident(id: .a, attachment: .window(1, offset: 10)),    // x 110
                b: Resident(id: .b, attachment: .window(2, offset: 100)))   // x 400
            sim.step(until: runningAt.addingTimeInterval(1))
            guard case .window(2, _) = sim.resident(.b).attachment else {
                Issue.record("running 1 秒后 Runner 应仍在窗口 2 上（\(sim.resident(.b).attachment)）")
                return
            }
            #expect(sim.resident(.a).walkDistance > 0)
            #expect(sim.resident(.b).walkDistance > 0)
            sim.source.hide(2)
            sim.step(until: runningAt.addingTimeInterval(Self.c.chaseDuration))
        case .falling:
            // Chaser 在 Ground 上不可达；Runner 带着追逐前累计的 Walk_Distance。结局前 2 帧关闭 Runner 所在窗口。
            runningAt = sim.startRunning(
                a: Resident(id: .a, attachment: .ground(x: 1000)),
                b: Resident(id: .b, attachment: .window(2, offset: 100), walkDistance: 200))
            sim.step(until: runningAt.addingTimeInterval(Self.c.chaseDuration - 2 * Self.dt))
            sim.source.close(2)
            sim.step(until: runningAt.addingTimeInterval(Self.c.chaseDuration))
            #expect(sim.resident(.b).state == .falling)
        }

        sim.expectSingleOutcome("escaped", at: runningAt.addingTimeInterval(Self.c.chaseDuration))
        let a = sim.resident(.a), b = sim.resident(.b)
        #expect(a.state == .celebrating && a.bubble == .heart)
        #expect(b.state != .celebrating && b.bubble != .heart)
        #expect(b.speedFactor == 1 && b.routeMetric == .standard)
        let walked = b.walkDistance
        #expect(walked > 0)

        // 庆祝的 Chaser：庆祝结束后 1 秒内选出 Activity。未恢复的 Runner 不补播庆祝。
        let celebrateEnd = sim.now.addingTimeInterval(StoryDirector.celebrateDuration)
        var chaserPicked = false
        while sim.now < celebrateEnd.addingTimeInterval(1) {
            sim.step()
            if sim.engine.state.activities[.a] != nil { chaserPicked = true }
            #expect(sim.resident(.b).state != .celebrating)
            #expect(sim.resident(.b).bubble != .heart)
            if absence == .falling, sim.resident(.b).state != .falling { break }
        }

        // Runner 恢复。
        var recoveredAt: Int?
        switch absence {
        case .hidden:
            #expect(chaserPicked)
            sim.source.show(2)
            recoveredAt = sim.frame + 1
        case .falling:
            for _ in 0 ..< 2 * Self.oneSecond where sim.resident(.b).state == .falling { sim.step() }
            if sim.resident(.b).state != .falling { recoveredAt = sim.frame }
        }
        guard let recoveredAt else {
            Issue.record("Runner 应已落地（\(sim.resident(.b).state)）")
            return
        }
        var picked: Activity?
        while sim.frame < recoveredAt + Self.oneSecond, picked == nil {
            sim.step()
            picked = sim.engine.state.activities[.b]
        }
        #expect(picked != nil, "Runner 恢复后 1 秒内应选出 Activity")
        #expect(sim.resident(.b).walkDistance >= walked)

        // 此后速度倍数为 1、不再 `running`。
        for _ in 0 ..< 3 * Self.oneSecond {
            sim.step()
            #expect(sim.resident(.b).state != .running)
            #expect(sim.resident(.b).speedFactor == 1)
        }
        #expect(sim.fulfilled.count == 1)
    }
}
