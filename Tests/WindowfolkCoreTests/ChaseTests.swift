import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 追逐属性测试（任务 8.5 起）。
// - Property 55：追逐 ready 阶段的朝向（Requirement 20.3、20.8）。
//
// 世界：屏幕 1440×900，窗口 1（x 100 → 300）与窗口 2（x 300 → 500）首尾相接、上沿 y 400，另有 Ground。
// 完整 V2 WorldEngine（剧情与自主活动启用），时区固定为 UTC，起始时刻 UTC 08:00（不是 Night）。

// MARK: - 生成器

/// 居民的放置：`kind` 0 为窗口 1、1 为窗口 2（`frac` 为窗沿上的比例），2 为 Ground（`frac` 换算成屏幕 x）。
fileprivate struct ChaseSpot: Sendable, CustomStringConvertible {
    var kind: Int
    var frac: Double

    var attachment: CoreAttachment {
        switch kind {
        case 0: .window(1, offset: 200 * frac)
        case 1: .window(2, offset: 200 * frac)
        default: .ground(x: 20 + 1400 * frac)
        }
    }

    /// 放置处的屏幕 x。
    var screenX: Double {
        switch kind {
        case 0: 100 + 200 * frac
        case 1: 300 + 200 * frac
        default: 20 + 1400 * frac
        }
    }

    var description: String { "\(attachment)" }
}

fileprivate struct ChaseReadyCase: Sendable, CustomStringConvertible {
    var spotA: ChaseSpot
    var spotB: ChaseSpot
    var facingA: Facing
    var facingB: Facing
    var wisher: ResidentID
    /// ready 期间开始下落的居民（nil 表示没有人下落）。
    var faller: ResidentID?
    /// 触发后第几帧结束时让 `faller` 从原地上方开始下落。
    var fallFrame: Int
    /// 下落起点在原位置上方的高度（pt）。
    var drop: Double
    /// 下落开始时 `faller` 的朝向（任意朝向，验证落地那一帧面朝对方）。
    var fallFacing: Facing

    var description: String {
        "A \(spotA) \(facingA), B \(spotB) \(facingB), wisher \(wisher), "
            + "faller \(faller.map { "\($0)" } ?? "-") @\(fallFrame) drop \(drop) \(fallFacing)"
    }
}

fileprivate extension Gen where Value == ChaseSpot {
    static var spot: Generator<ChaseSpot, some SendableSequenceType> {
        zip(Gen<Int>.int(in: 0...2), Gen<Double>.double(in: 0...1)).map { ChaseSpot(kind: $0, frac: $1) }
    }
}

fileprivate extension Gen where Value == ChaseReadyCase {
    static var readyCase: Generator<ChaseReadyCase, some SendableSequenceType> {
        zip(
            Gen<ChaseSpot>.spot,
            Gen<ChaseSpot>.spot,
            Gen<Int>.int(in: 0...4),          // 0：B 与 A 放在同一处（x 相等）
            Gen<Int>.int(in: 0...3),          // 两人的初始朝向（两个比特）
            Gen<Int>.int(in: 0...1),          // Wisher
            Gen<Int>.int(in: 0...2),          // 0：无人下落；1：A；2：B
            Gen<Int>.int(in: 1...8),
            zip(Gen<Double>.double(in: 5...300), Gen<Int>.int(in: 0...1))
        ).map { a, b, same, facings, wisher, fall, frame, f in
            ChaseReadyCase(
                spotA: a, spotB: same == 0 ? a : b,
                facingA: facings & 1 == 0 ? .left : .right,
                facingB: facings & 2 == 0 ? .left : .right,
                wisher: wisher == 0 ? .a : .b,
                faller: fall == 0 ? nil : (fall == 1 ? .a : .b),
                fallFrame: frame, drop: f.0, fallFacing: f.1 == 0 ? .left : .right)
        }
    }
}

// MARK: - 属性测试

