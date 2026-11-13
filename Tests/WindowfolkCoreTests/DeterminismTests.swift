import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// v2 任务 16.4：确定性（Requirement 19.3）。
///
/// 两台完整 V2 世界（剧情与自主活动启用）注入同一随机种子，从同一初始状态（同一组窗口、同一 Local_Clock 起点和时区）
/// 出发，各用一个 `ManualLocalClock` 按同一序列推进，并接受同一串窗口变化、调试命令和玩家鼠标操作（点击、拖动）。
/// 结束时两台产生的 Wish 序列（类型、Wisher、创建时间、Visit_Target）、Activity 序列（居民、类型、目标、开始时间、
/// `wander` 时长）和事件序列完全相同，随机源也停在同一状态。
///
/// 物件 ID 是 `UUID()`，两台各自生成的 ID 不同。比较前用 `ThoughtIsolationTests.ItemIDMap` 按出现顺序把第一台的
/// 物件 ID 配对到第二台，再替换第一台记录中的物件 ID。
struct DeterminismTests {
    // Feature: V2, Property 53: 确定性
    /// **Validates: Requirements 19.3**
    @Test func sameSeedSameInputsGiveSameSequences() async {
        await propertyCheck(count: 100, input: determinismScenario) { s in
            let report = Self.run(s)
            #expect(report.mismatch == nil, "\(s)\n\(report.mismatch ?? "")")
        }
    }

    /// 确认生成的场景确实产生了 Wish、Activity（含 `wander`）与玩家交互，否则比较只覆盖了空序列。
    @Test func scenariosProduceWishesActivitiesAndInteractions() {
        var rng = Xoshiro(seed: (53, 19, 3, 7))
        var wishes = 0, activities = 0, wanders = 0, interactions = 0
        for _ in 0 ..< 10 {
            let report = Self.run(determinismScenario.run(using: &rng))
            #expect(report.mismatch == nil, "\(report.mismatch ?? "")")
            wishes += report.wishes
            activities += report.activities
            wanders += report.wanders
            interactions += report.interactions
        }
        #expect(wishes > 0)
        #expect(activities > 0)
        #expect(wanders > 0)
        #expect(interactions > 0)
    }

    // MARK: - 记录

    /// Wish 序列中的一项：Wish 第一次出现在 `active` 时记录。
    struct WishRecord: Hashable, CustomStringConvertible {
        var id: WishID
        var type: WishType
        var wisher: ResidentID
        var createdAt: Date
        var visitTarget: VisitTarget?
        var description: String {
            "#\(id.rawValue) \(type) by \(wisher) at \(createdAt.timeIntervalSince1970) visit \(String(describing: visitTarget))"
        }
    }

    /// Activity 序列中的一项：居民的 Activity 换成新的一个（种类、目标或开始时间改变）时记录。
    struct ActivityRecord: Hashable, CustomStringConvertible {
        var resident: ResidentID
        var kind: ActivityKind
        var target: ActivityTarget
        var startedAt: Date
        var wanderDuration: TimeInterval?
        var description: String {
            "\(resident) \(kind) → \(target) at \(startedAt.timeIntervalSince1970) wander \(String(describing: wanderDuration))"
        }
    }

    struct Trace {
        var wishes: [WishRecord] = []
        var activities: [ActivityRecord] = []
        var events: [EventRecord] = []
        var seenWishes: Set<WishID> = []
        var current: [ResidentID: ActivityRecord] = [:]

        /// `mapItem` 把本台的物件 ID 换成参照台的 ID（参照台自身传恒等映射）。
        mutating func record(_ engine: WorldEngine, _ out: StepOutput, ids: ThoughtIsolationTests.ItemIDMap) {
            for w in engine.state.wishes.active where !seenWishes.contains(w.id) {
                seenWishes.insert(w.id)
                wishes.append(WishRecord(id: w.id, type: w.type, wisher: w.wisher,
                                         createdAt: w.createdAt, visitTarget: w.visitTarget))
            }
            let acts = ids.activities(engine.state.activities)
            for id in ResidentID.allCases {
                guard let a = acts[id] else { current[id] = nil; continue }
                let rec = ActivityRecord(resident: id, kind: a.kind, target: a.target,
                                         startedAt: a.startedAt, wanderDuration: a.wanderDuration)
                if current[id] != rec {
                    current[id] = rec
                    activities.append(rec)
                }
            }
            events += ids.events(out.events)
        }
    }

    struct Report {
        var mismatch: String?
        var wishes = 0
        var activities = 0
        var wanders = 0
        var interactions = 0
    }

    // MARK: - 运行

    static let screen = StoryEngineTests.screen
    static let dt = 1.0 / 30

