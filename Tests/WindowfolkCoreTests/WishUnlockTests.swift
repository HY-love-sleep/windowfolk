import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 任务 7.13：Property 1（Unlocked_Decor 单调且每种只记一次）。
// 通过 WorldEngine 驱动随机操作序列，每次 step 结束时检查 Unlocked_Decor 与 `decor_unlocked` 记录。
// 「重置世界」单独处理：该 step 结束时集合只含该 step 内新写记录的类型，之后从零重新计数。

// MARK: - 生成器

/// 一个操作。`kind` 见 `UnlockOp.Kind`；`wisherB` 选择 Wisher；`arg` 为帧数、Decor 下标或类型等参数。
fileprivate struct UnlockOp: Sendable, CustomStringConvertible {
    enum Kind: Int, CaseIterable, Sendable {
        /// 触发 Chair_Wish / Lamp_Wish（Debug「触发心愿」）。
        case triggerChair, triggerLamp
        /// Debug「解锁全部物件」。
        case unlockAll
        /// 时钟一次推进超过 Wish_Timeout，使 active 的 Chair_Wish、Lamp_Wish 超时放弃。
        case timeout
        /// 在某个 active Chair_Wish / Lamp_Wish 的 Wisher 脚下放一件对应 Decor，使其完成；没有时在 Ground 上随机放一件。
        case placeNear
        /// 把场上一件 Decor 拖回 Toolbox 收回。
        case returnToToolbox
        /// 放 Decor 直到达到 Max_Decor_Count。
        case fill
        /// 普通推进若干帧（期间可能按概率自然生成 Wish）。
        case frames
        /// 切换昼夜覆盖（夜晚、白天、自动）。
        case dayNight
        /// Debug「重置世界」。
        case resetWorld
    }

    var kind: Kind
    var wisherB: Bool
    var arg: Int

    var description: String { "\(kind)(\(wisherB ? "b" : "a"), \(arg))" }
}

fileprivate struct UnlockScenario: Sendable, CustomStringConvertible {
    var seed: UInt64
    var ops: [UnlockOp]
    var description: String { "seed=\(seed) ops=\(ops)" }
}

fileprivate extension Gen where Value == UnlockScenario {
    static var op: Generator<UnlockOp, some SendableSequenceType> {
        // 下标 0–13：triggerChair、triggerLamp 和 placeNear 出现得更频繁，resetWorld 较少。
        let kinds: [UnlockOp.Kind] = [
            .triggerChair, .triggerChair, .triggerLamp, .triggerLamp, .unlockAll, .timeout,
            .placeNear, .placeNear, .returnToToolbox, .fill, .frames, .frames, .dayNight, .resetWorld,
        ]
        return zip(Gen<Int>.int(in: 0...(kinds.count - 1)), Gen<Bool>.bool, Gen<Int>.int(in: 0...30))
            .map { UnlockOp(kind: kinds[$0], wisherB: $1, arg: $2) }
    }

    static var scenario: Generator<UnlockScenario, some SendableSequenceType> {
        zip(Gen<UInt64>.uint64(), op.array(of: 1...14)).map { UnlockScenario(seed: $0, ops: $1) }
    }
}

// MARK: - 测试

