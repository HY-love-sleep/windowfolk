import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// Wish 生命周期的模拟类属性测试（design.md Property 20，任务 7.7；Property 21 由任务 7.8 追加）。
//
// 随机世界：1 至 3 个窗口，剧情启用（默认 Activity_Planner 启用），居民由剧情开局放置；0 至 3 个 Chair 或 Lamp。
// 随机操作：逐帧等待、时钟跳跃（触发 Wish 检查、冷却和超时）、`triggerWish`（各类型、各居民，含 chase 与
// 不指定 Wisher）、切换昼夜覆盖、`unlockAllDecor`、`resetWorld`、拖动 Decor（从 Decor_Slot 拖出或拖动已有的）、
// 窗口移动 / 关闭 / 隐藏 / 显示 / 新开。时区固定为 UTC。

// MARK: - 生成器

fileprivate struct WindowSpec: Sendable {
    var x: Int, y: Int, w: Int
}

fileprivate struct DecorSpec: Sendable {
    var isLamp: Bool
    /// 0 为 Ground，其余为窗口下标 + 1（超出窗口数时取模）。
    var surface: Int
    /// 位置比例（0...10）。
    var frac: Int
}

fileprivate struct Op: Sendable, CustomStringConvertible {
    var kind: Int
    var index: Int
    var a: Int
    var b: Int
    var frames: Int

    static let names = [
        "wait", "jump", "trigger", "trigger", "trigger", "night", "day", "auto",
        "unlockAll", "reset", "drag", "move", "close", "hide", "show", "add",
    ]
    var description: String { "\(Self.names[kind])(\(index), \(a), \(b)) + \(frames)f" }
}

fileprivate struct Scenario: Sendable, CustomStringConvertible {
    var windows: [WindowSpec]
    var decors: [DecorSpec]
    var startHour: Int
    var seed: Int
    var ops: [Op]

    var description: String {
        "hour \(startHour) seed \(seed) windows \(windows.map { "(\($0.x),\($0.y),\($0.w))" }) "
            + "decors \(decors.map { "\($0.isLamp ? "lamp" : "chair")@\($0.surface):\($0.frac)" }) "
            + "ops \(ops)"
    }
}

fileprivate let windowGen = zip(Gen<Int>.int(in: 0...25), Gen<Int>.int(in: 5...14), Gen<Int>.int(in: 5...10))
    .map { WindowSpec(x: $0 * 40, y: $1 * 40, w: $2 * 40) }

fileprivate var scenarioGen: Generator<Scenario, some SendableSequenceType> {
    let decor = zip(Gen<Bool>.bool, Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...10))
        .map { DecorSpec(isLamp: $0, surface: $1, frac: $2) }
    let op = zip(
        Gen<Int>.int(in: 0...(Op.names.count - 1)), Gen<Int>.int(in: 0...14), Gen<Int>.int(in: -10...10),
        Gen<Int>.int(in: -10...10), Gen<Int>.int(in: 1...30)
    ).map { Op(kind: $0, index: $1, a: $2, b: $3, frames: $4) }
    return zip(
        windowGen.array(of: 1...3),
        decor.array(of: 0...3),
        Gen<Int>.int(in: 0...23),
        Gen<Int>.int(in: 0...1_000_000),
        op.array(of: 1...10)
    ).map { windows, decors, hour, seed, ops in
        Scenario(windows: windows, decors: decors, startHour: hour, seed: seed, ops: ops)
    }
}

// MARK: - 模拟