    static func constants() -> Tunables {
        var c = Tunables()
        // 让 Wish 更快出现；两台使用同一组常量。
        c.wishCheckInterval = 1
        c.wishCooldown = 5
        c.wishSpawnChance = 0.5
        return c
    }

    /// 两台各用一个独立的 `ManualLocalClock`，从同一本地日期时刻和时区起步。
    fileprivate static func makeClock(_ s: DeterminismScenario) -> ManualLocalClock {
        ManualLocalClock(year: 2026, month: 3, day: 14, hour: s.hour, minute: s.minute, second: 0,
                         timeZone: TimeZone(secondsFromGMT: s.tzOffsetHours * 3600)!)
    }

    fileprivate static func run(_ s: DeterminismScenario) -> Report {
        let c = constants()
        let clockA = makeClock(s), clockB = makeClock(s)
        let a = WorldEngine(constants: c, clockStart: clockA.now, screen: screen, rng: RandomSource(seed: s.seed), story: true)
        let b = WorldEngine(constants: c, clockStart: clockB.now, screen: screen, rng: RandomSource(seed: s.seed), story: true)
        var source = FakeWindowSource(snapshots: s.windows)
        var hidden = false
        var regions: [HitRegion] = []
        var ids = ThoughtIsolationTests.ItemIDMap()
        let same = ThoughtIsolationTests.ItemIDMap()
        var traceA = Trace(), traceB = Trace()
        var report = Report()
        var frame = 0

        for op in s.ops {
            var commands: [Command] = []
            var pointer: [[PointerEvent]] = []
            let windowIDs = source.windows.map(\.snapshot.id)
            let target = windowIDs.isEmpty ? nil : windowIDs[op.index % windowIDs.count]
            switch op.kind {
            case .move:
                if let t = target, let w = source.windows.first(where: { $0.snapshot.id == t }) {
                    source.move(t, to: Point(x: w.snapshot.frame.minX + Double(op.a * 10),
                                             y: w.snapshot.frame.minY + Double(op.b * 10)))
                }
            case .close: if let t = target { source.close(t) }
            case .hide: if let t = target { source.hide(t) }
            case .show: if let t = target { source.show(t) }
            case .front: if let t = target { source.bringToFront(t) }
            case .triggerWish:
                let type = WishType.allCases[abs(op.a) % WishType.allCases.count]
                commands.append(.triggerWish(type, op.b % 2 == 0 ? .a : .b))
            case .fastForward: commands.append(.fastForward)
            case .dayNight:
                commands.append(.setDayNight(DayNightOverride.allCases[abs(op.a) % DayNightOverride.allCases.count]))
            case .unlockAll: commands.append(.unlockAllDecor)
            case .toggleHidden: hidden.toggle()
            case .click, .drag:
                if let p = Self.pick(regions, index: op.index, u: op.u, v: op.v) {
                    if op.kind == .click {
                        pointer = [[.down(p), .up(p)]]
                    } else {
                        // 按下、分几帧移动、松手；终点在屏幕内。
                        let end = Point(x: min(max(p.x + Double(op.a * 40), 5), screen.frame.width - 5),
                                        y: min(max(p.y + Double(op.b * 30), 30), screen.frame.height - 5))
                        let steps = 4
                        pointer = [[.down(p)]]
                        for k in 1 ... steps {
                            let t = Double(k) / Double(steps)
                            pointer.append([.moved(Point(x: p.x + (end.x - p.x) * t, y: p.y + (end.y - p.y) * t))])
                        }
                        pointer.append([.up(end)])
                    }
                }
            case .wait: break
            }

            let frames = max(op.frames, pointer.count)
            for f in 0 ..< frames {
                // 两台的时钟按同一序列推进；首帧可能有一次时间跳跃，让计时器和 Night 判定跨过阈值。
                let advance = op.jump && f == 0 ? Double(op.a + 25) * 2 : dt
                clockA.advance(by: advance)
                clockB.advance(by: advance)
                let poll = source.poll()
                let cmds = f == 0 ? commands : []
                let ptr = f < pointer.count ? pointer[f] : []
                frame += 1

                let outA = a.step(FrameInput(poll: poll, screen: screen, pointer: ptr, commands: cmds,
                                             now: clockA.now, timeZone: clockA.timeZone, worldHidden: hidden))
                let outB = b.step(FrameInput(poll: poll, screen: screen, pointer: ptr, commands: cmds,
                                             now: clockB.now, timeZone: clockB.timeZone, worldHidden: hidden))
                regions = outA.view.hitRegions
                report.interactions += outA.interactions.count

                ids.learn(on: a.state.items, off: b.state.items)
                traceA.record(a, outA, ids: ids)
                traceB.record(b, outB, ids: same)
                if let m = Self.firstMismatch(traceA, traceB) {
                    report.mismatch = "frame \(frame): \(m)"
                    return report
                }
            }
        }
        if a.rng != b.rng { report.mismatch = "rng state differs at end" }
        report.wishes = traceA.wishes.count
        report.activities = traceA.activities.count
        report.wanders = traceA.activities.filter { $0.kind == .wander }.count
        return report
    }

