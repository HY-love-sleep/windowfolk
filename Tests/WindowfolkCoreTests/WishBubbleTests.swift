import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 Wish_Bubble 测试（任务 7.15）。
// - 单元测试：Chair_Wish / Lamp_Wish / Visit_Wish 没有路线时进入 `waiting` 只写一条 `waiting_started`，
//   状态不在 idle / waiting 之间抖动，并以 Wish_Bubble 代替「...」（Requirement 6.13、7.1、7.4）。
// - Property 17：气泡与状态一致。

struct WishBubbleUnitTests {
    typealias Harness = WishEngineUnitTests.Harness

    /// 触发 `type` 后再走 `frames` 帧：返回 Wisher 的 `waiting_started` 条数和每帧结束时的状态与气泡。
    static func run(_ type: WishType, wisher: ResidentID, night: Bool = false, frames: Int = 60)
        -> (waitingStarted: Int, states: [ResidentState], bubbles: [Bubble?])
    {
        let h = Harness()
        h.step(night ? [.setDayNight(.night)] : [])
        var outs = [h.step([.triggerWish(type, wisher)])]
        for _ in 0 ..< frames { outs.append(h.step()) }
        let ref = EventRecord.residentRef(wisher)
        let count = outs.flatMap(\.events).filter { $0.type == .waitingStarted && $0.actor == ref }.count
        let views = outs.map { $0.view.residents.first { $0.id == wisher }! }
        #expect(h.engine.state.wishes.active.contains { $0.type == type && $0.wisher == wisher })
        return (count, views.map(\.state), views.map(\.bubble))
    }

    @Test func chairWishWithoutChairWaitsOnce() {
        let r = Self.run(.chair, wisher: .b)
        #expect(r.waitingStarted == 1)
        #expect(r.states.allSatisfy { $0 == .waiting }, "\(r.states)")
        #expect(r.bubbles.allSatisfy { $0 == .wishIcon(.chair) })
    }

    @Test func lampWishWithoutLampWaitsOnce() {
        let r = Self.run(.lamp, wisher: .a, night: true)
        #expect(r.waitingStarted == 1)
        #expect(r.states.allSatisfy { $0 == .waiting }, "\(r.states)")
        #expect(r.bubbles.allSatisfy { $0 == .wishIcon(.lamp) })
    }

    @Test func visitWishWithoutRouteWaitsOnce() {
        // 三扇窗口同高、互不相连：从窗口 1 到 Visit_Target 窗口 2 没有路线。
        let r = Self.run(.visit, wisher: .a)
        #expect(r.waitingStarted == 1)
        #expect(r.states.allSatisfy { $0 == .waiting }, "\(r.states)")
        #expect(r.bubbles.allSatisfy { $0 == .wishIcon(.flag(arrow: .right)) })
    }

    /// 回归（Property 17 反例）：拜访停留中被拜访者（嘟嘟）或拜访者（都都）触发 Chair_Wish 成为 Wisher：
    /// 同帧结束拜访停留（不写 visited），双方的心形清除，Wisher 显示 Wish_Bubble（Requirement 4.12、6.8、6.9）。
    @Test(arguments: [ResidentID.b, .a])
    func becomingWisherDuringVisitStayEndsStayAndShowsWishBubble(_ wisher: ResidentID) {
        let h = Harness()
        for _ in 0 ..< 5 { h.step() }
        h.engine.place(Resident(id: .a, attachment: .ground(x: 300)))
        h.engine.place(Resident(id: .b, attachment: .ground(x: 320)))
        h.engine.state.activities[.a] = Activity(kind: .visitNeighbor, target: .resident(.b), startedAt: h.now)
        h.engine.state.activities[.b] = Activity(
            kind: .wander, target: .none, startedAt: h.now, wanderUntil: h.now.addingTimeInterval(1000))
        func staying() -> Bool {
            if case .staying = h.engine.state.activities[.a]?.phase { return true }
            return false
        }
        for _ in 0 ..< 60 where !staying() { h.step() }
        #expect(staying())
        #expect(h.resident(.a).bubble == .heart && h.resident(.b).bubble == .heart)

        let out = h.step([.triggerWish(.chair, wisher)])
        let other = wisher.other
        #expect(out.view.residents.first { $0.id == wisher }?.bubble == .wishIcon(.chair))
        #expect(h.resident(other).bubble != .heart)
        #expect(!staying())
        #expect(h.engine.state.activities[wisher] == nil)
        #expect(h.engine.state.activities[other] != nil)
        #expect(h.engine.state.activities[other]?.pausedUntil == nil)
        #expect(!out.events.contains { $0.type == .visited })
    }
}