@Suite struct ChasePropertyTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    /// UTC 08:00，不是 Night。
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let windows = StoryEngineTests.touching
    /// 每帧 0.2 秒（不超过 WorldEngine 的单帧上限 0.25 秒）：ready 阶段约 10 帧，控制单测耗时。
    static let dt = 0.2

    /// 居民在 Surface 上（不处于 `falling`、`hanging`、`climbing`）。
    static func grounded(_ v: ResidentView) -> Bool {
        v.state != .falling && v.state != .hanging && v.state != .climbing
    }

    // Feature: V2, Property 55: 追逐 ready 阶段的朝向
    // For any 两位居民的位置和朝向，在 Chase_Phase 为 ready 的每次 step 结束时，不处于 falling、hanging、climbing
    // 的居民不水平移动、处于 idle，并在对方 x 较小时朝左、较大时朝右、相等时保持原朝向。ready 期间可能有一人
    // 从原地上方开始下落（朝向任意），落地后同样适用。
    // **Validates: Requirements 20.3, 20.8**
    @Test func readyPhaseHoldsAndFacesOther() async {
        await propertyCheck(count: 100, input: Gen.readyCase) { c in
            var now = Self.t0
            let engine = WorldEngine(clockStart: now, screen: Self.screen, rng: RandomSource(seed: 7))
            var source = FakeWindowSource(snapshots: Self.windows)
            func step(_ commands: [Command] = []) -> StepOutput {
                now = now.addingTimeInterval(Self.dt)
                let out = engine.step(FrameInput(poll: source.poll(), screen: Self.screen,
                                                 commands: commands, now: now, timeZone: Self.utc))
                #expect(engine.invariantViolations().isEmpty, "\(c): \(engine.invariantViolations())")
                return out
            }
            func phase() -> ChasePhase? {
                engine.state.wishes.active.first { $0.type == .chase }?.chase?.phase
            }

            _ = step()   // 开局：分配 Home_Window 并放置居民
            engine.place(Resident(id: .a, attachment: c.spotA.attachment, facing: c.facingA))
            engine.place(Resident(id: .b, attachment: c.spotB.attachment, facing: c.facingB))
            var prevX: [ResidentID: Double] = [.a: c.spotA.screenX, .b: c.spotB.screenX]
            var prevFacing: [ResidentID: Facing] = [.a: c.facingA, .b: c.facingB]
            var prevGrounded: [ResidentID: Bool] = [.a: true, .b: true]

            var out = step([.triggerWish(.chase, c.wisher)])
            #expect(phase() == .ready, "\(c)")
            var frame = 0
            while phase() == .ready, frame < 60 {
                var views: [ResidentID: ResidentView] = [:]
                for v in out.view.residents { views[v.id] = v }
                for id in [ResidentID.a, .b] {
                    guard let me = views[id], let other = views[id.other],
                          let mx = me.position?.x, let ox = other.position?.x else {
                        Issue.record("frame \(frame): 无法定位 \(id)（\(c)）")
                        continue
                    }
                    if Self.grounded(me) {
                        #expect(me.state == .idle, "frame \(frame) \(id) state \(me.state)（\(c)）")
                        if prevGrounded[id] == true {
                            #expect(mx == prevX[id], "frame \(frame) \(id) 水平移动 \(prevX[id]!) → \(mx)（\(c)）")
                        }
                        let expected: Facing = ox < mx ? .left : (ox > mx ? .right : prevFacing[id]!)
                        #expect(me.facing == expected,
                                "frame \(frame) \(id) 朝向 \(me.facing)，应为 \(expected)（自 x \(mx)，对方 x \(ox)，\(c)）")
                    }
                    prevX[id] = mx
                    prevFacing[id] = me.facing
                    prevGrounded[id] = Self.grounded(me)
                }

                frame += 1
                if let f = c.faller, frame == c.fallFrame, var r = engine.state.residents[f],
                   let p = views[f]?.position {
                    // 从原地上方开始下落，朝向任意。
                    let start = Point(x: p.x, y: p.y - c.drop)
                    r.state = .falling
                    r.attachment = .free(start)
                    r.fall = FallState(position: start)
                    r.route = nil
                    r.traversal = nil
                    r.facing = c.fallFacing
                    engine.place(r)
                    prevFacing[f] = c.fallFacing
                    prevGrounded[f] = false
                }
                out = step()
            }
            // 满 Chase_Ready_Duration 离开 ready（进入 running；两人贴在一起时同帧得出 caught，Chase_Wish 结束）。
            #expect(phase() != .ready, "\(c): ready 应在 Chase_Ready_Duration 到时结束")
        }
    }
}