struct WishUnlockTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    /// UTC 08:00，不是 Night。
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let windows = WishEngineUnitTests.windows

    /// 驱动 WorldEngine 并在每次 step 结束时检查 Property 1。
    fileprivate final class Sim {
        let engine: WorldEngine
        var source = FakeWindowSource(snapshots: WishUnlockTests.windows)
        var now = WishUnlockTests.t0
        /// 上一次 step 结束时的 Unlocked_Decor。
        var previous: Set<DecorType> = []
        /// 自开局（或最近一次「重置世界」）以来每种 Decor_Type 的 `decor_unlocked` 记录数。
        var counts: [DecorType: Int] = [:]
        var violations: [String] = []
        /// 测试直接放入的 Decor 的下一个 ID（与 Toolbox 新建的 ID 错开）。
        var nextDecorID: UInt64 = 10_000

        init(seed: UInt64) {
            engine = WorldEngine(clockStart: now, screen: WishUnlockTests.screen, rng: RandomSource(seed: seed),
                                 demoResident: false, story: true)
        }

        var unlocked: Set<DecorType> { engine.state.decors.unlocked }

        @discardableResult
        func step(_ commands: [Command] = [], pointer: [PointerEvent] = [], advance: TimeInterval = 1.0 / 30,
                  label: String) -> StepOutput {
            now = now.addingTimeInterval(advance)
            let out = engine.step(FrameInput(poll: source.poll(), screen: WishUnlockTests.screen, pointer: pointer,
                                             commands: commands, now: now, timeZone: WishUnlockTests.utc))
            check(out, commands: commands, label: label)
            return out
        }

        func check(_ out: StepOutput, commands: [Command], label: String) {
            let cur = unlocked
            let isReset = commands.contains(.resetWorld)
            let unlockEvents = out.events.filter { $0.type == .decorUnlocked }
            var stepTypes: [DecorType] = []
            for e in unlockEvents {
                guard let raw = e.detail["decor_type"], let t = DecorType(rawValue: raw) else {
                    violations.append("\(label): decor_unlocked detail \(e.detail)")
                    continue
                }
                if e.actor != nil || e.target != nil {
                    violations.append("\(label): decor_unlocked actor/target \(String(describing: e.actor))/\(String(describing: e.target))")
                }
                stepTypes.append(t)
            }

            if isReset {
                // 「重置世界」：集合清空；同一 step 内（重置之后）新解锁的类型才可能在集合中。
                if !cur.isSubset(of: Set(stepTypes)) {
                    violations.append("\(label): after reset unlocked=\(cur) events=\(stepTypes)")
                }
                counts = [:]
            } else {
                // 单调：包含上一次 step 结束时的全部取值（Requirement 1.5）。
                if !previous.isSubset(of: cur) {
                    violations.append("\(label): unlocked shrank \(previous) -> \(cur)")
                }
                // 记录与解锁时刻一致：本 step 的 decor_unlocked 恰好是本 step 新加入的类型（Requirement 1.4）。
                if Set(stepTypes) != cur.subtracting(previous) || stepTypes.count != Set(stepTypes).count {
                    violations.append("\(label): events=\(stepTypes) but new=\(cur.subtracting(previous))")
                }
            }
            for t in stepTypes { counts[t, default: 0] += 1 }
            // 每种 Decor_Type 的记录数等于 1（在集合中）或 0（不在）。
            for t in DecorType.allCases where counts[t, default: 0] != (cur.contains(t) ? 1 : 0) {
                violations.append("\(label): \(t) count=\(counts[t, default: 0]) inSet=\(cur.contains(t))")
            }

            // Chair_Wish / Lamp_Wish 开始的那次 step 结束时对应类型已在集合中（Requirement 1.2、1.3），
            // 且 wish_started 在由它引起的 decor_unlocked 之前（Requirement 18.2）。同一 step 内同类型的多个
            // wish_started（两位居民同帧生成同类 Wish）只引起一次解锁，因此与该类型第一条 wish_started 比较。
            var checkedOrder: Set<String> = []
            for (i, e) in out.events.enumerated() where e.type == .wishStarted {
                guard let wt = e.detail["wish_type"], let t = DecorType(rawValue: wt) else { continue }
                if !cur.contains(t) { violations.append("\(label): \(t) wish started but not unlocked") }
                guard checkedOrder.insert(wt).inserted else { continue }
                if !commands.contains(.unlockAllDecor),
                   let j = out.events.firstIndex(where: { $0.type == .decorUnlocked && $0.detail["decor_type"] == wt }),
                   j < i {
                    violations.append("\(label): decor_unlocked(\(wt)) at \(j) before wish_started at \(i)")
                }
            }

            // 「解锁全部物件」后集合为 {chair, lamp}（Requirement 17.5）。
            if commands.contains(.unlockAllDecor), cur != Set(DecorType.allCases) {
                violations.append("\(label): after unlockAll unlocked=\(cur)")
            }
            previous = cur
        }

        func insert(_ type: DecorType, at a: CoreAttachment) {
            guard engine.state.decors.count < engine.constants.maxDecorCount else { return }
            engine.insertDecor(Decor(id: DecorID(nextDecorID), type: type, placement: .attached(a)))
            nextDecorID += 1
        }

        func run(_ op: UnlockOp) {
            let label = "\(op)"
            let wisher: ResidentID = op.wisherB ? .b : .a
            switch op.kind {
            case .triggerChair:
                step([.triggerWish(.chair, wisher)], label: label)
            case .triggerLamp:
                step([.triggerWish(.lamp, wisher)], label: label)
            case .unlockAll:
                step([.unlockAllDecor], label: label)
            case .timeout:
                step(advance: engine.constants.wishTimeout + 1, label: label)
                step(label: label)
            case .placeNear:
                let wishes = engine.state.wishes.active.filter { $0.type == .chair || $0.type == .lamp }
                if !wishes.isEmpty, let r = engine.state.residents[wishes[op.arg % wishes.count].wisher] {
                    let w = wishes[op.arg % wishes.count]
                    switch r.attachment {
                    case .window, .ground: insert(w.type == .chair ? .chair : .lamp, at: r.attachment)
                    default: break
                    }
                } else {
                    insert(op.wisherB ? .lamp : .chair, at: .ground(x: 100 + Double(op.arg) * 40))
                }
                for _ in 0 ..< 3 { step(label: label) }
            case .returnToToolbox:
                let ids = engine.state.decors.sortedIDs
                guard !ids.isEmpty else { step(label: label); return }
                let out = step(label: label)
                guard let v = out.view.decors.first(where: { $0.id == ids[op.arg % ids.count] }),
                      !v.isFalling, !v.isDragged,
                      let type = engine.state.decors.decors[v.id]?.type else { return }
                let c = SpriteMetrics.decorRect(type: type, bottomCenter: v.position).center
                let tb = ToolboxLayout.frame(screen: WishUnlockTests.screen, unlocked: unlocked)
                let drop = Point(x: tb.midX, y: tb.minY - 10)
                step(pointer: [.down(c), .moved(drop), .up(drop)], label: label)
            case .fill:
                var k = 0
                while engine.state.decors.count < engine.constants.maxDecorCount {
                    insert(k % 2 == 0 ? .chair : .lamp, at: .ground(x: 40 + Double(k) * 60))
                    k += 1
                }
                step(label: label)
            case .frames:
                for _ in 0 ... op.arg { step(label: label) }
            case .dayNight:
                let o: [DayNightOverride] = [.night, .day, .auto]
                step([.setDayNight(o[op.arg % o.count])], label: label)
            case .resetWorld:
                step([.resetWorld], label: label)
            }
        }
    }

    // Feature: V2, Property 1: Unlocked_Decor 单调且每种只记一次
    // **Validates: Requirements 1.2, 1.3, 1.4, 1.5, 17.5**
    @Test func unlockedDecorIsMonotonicAndRecordedOnce() async {
        await propertyCheck(count: 100, input: Gen<UnlockScenario>.scenario) { s in
            let sim = Sim(seed: s.seed)
            sim.step(label: "start")
            for op in s.ops where sim.violations.isEmpty {
                sim.run(op)
            }
            #expect(sim.violations.isEmpty, "\(sim.violations.prefix(3))")
        }
    }
}