// MARK: - Property 17

/// 一扇窗口：左上角（40pt 网格）与宽度。
fileprivate struct BubbleWindowSpec: Sendable {
    var x: Int, y: Int, w: Int
}

/// 一个操作：类型、下标与两个参数，之后等待 `frames` 帧。
fileprivate struct BubbleOp: Sendable, CustomStringConvertible {
    var kind: Int, index: Int, a: Int, b: Int, frames: Int

    static let names = [
        "wait", "wait", "trigger", "trigger", "night", "day", "move", "hide", "show", "close", "decor", "poke",
    ]
    var description: String { "\(Self.names[kind])(\(index), \(a), \(b)) + \(frames)f" }
}

fileprivate struct BubbleScenario: Sendable, CustomStringConvertible {
    var windows: [BubbleWindowSpec]
    var startHour: Int
    var seed: Int
    var ops: [BubbleOp]

    var description: String {
        "hour \(startHour) seed \(seed) windows \(windows.map { "(\($0.x),\($0.y),\($0.w))" }) ops \(ops)"
    }
}

fileprivate extension Gen where Value == BubbleScenario {
    static var bubbleScenario: Generator<BubbleScenario, some SendableSequenceType> {
        let window = zip(Gen<Int>.int(in: 0...25), Gen<Int>.int(in: 4...14), Gen<Int>.int(in: 4...10))
            .map { BubbleWindowSpec(x: $0 * 40, y: $1 * 40, w: $2 * 40) }
        let op = zip(
            Gen<Int>.int(in: 0...(BubbleOp.names.count - 1)), Gen<Int>.int(in: 0...9),
            Gen<Int>.int(in: -10...10), Gen<Int>.int(in: -10...10), Gen<Int>.int(in: 1...45)
        ).map { BubbleOp(kind: $0, index: $1, a: $2, b: $3, frames: $4) }
        return zip(
            window.array(of: 1...4), Gen<Int>.int(in: 0...23), Gen<Int>.int(in: 0...1_000_000), op.array(of: 1...12)
        ).map { BubbleScenario(windows: $0, startHour: $1, seed: $2, ops: $3) }
    }
}