// MARK: - Property 57：追逐中的可达性一致
//
// 世界：屏幕 1440×900（Ground y 825）。窗口 1（x 100 → 400，y 400）与窗口 2（x 520 → 820，y 400）之间隔 120pt，
// 可架一块木板；窗口 3（x 940 → 1240，y 720）离 Ground 105pt：可往下跳到 Ground，从 Ground 上来需要梯子。
// 操作：架设或拆除木板与梯子、把窗口 1 或 2 移到预设位置、隐藏与重新显示窗口、关闭窗口。

/// 一次玩家操作，之后推进 `wait` 帧。
fileprivate struct ChaseOp: Sendable, CustomStringConvertible {
    /// 0 架木板，1 拆木板，2 架梯子，3 拆梯子，4 移动窗口 1，5 移动窗口 2，6 隐藏窗口，7 显示全部，8 关闭窗口。
    var kind: Int
    var arg: Int
    var wait: Int

    var description: String {
        let names = ["plank+", "plank-", "ladder+", "ladder-", "move1", "move2", "hide", "show", "close"]
        return "\(names[kind])(\(arg))×\(wait)"
    }
}

/// 两人在本测试世界中的放置：`kind` 0、1、2 为窗口 1、2、3（`frac` 为窗沿上的比例），3 为 Ground。
fileprivate struct ReachSpot: Sendable, CustomStringConvertible {
    var kind: Int
    var frac: Double

    var attachment: CoreAttachment {
        switch kind {
        case 0, 1, 2: .window(WindowID(kind + 1), offset: 300 * frac)
        default: .ground(x: 20 + 1400 * frac)
        }
    }

    var description: String { "\(attachment)" }
}

fileprivate struct ChaseReachCase: Sendable, CustomStringConvertible {
    var spotA: ReachSpot
    var spotB: ReachSpot
    var wisher: ResidentID
    var ops: [ChaseOp]

    var description: String { "A \(spotA), B \(spotB), wisher \(wisher), ops \(ops)" }
}

fileprivate extension Gen where Value == ChaseReachCase {
    static var reachCase: Generator<ChaseReachCase, some SendableSequenceType> {
        let spot = zip(Gen<Int>.int(in: 0...3), Gen<Double>.double(in: 0...1)).map { ReachSpot(kind: $0, frac: $1) }
        let op = zip(Gen<Int>.int(in: 0...8), Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 1...10))
            .map { ChaseOp(kind: $0, arg: $1, wait: $2) }
        return zip(spot, spot, Gen<Int>.int(in: 0...1), op.array(of: 3...8))
            .map { ChaseReachCase(spotA: $0, spotB: $1, wisher: $2 == 0 ? .a : .b, ops: $3) }
    }
}

extension ChasePropertyTests {
    static let groundY = 825.0
    static func reachWindows() -> [WindowSnapshot] {
        [
            StoryEngineTests.win(1, x: 100, y: 400, w: 300, h: 200),
            StoryEngineTests.win(2, x: 520, y: 400, w: 300, h: 200),
            StoryEngineTests.win(3, x: 940, y: 720, w: 300, h: 150),
        ]
    }
    /// 窗口 1 的预设左上角：原位、抬高 100pt、右移到与窗口 2 相接、移到窗口 3 左侧较高处。
    static let presets1 = [Point(x: 100, y: 400), Point(x: 100, y: 300), Point(x: 220, y: 400), Point(x: 640, y: 640)]
    /// 窗口 2 的预设左上角：原位、左移到与窗口 1 相接、下移、移到与窗口 3 右端相接。
    static let presets2 = [Point(x: 520, y: 400), Point(x: 400, y: 400), Point(x: 520, y: 610), Point(x: 1240, y: 720)]
    /// dt = 1/8 秒：Date 运算精确，Chase_Replan_Interval（0.5 秒）恰为 4 帧。
    static let reachDt = 0.125