    /// 从上一帧的命中区域中选一个点。先按与物件 ID 无关的键排序，使同一场景每次运行选到同一处。
    static func pick(_ regions: [HitRegion], index: Int, u: Double, v: Double) -> Point? {
        guard !regions.isEmpty else { return nil }
        let sorted = regions.sorted {
            ($0.target.priority, $0.rect.minX, $0.rect.minY, $0.rect.width)
                < ($1.target.priority, $1.rect.minX, $1.rect.minY, $1.rect.width)
        }
        let r = sorted[index % sorted.count].rect
        return Point(x: r.minX + r.width * u, y: r.minY + r.height * v)
    }

    static func firstMismatch(_ x: Trace, _ y: Trace) -> String? {
        func diff<T: Equatable>(_ name: String, _ p: [T], _ q: [T]) -> String? {
            guard p != q else { return nil }
            let i = (0 ..< min(p.count, q.count)).first { p[$0] != q[$0] } ?? min(p.count, q.count)
            let pa = i < p.count ? "\(p[i])" : "<end>", qa = i < q.count ? "\(q[i])" : "<end>"
            return "\(name)[\(i)] differs\n  A: \(pa)\n  B: \(qa)"
        }
        return diff("wishes", x.wishes, y.wishes)
            ?? diff("activities", x.activities, y.activities)
            ?? diff("events", x.events, y.events)
    }
}

// MARK: - 生成器

fileprivate enum OpKind: CaseIterable, Sendable {
    case move, close, hide, show, front, triggerWish, fastForward, dayNight, unlockAll, toggleHidden,
         click, drag, wait
}

fileprivate struct DeterminismOp: Sendable, CustomStringConvertible {
    var kind: OpKind
    var index: Int
    var a: Int
    var b: Int
    var u: Double
    var v: Double
    var frames: Int
    var jump: Bool
    var description: String {
        "\(kind)(\(index), \(a), \(b), \(u), \(v)) ×\(frames)\(jump ? " +jump" : "")"
    }
}

fileprivate struct DeterminismScenario: Sendable, CustomStringConvertible {
    var seed: UInt64
    var hour: Int
    var minute: Int
    var tzOffsetHours: Int
    var windows: [WindowSnapshot]
    var ops: [DeterminismOp]
    var description: String {
        "seed \(seed), start \(hour):\(minute) GMT\(tzOffsetHours >= 0 ? "+" : "")\(tzOffsetHours), "
            + "windows \(windows.map { ($0.id, $0.frame) }), ops \(ops)"
    }
}

fileprivate let opGen = zip(
    Gen<Int>.int(in: 0 ... OpKind.allCases.count - 1),
    Gen<Int>.int(in: 0 ... 15),
    Gen<Int>.int(in: -12 ... 12),
    Gen<Int>.int(in: -12 ... 12),
    zip(Gen<Int>.int(in: 1 ... 9), Gen<Int>.int(in: 1 ... 9)),
    Gen<Int>.int(in: 1 ... 12),
    Gen<Bool>.bool
).map { kind, index, a, b, uv, frames, jump in
    DeterminismOp(kind: OpKind.allCases[kind], index: index, a: a, b: b,
                  u: Double(uv.0) / 10, v: Double(uv.1) / 10, frames: frames, jump: jump)
}

fileprivate let windowGen = zip(
    Gen<Int>.int(in: 0 ... 120),
    Gen<Int>.int(in: 10 ... 70),
    Gen<Int>.int(in: 15 ... 35)
).map { x, y, w in (x * 10, y * 10, w * 10) }
    .array(of: 2 ... 4)
    .map { specs in
        specs.enumerated().map { i, s in
            StoryEngineTests.win(WindowID(i + 1), x: Double(s.0), y: Double(s.1), w: Double(s.2))
        }
    }

fileprivate let determinismScenario = zip(
    Gen<UInt64>.uint64(in: 0 ... 1_000_000),
    Gen<Int>.int(in: 0 ... 23),
    Gen<Int>.int(in: 0 ... 59),
    Gen<Int>.int(in: -10 ... 12),
    windowGen,
    opGen.array(of: 3 ... 18)
).map { DeterminismScenario(seed: $0, hour: $1, minute: $2, tzOffsetHours: $3, windows: $4, ops: $5) }