struct WishBubbleTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let dt = 1.0 / 30

    /// 缩短检查间隔、冷却、超时、累的距离和追逐时长，让各类 Wish 在短模拟内自然生成、等待、完成和放弃。
    static let constants: Tunables = {
        var c = Tunables()
        c.wishCheckInterval = 1
        c.wishCooldown = 1
        c.wishTimeout = 12
        c.wishSpawnChance = 0.6
        c.tiredWalkDistance = 60
        c.chaseReadyDuration = 0.5
        c.chaseDuration = 4
        c.activityMinDuration = 0.5
        c.activityMaxDuration = 2
        c.sitDuration = 1.5
        c.walkSpeed = 120
        return c
    }()

    fileprivate final class Sim {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now: Date
        var windows: [WindowSnapshot]
        var nextDecor: UInt64 = 1
        var last: StepOutput?

        init(_ s: BubbleScenario) {
            now = Date(timeIntervalSince1970: 23 * 86400 + Double(s.startHour) * 3600)
            windows = s.windows.enumerated().map { i, w in
                StoryEngineTests.win(WindowID(i + 1), x: Double(w.x), y: Double(w.y), w: Double(w.w), h: 160)
            }
            engine = WorldEngine(constants: WishBubbleTests.constants, clockStart: now, screen: WishBubbleTests.screen,
                                 rng: RandomSource(seed: UInt64(s.seed)), demoResident: false,
                                 story: true, activities: true)
            source = FakeWindowSource(snapshots: windows)
        }

        @discardableResult
        func step(_ commands: [Command] = [], pointer: [PointerEvent] = []) -> StepOutput {
            now = now.addingTimeInterval(WishBubbleTests.dt)
            let out = engine.step(FrameInput(poll: source.poll(), screen: WishBubbleTests.screen,
                                             pointer: pointer, commands: commands, now: now,
                                             timeZone: WishBubbleTests.utc))
            last = out
            return out
        }
    }

    /// 每次 step 结束时检查 Property 17（跳过显示「?」的居民）。
    fileprivate static func check(_ sim: Sim, _ out: StepOutput) -> [String] {
        var out17: [String] = []
        let active = sim.engine.state.wishes.active
        for rv in out.view.residents {
            if let p = rv.poke, p.bubbleRemaining > 0 { continue }
            let id = rv.id
            let tag = "\(id) state=\(rv.state) bubble=\(String(describing: rv.bubble))"
            if rv.state == .sleeping, rv.bubble != .zzz { out17.append("sleeping without Zzz: \(tag)") }

            var expected: WishIcon?
            var hasWish = false
            for w in active where w.participants.contains(id) && w.type != .flower {
                hasWish = true
                guard w.wisher == id else { continue }
                switch w.type {
                case .chair: expected = .chair
                case .lamp: expected = .lamp
                case .chase: expected = .footprints
                case .visit:
                    if case let .wishIcon(.flag(arrow))? = rv.bubble { expected = .flag(arrow: arrow) }
                    else { expected = .flag(arrow: .right) }
                case .flower: break
                }
            }
            if let expected {
                if rv.bubble != .wishIcon(expected) { out17.append("wisher bubble \(tag), expected \(expected)") }
            } else if case .wishIcon? = rv.bubble {
                out17.append("non-wisher shows Wish_Bubble (participant=\(hasWish)): \(tag)")
            }
        }
        return out17
    }

    fileprivate static func run(_ op: BubbleOp, _ sim: Sim, violations: inout [String]) {
        var commands: [Command] = []
        var pointer: [PointerEvent] = []
        let rid: ResidentID = op.index % 2 == 0 ? .a : .b
        switch BubbleOp.names[op.kind] {
        case "trigger":
            let types = WishType.allCases
            commands = [.triggerWish(types[abs(op.a) % types.count], rid)]
        case "night": commands = [.setDayNight(.night)]
        case "day": commands = [.setDayNight(.day)]
        case "move":
            guard !sim.windows.isEmpty else { break }
            let i = op.index % sim.windows.count
            let f = sim.windows[i].frame
            let origin = Point(x: min(max(f.minX + Double(op.a) * 20, 0), 1200),
                               y: min(max(f.minY + Double(op.b) * 20, 120), 640))
            sim.source.move(sim.windows[i].id, to: origin)
            sim.windows[i].frame = Rect(minX: origin.x, minY: origin.y, width: f.width, height: f.height)
        case "hide":
            guard !sim.windows.isEmpty else { break }
            sim.source.hide(sim.windows[op.index % sim.windows.count].id)
        case "show":
            for w in sim.windows { sim.source.show(w.id) }
        case "close":
            guard sim.windows.count > 1 else { break }
            let i = op.index % sim.windows.count
            sim.source.close(sim.windows[i].id)
            sim.windows.remove(at: i)
        case "decor":
            // 在某位居民所在窗口（或 Ground）上放一件 Chair 或 Lamp。
            let r = sim.engine.state.residents[rid]
            let attachment: CoreAttachment
            if case let .window(wid, _)? = r?.attachment, let w = sim.windows.first(where: { $0.id == wid }) {
                attachment = .window(wid, offset: w.frame.width * Double(abs(op.b) % 11) / 10)
            } else {
                attachment = .ground(x: 100 + Double(abs(op.b)) * 100)
            }
            sim.engine.insertDecor(Decor(id: DecorID(sim.nextDecor), type: op.a % 2 == 0 ? .chair : .lamp,
                                         placement: .attached(attachment)))
            sim.nextDecor += 1
        case "poke":
            if let p = sim.last?.view.residents.first(where: { $0.id == rid })?.position {
                let q = Point(x: p.x, y: p.y - 10)
                pointer = [.down(q), .up(q)]
            }
        default: break
        }
        for f in 0 ..< op.frames {
            let out = sim.step(f == 0 ? commands : [], pointer: f == 0 ? pointer : [])
            violations += check(sim, out)
            if !violations.isEmpty { return }
        }
    }

    // Feature: V2, Property 17: 气泡与状态一致
    // **Validates: Requirements 5.6, 6.9, 6.13, 20.3**
    @Test func bubblesMatchState() async {
        await propertyCheck(count: 100, input: Gen.bubbleScenario) { s in
            let sim = Sim(s)
            var violations = Self.check(sim, sim.step())
            for op in s.ops where violations.isEmpty {
                Self.run(op, sim, violations: &violations)
            }
            #expect(violations.isEmpty, "\(violations.prefix(3)) in \(s)")
        }
    }
}