    /// 执行一次玩家操作（只改变 Nav_Graph 和窗口）。
    fileprivate static func apply(_ op: ChaseOp, engine: WorldEngine, source: inout FakeWindowSource) {
        let state = engine.state
        let src = source
        let visible = { (id: WindowID) in src.window(id).flatMap { $0.isHidden ? nil : $0.snapshot.frame } }
        let placedPlanks = state.planks.planks.compactMap { id, p -> PlankID? in
            if case .placed = p { return id } else { return nil }
        }
        let placedLadders = state.ladders.ladders.compactMap { id, l -> LadderID? in
            if case .placed = l { return id } else { return nil }
        }
        switch op.kind {
        case 0:
            guard placedPlanks.isEmpty, let f1 = visible(1), visible(2) != nil else { return }
            engine.insertPlank(.placed(PlacedPlank(
                id: PlankID(0), endA: PlankEnd(window: 1, offset: f1.width), endB: PlankEnd(window: 2, offset: 0))))
        case 1:
            for pid in placedPlanks where !state.residents.values.contains(where: {
                if case let .plank(p, _) = $0.attachment { return p == pid } else { return false }
            }) {
                engine.state.planks.planks[pid] = nil
            }
        case 2:
            guard placedLadders.isEmpty, let f3 = visible(3) else { return }
            engine.insertLadder(.placed(PlacedLadder(
                id: LadderID(0), top: PlankEnd(window: 3, offset: 50),
                bottomSurface: .ground, bottom: Point(x: f3.minX + 50, y: groundY))))
        case 3:
            guard !state.residents.values.contains(where: { $0.state == .climbing }) else { return }
            for lid in placedLadders { engine.state.ladders.ladders[lid] = nil }
        case 4:
            source.move(1, to: presets1[op.arg])
        case 5:
            source.move(2, to: presets2[op.arg])
        case 6:
            source.hide(WindowID(op.arg % 3 + 1))
        case 7:
            for id in [WindowID(1), 2, 3] { source.show(id) }
        default:
            if source.count > 2 { source.close(WindowID(op.arg % 3 + 1)) }
        }
    }