fileprivate final class Sim {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let dt = 1.0 / 30

    let engine: WorldEngine
    var source: FakeWindowSource
    var now: Date
    /// 未关闭的窗口（含隐藏的）及其当前 frame。
    var windows: [WindowSnapshot]
    var hidden: Set<WindowID> = []
    var nextWindowID: WindowID

    init(_ s: Scenario, constants: Tunables = Tunables()) {
        now = Date(timeIntervalSince1970: 23 * 86400 + Double(s.startHour) * 3600)
        windows = s.windows.enumerated().map { i, w in
            StoryEngineTests.win(WindowID(i + 1), x: Double(w.x), y: Double(w.y), w: Double(w.w), h: 160)
        }
        nextWindowID = WindowID(windows.count + 1)
        engine = WorldEngine(constants: constants, clockStart: now, screen: Self.screen,
                             rng: RandomSource(seed: UInt64(s.seed)))
        source = FakeWindowSource(snapshots: windows)
        for (i, d) in s.decors.enumerated() {
            engine.insertDecor(Decor(id: DecorID(UInt64(i + 1)), type: d.isLamp ? .lamp : .chair,
                                     placement: .attached(attachment(d))))
        }
    }

    func attachment(_ d: DecorSpec) -> CoreAttachment {
        if d.surface == 0 || windows.isEmpty {
            return .ground(x: 100 + Double(d.frac) * 120)
        }
        let w = windows[(d.surface - 1) % windows.count]
        return .window(w.id, offset: w.frame.width * Double(d.frac) / 10)
    }

    @discardableResult
    func step(_ commands: [Command] = [], pointer: [PointerEvent] = [], advance: Double = Sim.dt) -> StepOutput {
        now = now.addingTimeInterval(advance)
        return engine.step(FrameInput(poll: source.poll(), screen: Self.screen, pointer: pointer,
                                      commands: commands, now: now, timeZone: Self.utc))
    }
}

// MARK: - 检查器

/// 每次 step 结束时检查 Property 20：每位居民最多参与 1 个 active Wish；最多 1 个 active Chase_Wish；
/// 存在 active Chase_Wish 时不存在其他 active Wish；Chase_Wish 中 Chaser 为 Resident_A、Runner 为 Resident_B。
///
/// Chaser / Runner 的角色由两人的 Goal 观察：都都只会追向嘟嘟（`.reach(.b)`）、原地等待或停住并面朝嘟嘟；
/// 嘟嘟只会逃向 Flee_Target（`.reachPoint`）或停住并面朝都都。`running` 阶段两人的速度倍数分别为
/// Chaser_Speed_Factor 与 Runner_Speed_Factor。
fileprivate func checkWishStructure(_ sim: Sim) -> [String] {
    var out: [String] = []
    let st = sim.engine.state
    let active = st.wishes.active
    let c = Tunables()

    for w in active where w.state != .active {
        out.append("wish \(w.id.rawValue) \(w.type) in active list with state \(w.state)")
    }
    for id in ResidentID.allCases {
        let n = active.filter { $0.participants.contains(id) }.count
        if n > 1 { out.append("\(id) participates in \(n) active wishes \(active.map(\.type))") }
    }
    let chases = active.filter { $0.type == .chase }
    if chases.count > 1 { out.append("\(chases.count) active chase wishes") }
    if !chases.isEmpty, active.count > 1 {
        out.append("chase coexists with other wishes \(active.map(\.type))")
    }
    for w in chases {
        guard let chase = w.chase else {
            out.append("chase wish \(w.id.rawValue) without chase state")
            continue
        }
        if w.participants != [.a, .b] { out.append("chase participants \(w.participants)") }
        if let a = st.residents[ChaseRules.chaser] {
            switch a.goal {
            case .reach(.b), .wait(face: .resident(.b)), .hold(face: .resident(.b)): break
            default: out.append("chaser A has goal \(a.goal) (phase \(chase.phase))")
            }
            if chase.phase == .running, a.speedFactor != c.chaserSpeedFactor {
                out.append("chaser A speedFactor \(a.speedFactor)")
            }
        }
        if let b = st.residents[ChaseRules.runner] {
            switch b.goal {
            case .reachPoint, .hold(face: .resident(.a)): break
            default: out.append("runner B has goal \(b.goal) (phase \(chase.phase))")
            }
            if chase.phase == .running, b.speedFactor != c.runnerSpeedFactor {
                out.append("runner B speedFactor \(b.speedFactor)")
            }
        }
    }
    return out
}

