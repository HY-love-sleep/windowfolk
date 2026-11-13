import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// Activity_Planner 接入 WorldEngine 后的模拟类属性测试（design.md Property 9，任务 5.7；Property 12 由任务 5.8 追加）。
//
// 随机世界：1 至 3 个窗口、两位居民（剧情关闭时放在窗沿或 Ground 上；剧情开启时由剧情开局放置）、
// 0 至 4 个 Chair 或 Lamp。随机操作：等待、切换昼夜覆盖、移动窗口、关闭窗口（居民下落）、拖动 Decor 再放下、
// 「让都都去找嘟嘟」（剧情关闭时都都在寻找期间是 Busy_Resident）、快进剧情。时区固定为 UTC。
//
// Busy_Resident 按定义独立判定：参与 active Wish 的居民（含送花的 Giver 与 Receiver）、Wish 完成后庆祝中的居民，
// 以及调试寻找中的都都。

struct ActivityEngineTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let dt = 1.0 / 30
    static let groundY = 825.0

    // MARK: - 生成器

    struct WindowSpec: Sendable {
        var x: Int, y: Int, w: Int
    }

    struct Placement: Sendable {
        /// 0 为 Ground，其余为窗口下标 + 1（超出窗口数时取模）。
        var surface: Int
        /// 位置比例（0...10）。
        var frac: Int
    }

    struct DecorSpec: Sendable {
        var isLamp: Bool
        var at: Placement
    }

    struct Op: Sendable, CustomStringConvertible {
        var kind: Int
        var index: Int
        var a: Int
        var b: Int
        var frames: Int

        static let names = ["wait", "wait", "night", "day", "auto", "move", "close", "drag", "seek", "fastForward"]
        var description: String { "\(Self.names[kind])(\(index), \(a), \(b)) + \(frames)f" }
    }

    struct Scenario: Sendable, CustomStringConvertible {
        var windows: [WindowSpec]
        var residents: [Placement]
        var decors: [DecorSpec]
        var story: Bool
        var startHour: Int
        var seed: Int
        var ops: [Op]

        var description: String {
            "story \(story) hour \(startHour) seed \(seed) windows \(windows.map { "(\($0.x),\($0.y),\($0.w))" }) "
                + "residents \(residents.map { "\($0.surface):\($0.frac)" }) "
                + "decors \(decors.map { "\($0.isLamp ? "lamp" : "chair")@\($0.at.surface):\($0.at.frac)" }) "
                + "ops \(ops)"
        }
    }

    static var placement: Generator<Placement, some SendableSequenceType> {
        zip(Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...10)).map { Placement(surface: $0, frac: $1) }
    }

    static var scenario: Generator<Scenario, some SendableSequenceType> {
        let window = zip(Gen<Int>.int(in: 0...25), Gen<Int>.int(in: 5...14), Gen<Int>.int(in: 5...10))
            .map { WindowSpec(x: $0 * 40, y: $1 * 40, w: $2 * 40) }
        let decor = zip(Gen<Bool>.bool, placement).map { DecorSpec(isLamp: $0, at: $1) }
        let op = zip(
            Gen<Int>.int(in: 0...9), Gen<Int>.int(in: 0...3), Gen<Int>.int(in: -10...10),
            Gen<Int>.int(in: -10...10), Gen<Int>.int(in: 1...40)
        ).map { Op(kind: $0, index: $1, a: $2, b: $3, frames: $4) }
        return zip(
            window.array(of: 1...3),
            placement.array(of: 2),
            decor.array(of: 0...4),
            Gen<Int>.int(in: 0...3),     // 0 剧情开启，其余剧情关闭
            Gen<Int>.int(in: 0...23),
            Gen<Int>.int(in: 0...1_000_000),
            op.array(of: 1...12)
        ).map { windows, residents, decors, story, hour, seed, ops in
            Scenario(windows: windows, residents: residents, decors: decors, story: story == 0,
                     startHour: hour, seed: seed, ops: ops)
        }
    }

    // MARK: - 模拟

    final class Sim {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now: Date
        var windows: [WindowSnapshot]

        init(_ s: Scenario, constants: Tunables = Tunables()) {
            now = Date(timeIntervalSince1970: 23 * 86400 + Double(s.startHour) * 3600)
            windows = s.windows.enumerated().map { i, w in
                StoryEngineTests.win(WindowID(i + 1), x: Double(w.x), y: Double(w.y), w: Double(w.w), h: 160)
            }
            engine = WorldEngine(constants: constants, clockStart: now, screen: ActivityEngineTests.screen,
                                 rng: RandomSource(seed: UInt64(s.seed)), demoResident: false,
                                 story: s.story, activities: true)
            source = FakeWindowSource(snapshots: windows)
            if !s.story {
                for (i, p) in s.residents.enumerated() {
                    engine.place(Resident(id: i == 0 ? .a : .b, attachment: attachment(p)))
                }
            }
            for (i, d) in s.decors.enumerated() {
                engine.insertDecor(Decor(id: DecorID(UInt64(i + 1)), type: d.isLamp ? .lamp : .chair,
                                         placement: .attached(attachment(d.at))))
            }
        }

        func attachment(_ p: Placement) -> CoreAttachment {
            if p.surface == 0 || windows.isEmpty {
                return .ground(x: 100 + Double(p.frac) * 120)
            }
            let w = windows[(p.surface - 1) % windows.count]
            return .window(w.id, offset: w.frame.width * Double(p.frac) / 10)
        }

        @discardableResult
        func step(_ commands: [Command] = [], pointer: [PointerEvent] = []) -> StepOutput {
            now = now.addingTimeInterval(ActivityEngineTests.dt)
            return engine.step(FrameInput(poll: source.poll(), screen: ActivityEngineTests.screen,
                                          pointer: pointer, commands: commands, now: now,
                                          timeZone: ActivityEngineTests.utc))
        }

        /// 按定义判定的 Busy_Resident：参与 active Wish 的居民（v2 任务 7.4 起送花也是 Wish），Wish 完成后庆祝中的
        /// 居民（庆祝结束后再选择 Activity），以及调试寻找中的都都。
        var busy: Set<ResidentID> {
            var out = engine.state.wishes.busy
            out.formUnion(engine.state.wishes.celebrations.keys)
            if engine.seekOverride != nil || engine.debugSeekActive { out.insert(.a) }
            return out
        }
    }

    // MARK: - 检查器

    /// 每次 step 结束时检查 Property 9。`covered[id]` 是该居民最近一次「有 Activity 或不要求有 Activity」的时刻。
    static func check(_ sim: Sim, covered: inout [ResidentID: Date], previous: Date) -> [String] {
        var out: [String] = []
        let st = sim.engine.state
        for id in st.activities.keys where st.residents[id] == nil {
            out.append("activity for absent resident \(id)")
        }
        let busy = sim.busy
        for id in ResidentID.allCases {
            guard let r = st.residents[id] else {
                covered[id] = nil
                continue
            }
            let a = st.activities[id]
            if busy.contains(id) || r.state == .falling || r.state == .hanging {
                if a != nil { out.append("\(id) busy=\(busy.contains(id)) state=\(r.state) has activity \(a!.kind)") }
                covered[id] = sim.now
            } else if a != nil || r.state == .climbing {
                // 爬梯中不要求重新选择（Requirement 4.1 只约束非 climbing 状态）。
                covered[id] = sim.now
            } else {
                // 无 Activity：自最近一次被覆盖（或居民出现）起不得超过 1 秒。
                let since = covered[id] ?? previous
                if covered[id] == nil { covered[id] = previous }
                if sim.now.timeIntervalSince(since) > 1.0 + 1e-9 {
                    out.append("\(id) state=\(r.state) without activity for \(sim.now.timeIntervalSince(since))s")
                }
            }
        }
        return out
    }

    /// 执行一个操作（第一帧可带命令和指针事件），之后等待 `frames` 帧；每帧检查。
    static func run(_ op: Op, _ sim: Sim, covered: inout [ResidentID: Date], violations: inout [String]) {
        var commands: [Command] = []
        var pointer: [PointerEvent] = []
        var release: Point?
        switch Op.names[op.kind] {
        case "night": commands = [.setDayNight(.night)]
        case "day": commands = [.setDayNight(.day)]
        case "auto": commands = [.setDayNight(.auto)]
        case "seek": commands = [.debugSeek]
        case "fastForward": commands = [.fastForward]
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
            sim.windows.remove(at: i)
        case "drag":
            let decors = sim.engine.state.decors.sortedIDs
            guard !decors.isEmpty,
                  let view = sim.step().view.decors.first(where: { $0.id == decors[op.index % decors.count] }),
                  !view.isFalling, !view.isDragged else { break }
            if let v = check(sim, covered: &covered, previous: sim.now.addingTimeInterval(-dt)).first {
                violations.append(v)
            }
            let p = Point(x: view.position.x, y: view.position.y - 4)
            let to = Point(x: min(max(p.x + Double(op.a) * 30, 20), 1400), y: min(max(p.y + Double(op.b) * 30, 60), 800))
            pointer = [.down(p), .moved(to)]
            release = to
        default: break
        }
        for f in 0 ..< op.frames {
            let previous = sim.now
            var ptr: [PointerEvent] = f == 0 ? pointer : []
            if f == op.frames - 1, let r = release { ptr.append(.up(r)) }
            sim.step(f == 0 ? commands : [], pointer: ptr)
            violations += check(sim, covered: &covered, previous: previous)
            if !violations.isEmpty { return }
        }
    }

    // MARK: - 属性

    // Feature: V2, Property 9: 每位空闲居民恰好一个 Activity
    // **Validates: Requirements 4.1, 4.2**
    @Test func idleResidentsHaveExactlyOneActivity() async {
        await propertyCheck(count: 100, input: Self.scenario) { s in
            let sim = Sim(s)
            var covered: [ResidentID: Date] = [:]
            var violations: [String] = []
            let start = sim.now
            sim.step()
            violations += Self.check(sim, covered: &covered, previous: start)
            for op in s.ops where violations.isEmpty {
                Self.run(op, sim, covered: &covered, violations: &violations)
            }
            #expect(violations.isEmpty, "\(violations.prefix(3))")
        }
    }

    // MARK: - Property 12

    /// Property 12 使用的常量：缩短 Activity 时长、Sit_Duration，加快步行，让 `rest` 和坐下在短模拟内频繁出现。
    static let seatConstants: Tunables = {
        var c = Tunables()
        c.activityMinDuration = 0.5
        c.activityMaxDuration = 1.5
        c.sitDuration = 1.5
        c.walkSpeed = 120
        return c
    }()

    /// Property 12 的场景：复用 `scenario`，Decor 以 Chair 为主（每 4 个中约 1 个 Lamp），
    /// 并放在某位居民附近的同一 Surface 上，使居民很快能走到 Chair 坐下。
    static var seatScenario: Generator<Scenario, some SendableSequenceType> {
        scenario.map { s in
            var s = s
            s.decors = s.decors.enumerated().map { i, d in
                let near = s.residents[i % s.residents.count]
                let frac = min(max(near.frac + (d.at.frac % 3) - 1, 0), 10)
                return DecorSpec(isLamp: d.isLamp && d.at.frac % 4 == 0, at: Placement(surface: near.surface, frac: frac))
            }
            if s.decors.isEmpty { s.decors = [DecorSpec(isLamp: false, at: s.residents[0])] }
            return s
        }
    }

    /// 每次 step 结束时检查 Property 12：每把 Chair 最多 1 位占用者；`sitting` 的居民恰好占用 1 把 Chair；
    /// 每个 `seat` 指向存在、类型为 Chair、已放在 Surface 上（不在拖动中、不在下落中）的 Decor。
    static func checkSeats(_ sim: Sim) -> [String] {
        var out: [String] = []
        let st = sim.engine.state
        var occupants: [DecorID: [ResidentID]] = [:]
        for id in ResidentID.allCases {
            guard let r = st.residents[id] else { continue }
            if r.state == .sitting, r.seat == nil { out.append("\(id) sitting without seat") }
            guard let seat = r.seat else { continue }
            occupants[seat, default: []].append(id)
            guard let d = st.decors.decors[seat] else {
                out.append("\(id) seat \(seat) does not exist")
                continue
            }
            if d.type != .chair { out.append("\(id) seat \(seat) is \(d.type)") }
            guard case .attached = d.placement else {
                out.append("\(id) seat \(seat) placement \(d.placement)")
                continue
            }
        }
        for (did, ids) in occupants where ids.count > 1 {
            out.append("chair \(did) occupied by \(ids)")
        }
        return out
    }

    /// Property 12 的操作解释（复用 `Op`，按 `kind` 重新映射）：
    /// 0、1 等待；2 拖动一个 Decor 到随机位置；3 拖动一把有人坐的 Chair（没有时拖任意 Decor）；
    /// 4 把 Decor 收回 Toolbox；5 把 Decor 拖到高处松手（下落）；6 调试寻找（Busy 切换）；7 移动窗口；
    /// 8 关闭窗口；9 快进剧情（剧情开启时切换 Busy）。
    static let seatOpNames = ["wait", "wait", "drag", "dragSeated", "stow", "lift", "seek", "move", "close", "fastForward"]

    static func runSeats(_ op: Op, _ sim: Sim, violations: inout [String]) {
        var commands: [Command] = []
        var pointer: [PointerEvent] = []
        var release: Point?
        let name = seatOpNames[op.kind]
        switch name {
        case "seek": commands = [.debugSeek]
        case "fastForward": commands = [.fastForward]
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
            sim.windows.remove(at: i)
        case "drag", "dragSeated", "stow", "lift":
            let decors = sim.engine.state.decors.sortedIDs
            guard !decors.isEmpty else { break }
            var did = decors[op.index % decors.count]
            if name == "dragSeated",
               let seated = ResidentID.allCases.compactMap({ sim.engine.state.residents[$0]?.seat }).first {
                did = seated
            }
            let out = sim.step()
            violations += checkSeats(sim)
            guard violations.isEmpty,
                  let view = out.view.decors.first(where: { $0.id == did }),
                  !view.isFalling, !view.isDragged else { break }
            let p = Point(x: view.position.x, y: view.position.y - 4)
            let to: Point
            switch name {
            case "stow":
                let t = out.view.toolbox
                to = Point(x: t.minX + t.width / 2, y: t.minY + t.height / 2)
            case "lift":
                to = Point(x: min(max(p.x + Double(op.a) * 30, 20), 1400), y: 60)
            default:
                to = Point(x: min(max(p.x + Double(op.a) * 30, 20), 1400), y: min(max(p.y + Double(op.b) * 30, 60), 800))
            }
            pointer = [.down(p), .moved(to)]
            release = to
        default: break
        }
        for f in 0 ..< op.frames {
            var ptr: [PointerEvent] = f == 0 ? pointer : []
            if f == op.frames - 1, let r = release { ptr.append(.up(r)) }
            sim.step(f == 0 ? commands : [], pointer: ptr)
            violations += checkSeats(sim)
            if !violations.isEmpty { return }
        }
    }

    // Feature: V2, Property 12: Chair 占用不变量
    // **Validates: Requirements 4.13, 3.8**
    @Test func chairOccupancyInvariant() async {
        await propertyCheck(count: 100, input: Self.seatScenario) { s in
            let sim = Sim(s, constants: Self.seatConstants)
            var violations: [String] = []
            sim.step()
            violations += Self.checkSeats(sim)
            for op in s.ops where violations.isEmpty {
                Self.runSeats(op, sim, violations: &violations)
            }
            #expect(violations.isEmpty, "\(violations.prefix(3))")
        }
    }
}