    // Feature: V2, Property 57: 追逐中的可达性一致
    // For any Nav_Graph 和由搭拆木板梯子、移动、隐藏、关闭窗口组成的操作序列，在 Chase_Phase 为 running 期间的每次
    // step 结束时：若 Chaser 有路线可达 Runner 所在 Surface，则 Chaser 目标为 reach(Runner)、不处于 waiting、剩余
    // 路线的每条边都在当前 Nav_Graph 中，Runner 有 Flee_Target，距上次重新规划不超过 Chase_Replan_Interval，
    // Nav_Graph 变化或路线恢复（此前没有 Flee_Target）的那一次 step 内重新规划；否则（含任一人在 Hidden_Window 上）
    // Chaser 目标为 wait(face: Runner)、处于 waiting 且面朝 Runner、没有「...」气泡，Runner 目标为
    // hold(face: Chaser)、处于 idle 且面朝 Chaser。可达性只在两人上一帧和这一帧都站在可定位的 Surface 上时判定
    // （下落、悬挂、爬梯、小跳或跳下途中的居民，以及本帧内因窗口关闭等下落并已落到另一 Surface 的居民，plan 时没有
    // 位置，按 Requirement 21.9 落地后再继续）；可见居民的状态与朝向同样只在此时检查。
    // **Validates: Requirements 21.2, 21.3, 21.6**
    @Test func reachabilityConsistentDuringChase() async {
        await propertyCheck(count: 100, input: Gen.reachCase) { c in
            var now = Self.t0
            let engine = WorldEngine(clockStart: now, screen: Self.screen, rng: RandomSource(seed: 7))
            var source = FakeWindowSource(snapshots: Self.reachWindows())
            func step(_ commands: [Command] = []) {
                now = now.addingTimeInterval(Self.reachDt)
                _ = engine.step(FrameInput(poll: source.poll(), screen: Self.screen,
                                           commands: commands, now: now, timeZone: Self.utc))
                #expect(engine.invariantViolations().isEmpty, "\(c): \(engine.invariantViolations())")
            }
            func chase() -> ChaseState? {
                engine.state.wishes.active.first { $0.type == .chase }?.chase
            }

            step()
            engine.place(Resident(id: .a, attachment: c.spotA.attachment))
            engine.place(Resident(id: .b, attachment: c.spotB.attachment))
            step([.triggerWish(.chase, c.wisher)])
            var guardFrames = 0
            while chase()?.phase == .ready, guardFrames < 40 {
                step()
                guardFrames += 1
            }
            guard chase()?.phase == .running else { return }   // 两人贴在一起时进入 running 的同帧得出 caught

            let a = ChaseRules.chaser, b = ChaseRules.runner
            func snapshot() -> WishContext {
                WishContext(world: engine.state, now: now, navVersion: engine.navVersion)
            }
            var prev = snapshot()
            var prevFacing: [ResidentID: Facing] = [:]
            var prevFlee = chase()?.fleeTarget
            var prevNavVersion = engine.navVersion
            for id in [a, b] { prevFacing[id] = engine.state.residents[id]?.facing }
            /// 正在执行小跳或跳下（`traversal` 非空）。这时 `ResidentController.location` 仍给出出发 Surface，
            /// 但居民不站在任何 Surface 上：边要走完才落到 `edge.to`（Requirement 21.9），不能据此判定可达性。
            func inTraversal(_ id: ResidentID) -> Bool { engine.state.residents[id]?.traversal != nil }
            var prevTraversal: [ResidentID: Bool] = [a: inTraversal(a), b: inTraversal(b)]
            /// 上一帧结束时的剩余路线：本帧走过 Surface 接缝时，新 Surface 一定是其中某条边的 `to`。
            var prevRoute: [ResidentID: [NavEdge]] = [:]
            for id in [a, b] { prevRoute[id] = engine.state.residents[id]?.route?.steps ?? [] }

            /// 一次 step 后检查 Property 57。
            func check(_ label: String) {
                guard let ch = chase(), ch.phase == .running,
                      let ra = engine.state.residents[a], let rb = engine.state.residents[b] else { return }
                let cur = snapshot()
                let nav = engine.state.nav
                let hidden = !cur.hiddenResidents.isEmpty
                // 上一帧与这一帧都可定位（可见、站在 Surface 上且不在小跳或跳下途中），并且这一帧所在 Surface
                // 与上一帧相同或沿自己路线上的 walk / plank 边（无需 traversal 的接缝）走到：plan 时的位置与
                // 这一帧的可达性一致。窗口关闭、木板失效等使居民在本帧内开始下落并落到另一 Surface 时，plan 那一刻
                // 居民正在下落、没有位置，按 Requirement 21.9 落地后再继续，这一帧不判定。
                let stable = { (id: ResidentID) -> Bool in
                    guard let p = prev.locations[id], let q = cur.locations[id],
                          prevTraversal[id] != true, !inTraversal(id) else { return false }
                    return p.surface == q.surface || (prevRoute[id] ?? []).contains {
                        $0.from == p.surface && $0.to == q.surface && ($0.kind == .walk || $0.kind == .plank)
                    }
                }
                let ctx = "\(label)（\(c)）"
                if hidden {
                    #expect(ra.goal == .wait(face: .resident(b)), "Chaser goal \(ra.goal) \(ctx)")
                    #expect(rb.goal == .hold(face: .resident(a)), "Runner goal \(rb.goal) \(ctx)")
                    if !cur.hiddenResidents.contains(a), stable(a) {
                        #expect(ra.state == .waiting, "Chaser state \(ra.state) \(ctx)")
                        #expect(ra.bubble != .dots, "Chaser 显示「...」\(ctx)")
                    }
                    if !cur.hiddenResidents.contains(b), stable(b) {
                        #expect(rb.state == .idle, "Runner state \(rb.state) \(ctx)")
                    }
                    return
                }
                guard stable(a), stable(b), let la = cur.locations[a], let lb = cur.locations[b] else { return }
                if nav.isReachable(from: la.surface, to: lb.surface) {
                    #expect(ra.goal == .reach(b), "Chaser goal \(ra.goal) \(ctx)")
                    #expect(ra.state != .waiting, "Chaser 可达时不应 waiting \(ctx)")
                    for e in ra.route?.steps ?? [] {
                        #expect(nav.contains(e), "Chaser 路线的边 \(e) 不在 Nav_Graph 中 \(ctx)")
                    }
                    #expect(ch.fleeTarget != nil, "Runner 没有 Flee_Target \(ctx)")
                    if let t = ch.lastReplanAt {
                        let gap = now.timeIntervalSince(t)
                        #expect(gap >= 0 && gap <= engine.constants.chaseReplanInterval,
                                "距上次重新规划 \(gap) 秒 \(ctx)")
                        if engine.navVersion != prevNavVersion || prevFlee == nil {
                            #expect(t == now, "Nav_Graph 变化或路线恢复后本次 step 未重新规划 \(ctx)")
                            #expect(ch.lastNavVersion == engine.navVersion, "\(ctx)")
                        }
                    } else {
                        Issue.record("可达时从未重新规划 \(ctx)")
                    }
                } else {
                    #expect(ra.goal == .wait(face: .resident(b)), "Chaser goal \(ra.goal) \(ctx)")
                    #expect(rb.goal == .hold(face: .resident(a)), "Runner goal \(rb.goal) \(ctx)")
                    #expect(ra.state == .waiting, "Chaser state \(ra.state) \(ctx)")
                    #expect(ra.bubble != .dots, "Chaser 显示「...」\(ctx)")
                    #expect(rb.state == .idle, "Runner state \(rb.state) \(ctx)")
                    let faceA: Facing = lb.x < la.x ? .left : (lb.x > la.x ? .right : prevFacing[a]!)
                    let faceB: Facing = la.x < lb.x ? .left : (la.x > lb.x ? .right : prevFacing[b]!)
                    #expect(ra.facing == faceA, "Chaser 朝向 \(ra.facing)，应为 \(faceA) \(ctx)")
                    #expect(rb.facing == faceB, "Runner 朝向 \(rb.facing)，应为 \(faceB) \(ctx)")
                }
            }

            func advance(_ label: String) {
                step()
                check(label)
                prev = snapshot()
                prevFlee = chase()?.fleeTarget
                prevNavVersion = engine.navVersion
                for id in [a, b] {
                    prevFacing[id] = engine.state.residents[id]?.facing
                    prevTraversal[id] = inTraversal(id)
                    prevRoute[id] = engine.state.residents[id]?.route?.steps ?? []
                }
            }

            advance("running 第 1 帧")
            for (i, op) in c.ops.enumerated() {
                guard chase() != nil else { return }
                Self.apply(op, engine: engine, source: &source)
                for f in 0 ..< op.wait {
                    guard chase() != nil else { return }
                    advance("op \(i) \(op) 后第 \(f) 帧")
                }
            }
            for f in 0 ..< 8 {
                guard chase() != nil else { return }
                advance("收尾第 \(f) 帧")
            }
        }
    }
}