/// 执行一个操作（第一帧带命令、指针事件或窗口变化），之后共推进 `frames` 帧；每帧检查。
fileprivate func run(_ op: Op, _ sim: Sim, violations: inout [String]) {
    var commands: [Command] = []
    var pointer: [PointerEvent] = []
    var release: Point?
    var advance = Sim.dt
    switch Op.names[op.kind] {
    case "jump":
        // 跳过 10 至 700 秒：覆盖 Wish_Check_Interval、Wish_Cooldown、Chase_Duration 等时长（dt 由引擎限幅）。
        advance = 10 + Double(op.index * 40 + (op.a + 10) * 3)
    case "trigger":
        let type = WishType.allCases[op.index % WishType.allCases.count]
        let wisher: ResidentID? = [ResidentID.a, .b, nil][(op.a + 10) % 3]
        commands = [.triggerWish(type, wisher)]
    case "night": commands = [.setDayNight(.night)]
    case "day": commands = [.setDayNight(.day)]
    case "auto": commands = [.setDayNight(.auto)]
    case "unlockAll": commands = [.unlockAllDecor]
    case "reset": commands = [.resetWorld]
    case "drag":
        let unlocked = sim.engine.state.decors.unlocked.sorted { $0.rawValue < $1.rawValue }
        var from: Point?
        if op.index % 2 == 0, !unlocked.isEmpty,
           let r = ToolboxLayout.zoneFrame(.decor(unlocked[op.index / 2 % unlocked.count]), screen: Sim.screen,
                                           unlocked: sim.engine.state.decors.unlocked) {
            from = Point(x: r.midX, y: r.midY)
        } else {
            let ids = sim.engine.state.decors.sortedIDs
            if !ids.isEmpty {
                let view = sim.step().view
                violations += checkWishStructure(sim)
                if let d = view.decors.first(where: { $0.id == ids[op.index % ids.count] }),
                   !d.isFalling, !d.isDragged {
                    from = SpriteMetrics.decorRect(type: d.type, bottomCenter: d.position).center
                }
            }
        }
        guard let p = from else { break }
        let to = Point(x: min(max(p.x + Double(op.a) * 40, 20), 1400), y: min(max(p.y + Double(op.b) * 40, 60), 800))
        pointer = [.down(p), .moved(to)]
        release = to
    case "move":
        guard !sim.windows.isEmpty else { break }
        let i = op.index % sim.windows.count
        let f = sim.windows[i].frame
        let origin = Point(x: min(max(f.minX + Double(op.a) * 20, 0), 1200),
                           y: min(max(f.minY + Double(op.b) * 20, 120), 640))
        sim.source.move(sim.windows[i].id, to: origin)
        sim.windows[i].frame = Rect(minX: origin.x, minY: origin.y, width: f.width, height: f.height)
    case "close":
        guard !sim.windows.isEmpty else { break }
        let i = op.index % sim.windows.count
        sim.source.close(sim.windows[i].id)
        sim.hidden.remove(sim.windows[i].id)
        sim.windows.remove(at: i)
    case "hide":
        guard !sim.windows.isEmpty else { break }
        let id = sim.windows[op.index % sim.windows.count].id
        sim.source.hide(id)
        sim.hidden.insert(id)
    case "show":
        guard let id = sim.hidden.sorted().first else { break }
        sim.source.show(id)
        sim.hidden.remove(id)
    case "add":
        guard sim.windows.count < 4 else { break }
        let w = StoryEngineTests.win(sim.nextWindowID, x: Double((op.index * 7 + op.a + 10) % 26) * 40,
                                     y: Double(5 + (op.b + 10) % 10) * 40, w: Double(5 + op.index % 6) * 40, h: 160)
        sim.nextWindowID += 1
        sim.source.add(w)
        sim.windows.append(w)
    default: break
    }
    for f in 0 ..< op.frames {
        var ptr: [PointerEvent] = f == 0 ? pointer : []
        if f == op.frames - 1, let r = release { ptr.append(.up(r)) }
        sim.step(f == 0 ? commands : [], pointer: ptr, advance: f == 0 ? advance : Sim.dt)
        violations += checkWishStructure(sim)
        if !violations.isEmpty { return }
    }
}

// MARK: - Property 21：Wish_Timeout

/// Property 21 的一个操作：可选的 `triggerWish`，可选的时钟跳跃（Wish_Timeout 的 0 至 1.2 倍），之后共推进 `frames` 帧。
fileprivate struct TimeoutOp: Sendable, CustomStringConvertible {
    /// WishType.allCases 下标；nil 表示不触发。
    var trigger: Int?
    var wisherIsB: Bool
    /// 跳跃时长为 Wish_Timeout × jumpTenths / 10；0 表示不跳。
    var jumpTenths: Int
    var frames: Int

    var description: String {
        let t = trigger.map { "trigger(\(WishType.allCases[$0]), \(wisherIsB ? "b" : "a")) " } ?? ""
        return "\(t)jump \(jumpTenths)/10 + \(frames)f"
    }
}

fileprivate struct TimeoutScenario: Sendable, CustomStringConvertible {
    var world: Scenario
    /// 短 Wish_Timeout（20 至 45 秒，短于 Chase_Duration，使 Chase_Wish 也能保持 active 达到 Wish_Timeout）
    /// 或默认的 1800 秒。
    var timeout: Double
    var ops: [TimeoutOp]

    var description: String { "timeout \(timeout) \(world) timeoutOps \(ops)" }
}

fileprivate var timeoutScenarioGen: Generator<TimeoutScenario, some SendableSequenceType> {
    let decor = zip(Gen<Bool>.bool, Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...10))
        .map { DecorSpec(isLamp: $0, surface: $1, frac: $2) }
    let op = zip(
        Gen<Int>.int(in: -2...(WishType.allCases.count - 1)), Gen<Bool>.bool,
        Gen<Int>.int(in: -4...12), Gen<Int>.int(in: 1...30)
    ).map { t, b, j, f in TimeoutOp(trigger: t >= 0 ? t : nil, wisherIsB: b, jumpTenths: max(j, 0), frames: f) }
    return zip(
        windowGen.array(of: 1...3),
        decor.array(of: 0...2),
        Gen<Int>.int(in: 0...23),
        Gen<Int>.int(in: 0...1_000_000),
        Gen<Int>.int(in: 0...26),
        op.array(of: 2...8)
    ).map { windows, decors, hour, seed, t, ops in
        // 首个操作总是触发一个 Wish，保证每个场景至少尝试一次。
        var ops = ops
        if ops[0].trigger == nil { ops[0].trigger = seed % WishType.allCases.count }
        return TimeoutScenario(
            world: Scenario(windows: windows, decors: decors, startHour: hour, seed: seed, ops: []),
            timeout: t > 25 ? 1800 : Double(20 + t), ops: ops)
    }
}

/// 一次 step 中检查 Property 21。`before` 是 step 之前的世界状态，`out` 是本次 step 的输出。
///
/// - Chair_Wish、Lamp_Wish、Visit_Wish：step 前 active 且本次 step 的 `now - createdAt` 首次达到 Wish_Timeout 时，
///   本次 step 后不再 active，写了 `wish_dropped`（actor 为 Wisher，`wish_type` 一致），Wisher 的
///   上一个 Wish 结束时间为本次 `now`；Decor 集合、Plank、Ladder 与 step 前相同，Item 集合与 step 前相同（同一
///   step 中开始了 Flower_Wish 时除外），Unlocked_Decor 只多出
///   本次 `decor_unlocked` 记录的类型（同一 step 中另一位居民开始 Chair_Wish / Lamp_Wish 引起）。
/// - Flower_Wish、Chase_Wish：任何时候都不写 `wish_dropped`。
fileprivate func checkTimeout(before: WorldState, after: WorldState, out: StepOutput, now: Date,
                              timeout: Double) -> [String] {
    var v: [String] = []
    let dropped = out.events.filter { $0.type == .wishDropped }
    for e in dropped {
        let t = e.detail["wish_type"]
        if t == WishType.flower.rawValue || t == WishType.chase.rawValue {
            v.append("\(t!) wish dropped by \(e.actor ?? "nil")")
        }
    }
    for w in before.wishes.active where w.type != .flower && w.type != .chase {
        let age = now.timeIntervalSince(w.createdAt)
        guard age >= timeout else { continue }
        let tag = "\(w.type) wish \(w.id.rawValue) of \(w.wisher) age \(age)"
        if after.wishes.active.contains(where: { $0.id == w.id }) {
            v.append("\(tag) still active")
            continue
        }
        let ref = EventRecord.residentRef(w.wisher)
        if !dropped.contains(where: { $0.actor == ref && $0.detail["wish_type"] == w.type.rawValue }) {
            v.append("\(tag) ended without wish_dropped; events \(out.events.map(\.type))")
        }
        if after.wishes.lastEnded[w.wisher] != now {
            v.append("\(tag) lastEnded \(String(describing: after.wishes.lastEnded[w.wisher])) != now \(now)")
        }
        if after.decors.decors != before.decors.decors { v.append("\(tag) decors changed") }
        let newlyUnlocked = Set(out.events.filter { $0.type == .decorUnlocked }
            .compactMap { $0.detail["decor_type"].flatMap(DecorType.init(rawValue:)) })
        if after.decors.unlocked != before.decors.unlocked.union(newlyUnlocked) {
            v.append("\(tag) unlocked \(before.decors.unlocked) -> \(after.decors.unlocked)")
        }
        // 同一 step 中另一位居民（冷却已满的 Giver）可能紧接着开始 Flower_Wish（Requirement 8.1 不要求 Receiver
        // 冷却），剧情开局会放出种子等 Item；此时 Item 的变化来自新 Wish，不计入放弃的影响。
        let flowerStarted = out.events.contains {
            $0.type == .wishStarted && $0.detail["wish_type"] == WishType.flower.rawValue
        }
        if !flowerStarted, Set(after.items.items.keys) != Set(before.items.items.keys) {
            v.append("\(tag) items \(before.items.items.keys) -> \(after.items.items.keys)")
        }
        if after.planks.planks != before.planks.planks { v.append("\(tag) planks changed") }
        if after.ladders.ladders != before.ladders.ladders { v.append("\(tag) ladders changed") }
    }
    return v
}

// MARK: - 属性

struct WishLifecycleTests {
    // Feature: V2, Property 20: Wish 结构不变量
    // **Validates: Requirements 6.7, 20.5, 20.7**
    @Test func wishStructureInvariant() async {
        await propertyCheck(count: 100, input: scenarioGen) { s in
            let sim = Sim(s)
            var violations: [String] = []
            sim.step()
            violations += checkWishStructure(sim)
            for op in s.ops where violations.isEmpty {
                run(op, sim, violations: &violations)
            }
            #expect(violations.isEmpty, "\(violations.prefix(3))")
        }
    }

    // Feature: V2, Property 21: Wish_Timeout 只放弃普通 Wish
    // **Validates: Requirements 6.11, 8.5, 20.6**
    @Test func wishTimeoutDropsOnlyOrdinaryWishes() async {
        await propertyCheck(count: 100, input: timeoutScenarioGen) { s in
            var c = Tunables()
            c.wishTimeout = s.timeout
            let sim = Sim(s.world, constants: c)
            var violations: [String] = []
            sim.step()
            for op in s.ops where violations.isEmpty {
                var commands: [Command] = []
                if let t = op.trigger { commands = [.triggerWish(WishType.allCases[t], op.wisherIsB ? .b : .a)] }
                let jump = s.timeout * Double(op.jumpTenths) / 10
                for f in 0 ..< op.frames where violations.isEmpty {
                    let before = sim.engine.state
                    let out = sim.step(f == 0 ? commands : [], advance: f == 0 && jump > 0 ? jump : Sim.dt)
                    violations += checkTimeout(before: before, after: sim.engine.state, out: out, now: sim.now,
                                               timeout: s.timeout)
                }
            }
            #expect(violations.isEmpty, "\(violations.prefix(3))")
        }
    }
}
