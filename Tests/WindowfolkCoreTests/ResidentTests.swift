import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 居民寻路相关的属性测试（design.md「测试文件组织」：Property 23 至 26）。
struct ResidentTests {
    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))
    static let dt = 1.0 / 30

    // MARK: - 生成器

    /// 一个窗口的生成参数（以 8pt 网格为单位）。窗口大致从左到右排开，上沿高度相近，
    /// 让小跳、往下跳、木板和 Ground 的可达性在操作中频繁变化。
    struct WindowSpec: Sendable {
        var jitterX: Int
        var y: Int
        var w: Int
        var h: Int
    }

    /// 一个世界操作，后接若干帧推进。
    struct WorldOp: Sendable, CustomStringConvertible {
        var kind: Int
        var index: Int
        var a: Int
        var b: Int
        var frames: Int

        var description: String {
            let name = ["move", "move", "move", "move", "resize", "hide", "show", "close", "front", "wait"][kind]
            return "\(name)(w\(index), \(a), \(b)) + \(frames)f"
        }
    }

    static var windowSpecs: Generator<[WindowSpec], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: -6...6),
            Gen<Int>.int(in: 62...68),     // 上沿 y 496 到 544pt（Ground 在 825pt）
            Gen<Int>.int(in: 30...38),     // 宽 240 到 304pt
            Gen<Int>.int(in: 15...22)      // 高 120 到 176pt
        ).map { WindowSpec(jitterX: $0, y: $1, w: $2, h: $3) }
            .array(of: 2...5)
    }

    /// `Gen.worldOps`：窗口移动、缩放、换层级、关闭、隐藏、显示与时间推进。
    static var worldOps: Generator<[WorldOp], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...9),
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: -12...12),
            Gen<Int>.int(in: -12...12),
            Gen<Int>.int(in: 1...30)
        ).map { WorldOp(kind: $0, index: $1, a: $2, b: $3, frames: $4) }
            .array(of: 1...20)
    }

    static func makeWindows(_ specs: [WindowSpec]) -> [WindowSnapshot] {
        specs.enumerated().map { i, s in
            let id = WindowID(i + 1)
            let frame = Rect(
                minX: Double(i) * 280 + 20 + Double(s.jitterX) * 8, minY: Double(s.y) * 8,
                width: Double(s.w) * 8, height: Double(s.h) * 8)
            return WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: Int32(100 + i), frame: frame, zIndex: i)
        }
    }

    /// 对假窗口源执行一个操作。关闭只在 |a| 较大时发生，避免窗口过早全部消失。
    static func apply(_ op: WorldOp, to source: inout FakeWindowSource, ids: [WindowID]) {
        let id = ids[op.index % ids.count]
        guard let w = source.window(id) else { return }
        let f = w.snapshot.frame
        switch op.kind {
        case 0...3:
            source.move(id, to: Point(x: f.minX + Double(op.a) * 8, y: min(max(f.minY + Double(op.b) * 4, 40), 760)))
        case 4:
            source.resize(id, to: (max(120, f.width + Double(op.a) * 8), f.height))
        case 5:
            source.hide(id)
        case 6:
            source.show(id)
        case 7:
            if abs(op.a) >= 10 { source.close(id) } else { source.show(id) }
        case 8:
            source.bringToFront(id)
        default:
            break
        }
    }

    // MARK: - 检查

    static func context(_ engine: WorldEngine) -> WorldContext {
        WorldContext(
            windows: engine.state.windows, surfaces: engine.state.surfaces, screen: engine.state.screen,
            constants: engine.constants, nav: engine.state.nav)
    }

    /// 一次 step 结束时检查 Property 23。返回违规描述，满足时为 nil。
    ///
    /// - `before`：step 之前的 A。上一帧还在下落、悬挂或执行动作的居民，本帧是落地或动作完成的过渡帧，
    ///   由 Requirement 12.9、14.7、20.2 的「下一帧重新规划」覆盖，不做路线检查（Property 23 中的
    ///   「正在完成一个已开始的动作」）。
    /// - `bBefore`：step 之前的 B。B 本帧落地时，A 追踪的是本帧开始时的位置，不检查终点一致。
    static func violation(engine: WorldEngine, before: Resident, bBefore: Resident) -> String? {
        guard let a = engine.state.residents[.a], let b = engine.state.residents[.b] else { return "resident missing" }
        let nav = engine.state.nav

        // 本帧开始的动作必须走当前图中的边。
        if let t = a.traversal, before.traversal?.edge != t.edge || before.traversal == nil,
           let edge = t.edge, !nav.contains(edge) {
            return "started traversal on edge not in graph: \(edge)"
        }

        if a.state == .falling || a.state == .hanging { return nil }
        if a.traversal != nil { return nil }
        if before.state == .falling || before.state == .hanging || before.traversal != nil { return nil }
        guard bBefore.state != .falling, bBefore.state != .hanging else { return nil }

        let ctx = context(engine)
        // A 或 B 无法定位（所在窗口隐藏，或 B 正在下落、悬挂）时 A 暂停或沿原路线继续，不检查。
        guard let aLoc = ResidentController.location(of: a, world: ctx),
              let bLoc = ResidentController.location(of: b, world: ctx) else { return nil }

        let reachable = nav.isReachable(from: aLoc.surface, to: bLoc.surface)
        if a.state == .waiting {
            if reachable { return "waiting although target reachable: A \(aLoc) B \(bLoc)" }
            if a.route != nil { return "waiting with a route" }
            return nil
        }
        if let route = a.route {
            for e in route.steps where !nav.contains(e) { return "route step not in graph: \(e)" }
            if route.targetSurface != bLoc.surface {
                return "route ends at \(route.targetSurface), target is on \(bLoc.surface)"
            }
            if !nav.isValid(route, from: aLoc.surface) { return "route invalid from \(aLoc.surface): \(route)" }
            return nil
        }
        // 到达目标后停下并清除路线（Requirement 12.8）：与目标在同一条 Surface 上、处于 idle。
        if a.state == .idle, aLoc.surface == bLoc.surface { return nil }
        return "no route, not waiting: state \(a.state) A \(aLoc) B \(bLoc) reachable \(reachable)"
    }

    // Feature: v1, Property 23: 居民只走当前有效路线
    // **Validates: Requirements 6.10, 12.1, 12.9, 12.10, 12.11, 14.8, 16.6, 18.4, 18.5, 20.4**
    @Test func residentOnlyFollowsCurrentValidRoute() async {
        await propertyCheck(
            count: 100,
            input: Self.windowSpecs,
            Gen<Int>.int(in: 0...255),       // 木板掩码：相邻窗口之间约 3/4 的概率架木板
            Gen<Double>.double(in: 0.1...0.9),
            Gen<Double>.double(in: 0.1...0.9),
            Gen<Int>.int(in: 0...1_000_000),
            Self.worldOps
        ) { specs, plankMask, fracA, fracB, seed, ops in
            let windows = Self.makeWindows(specs)
            let ids = windows.map(\.id)
            var now = Date(timeIntervalSince1970: 3_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: UInt64(seed)), demoResident: false)
            var source = FakeWindowSource(snapshots: windows)

            for i in 0 ..< max(windows.count - 1, 0) where (plankMask | (plankMask >> 4)) & (1 << i) != 0 {
                engine.insertPlank(.placed(PlacedPlank(
                    id: PlankID(0),
                    endA: PlankEnd(window: windows[i].id, offset: windows[i].frame.width),
                    endB: PlankEnd(window: windows[i + 1].id, offset: 0))))
            }
            let first = windows[0], last = windows[windows.count - 1]
            engine.place(Resident(
                id: .a, attachment: .window(first.id, offset: first.frame.width * fracA), goal: .reach(.b)))
            engine.place(Resident(
                id: .b, attachment: .window(last.id, offset: last.frame.width * fracB), facing: .left))

            func step(_ label: String) -> Bool {
                let before = engine.state.residents[.a]!
                let bBefore = engine.state.residents[.b]!
                now = now.addingTimeInterval(Self.dt)
                engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: now))
                if let v = Self.violation(engine: engine, before: before, bBefore: bBefore) {
                    Issue.record("\(label): \(v)")
                    return false
                }
                return true
            }

            guard step("initial") else { return }
            for (n, op) in ops.enumerated() {
                Self.apply(op, to: &source, ids: ids)
                for f in 0 ..< op.frames {
                    guard step("op \(n) \(op) frame \(f)") else { return }
                }
            }
        }
    }
}

/// Property 24：没有目标（`Goal.none`）或剧情限定（`Goal.confined`）的居民只在当前 Surface 上闲逛。
///
/// 窗口分布在互不重叠的竖条「车道」里，移动和缩放都不越出车道，因此窗沿不会被遮挡，
/// 每个窗口始终恰好有一条 Window_Ledge，居民所在 Surface 的身份不变（属性的前提）。
/// 窗口上沿离 Ground 较近时会产生往下跳边，用来确认居民不会使用通路边。
struct ResidentConfinementTests {
    static let screen = ResidentTests.screen
    static let dt = ResidentTests.dt
    static let laneWidth = 480.0

    struct LaneWindow: Sendable {
        var x: Int      // 车道内左边缘偏移，8pt 单位
        var y: Int      // 上沿，8pt 单位
        var w: Int      // 宽，8pt 单位
    }

    struct MoveOp: Sendable, CustomStringConvertible {
        var index: Int
        var dx: Int
        var dy: Int
        var dw: Int
        var frames: Int
        var description: String { "move(w\(index), dx \(dx), dy \(dy), dw \(dw)) + \(frames)f" }
    }

    static var laneWindows: Generator<[LaneWindow], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...20),
            Gen<Int>.int(in: 10...97),     // 上沿 80 到 776pt（Ground 825pt，较低时有往下跳边）
            Gen<Int>.int(in: 15...40)      // 宽 120 到 320pt
        ).map { LaneWindow(x: $0, y: $1, w: $2) }
            .array(of: 1...3)
    }

    static var moveOps: Generator<[MoveOp], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...2),
            Gen<Int>.int(in: -10...10),
            Gen<Int>.int(in: -10...10),
            Gen<Int>.int(in: -6...6),
            Gen<Int>.int(in: 1...30)
        ).map { MoveOp(index: $0, dx: $1, dy: $2, dw: $3, frames: $4) }
            .array(of: 1...15)
    }

    /// 把窗口矩形限制在第 `lane` 条车道内。
    static func clampToLane(_ f: Rect, lane: Int) -> Rect {
        let lo = Double(lane) * laneWidth
        let w = min(max(f.width, 120), laneWidth - 16)
        let x = min(max(f.minX, lo + 8), lo + laneWidth - 8 - w)
        let y = min(max(f.minY, 40), 780)
        return Rect(minX: x, minY: y, width: w, height: 160)
    }

    static func makeWindows(_ specs: [LaneWindow]) -> [WindowSnapshot] {
        specs.enumerated().map { i, s in
            let raw = Rect(
                minX: Double(i) * laneWidth + 8 + Double(s.x) * 8, minY: Double(s.y) * 8,
                width: Double(s.w) * 8, height: 160)
            let id = WindowID(i + 1)
            return WindowSnapshot(
                id: id, ownerName: "App\(id)", ownerPID: Int32(200 + i), frame: clampToLane(raw, lane: i), zIndex: i)
        }
    }

    /// 检查一位居民：仍在初始 Surface 上，x 在其范围内，只处于 idle / walking，没有路线和动作。
    static func violation(_ r: Resident, expected: SurfaceID, engine: WorldEngine) -> String? {
        if r.state != .idle && r.state != .walking { return "\(r.id) state \(r.state)" }
        if r.traversal != nil { return "\(r.id) started traversal \(String(describing: r.traversal))" }
        if r.route != nil { return "\(r.id) has route" }
        let ctx = ResidentTests.context(engine)
        guard let (s, p) = ResidentController.currentSurface(of: r, world: ctx) else {
            return "\(r.id) has no surface (attachment \(r.attachment))"
        }
        if s.id != expected { return "\(r.id) moved from \(expected) to \(s.id)" }
        let eps = 1e-6
        if p.x < s.start.x - eps || p.x > s.end.x + eps {
            return "\(r.id) x \(p.x) outside \(s.start.x)...\(s.end.x)"
        }
        return nil
    }

    // Feature: v1, Property 24: 活动限定在当前 Surface
    // **Validates: Requirements 12.13, 16.8, 18.3, 18.9**
    @Test func idleResidentsStayOnTheirSurface() async {
        await propertyCheck(
            count: 100,
            input: Self.laneWindows,
            // 低 2 位：A 所在（窗口序号，取模后等于窗口数时放在 Ground）；再 2 位：B 所在；高 2 位：Goal 组合
            Gen<Int>.int(in: 0...63),
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: 0...1),
            Gen<Int>.int(in: 0...1_000_000),
            Self.moveOps
        ) { specs, code, fracA, fracB, seed, ops in
            let homeA = code & 3, homeB = (code >> 2) & 3, goals = code >> 4
            let windows = Self.makeWindows(specs)
            var now = Date(timeIntervalSince1970: 4_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: UInt64(seed)), demoResident: false)
            var source = FakeWindowSource(snapshots: windows)

            func make(_ id: ResidentID, home: Int, frac: Double, confined: Bool) -> (Resident, SurfaceID) {
                let goal: Goal = confined ? .confined : .none
                let k = home % (windows.count + 1)
                if k < windows.count {
                    let w = windows[k]
                    return (Resident(id: id, attachment: .window(w.id, offset: w.frame.width * frac), goal: goal),
                            .ledge(w.id, index: 0))
                }
                let v = Self.screen.visibleFrame
                return (Resident(id: id, attachment: .ground(x: v.minX + v.width * frac), goal: goal), .ground)
            }
            let (a, surfA) = make(.a, home: homeA, frac: fracA, confined: goals & 1 != 0)
            let (b, surfB) = make(.b, home: homeB, frac: fracB, confined: goals & 2 != 0)
            engine.place(a)
            engine.place(b)

            func step(_ label: String) -> Bool {
                now = now.addingTimeInterval(Self.dt)
                engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: now))
                for (id, expected) in [(ResidentID.a, surfA), (.b, surfB)] {
                    guard let r = engine.state.residents[id] else {
                        Issue.record("\(label): \(id) missing")
                        return false
                    }
                    if let v = Self.violation(r, expected: expected, engine: engine) {
                        Issue.record("\(label): \(v)")
                        return false
                    }
                }
                return true
            }

            for f in 0 ..< 30 { guard step("initial frame \(f)") else { return } }
            for (n, op) in ops.enumerated() {
                let i = op.index % windows.count
                if let w = source.window(windows[i].id) {
                    let f = w.snapshot.frame
                    let moved = Self.clampToLane(
                        Rect(minX: f.minX + Double(op.dx) * 8, minY: f.minY + Double(op.dy) * 8,
                             width: f.width + Double(op.dw) * 8, height: f.height),
                        lane: i)
                    source.resize(windows[i].id, to: (moved.width, moved.height))
                    source.move(windows[i].id, to: Point(x: moved.minX, y: moved.minY))
                }
                for f in 0 ..< op.frames {
                    guard step("op \(n) \(op) frame \(f)") else { return }
                }
            }
        }
    }
}

/// Property 25：已架设的 Plank 或 Ladder 失效时居民的状态转换。
///
/// 场景：窗口 1（x 100…400）和窗口 2 之间架一块木板，和/或从窗口 2 上沿到 Ground 架一架梯子；
/// 窗口 3 在最前方、远离两扇窗口，用于「遮住窗口 2 上沿」的失效操作。窗口 1 从不改动。
/// 两位居民随机放在木板上、梯子上（爬梯中）、窗口 1 窗沿（木板端点所在窗沿）、Ground，
/// 或在只平移窗口 2 的操作下放在窗口 2 窗沿（木板另一端和梯子上端所在窗沿）。
struct SupportFailureTests {
    static let screen = ResidentTests.screen
    static let dt = ResidentTests.dt
    static let groundY = 825.0

    struct Scene: Sendable, CustomStringConvertible {
        var y1: Int          // 窗口 1 上沿
        var gap: Int         // 窗口 1 右边缘到窗口 2 左边缘
        var rise: Int        // 窗口 2 上沿相对窗口 1 的高差
        var ladderOffset: Int
        var mask: Int        // 0：只有木板；1：只有梯子；2：两者都有
        var description: String {
            "y1 \(y1) gap \(gap) rise \(rise) ladderOffset \(ladderOffset) mask \(mask)"
        }
        var hasPlank: Bool { mask != 1 }
        var hasLadder: Bool { mask != 0 }
    }

    /// 失效操作：0 窗口 2 右移（木板超长）；1 窗口 2 上移（木板过陡、梯子超长）；2 关闭窗口 2；3 窗口 3 遮住窗口 2 上沿。
    struct Placement: Sendable, CustomStringConvertible {
        var op: Int
        var kindA: Int       // 0 木板；1 梯子；2 窗口 1 窗沿；3 Ground；4 窗口 2 窗沿
        var kindB: Int
        var fracA: Double
        var fracB: Double
        var amount: Int      // 操作幅度
        var description: String { "op \(op) A \(kindA)@\(fracA) B \(kindB)@\(fracB) amount \(amount)" }
    }

    static var scenes: Generator<Scene, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 660...700),
            Gen<Int>.int(in: 40...150),
            Gen<Int>.int(in: -32...32),
            Gen<Int>.int(in: 20...280),
            Gen<Int>.int(in: 0...2)
        ).map { Scene(y1: $0, gap: $1, rise: $2, ladderOffset: $3, mask: $4) }
    }

    static var placements: Generator<Placement, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...3),
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: 0...4),
            Gen<Double>.double(in: 0.05...0.95),
            Gen<Double>.double(in: 0.05...0.95),
            Gen<Int>.int(in: 0...100)
        ).map { Placement(op: $0, kindA: $1, kindB: $2, fracA: $3, fracB: $4, amount: $5) }
    }

    static func snapshot(_ id: WindowID, _ frame: Rect, z: Int) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: Int32(300 + Int(id)), frame: frame, zIndex: z)
    }

    /// 不会自己闲逛的居民（很长的停顿）。
    static func still(_ id: ResidentID, _ resident: Resident) -> Resident {
        var r = resident
        r.wander = WanderState(pauseRemaining: 10_000)
        return r
    }

    // Feature: v1, Property 25: 支撑失效时的状态转换
    // **Validates: Requirements 10.9, 13.1, 13.2, 13.4, 13.5, 13.6, 13.7**
    @Test func supportFailureTransitions() async {
        await propertyCheck(count: 100, input: Self.scenes, Self.placements) { scene, placement in
            var op = placement.op
            if !scene.hasPlank, op == 0 { op = 1 + placement.amount % 3 }   // 只有梯子时右移不会让它失效

            let y1 = Double(scene.y1), y2 = y1 + Double(scene.rise)
            let w1 = Rect(minX: 100, minY: y1, width: 300, height: 150)
            let w2 = Rect(minX: 400 + Double(scene.gap), minY: y2, width: 300, height: 150)
            let w3 = Rect(minX: 1000, minY: 100, width: 340, height: 200)
            var source = FakeWindowSource(snapshots: [
                Self.snapshot(3, w3, z: 0), Self.snapshot(1, w1, z: 1), Self.snapshot(2, w2, z: 2),
            ])
            var now = Date(timeIntervalSince1970: 5_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: 7), demoResident: false)

            var pid: PlankID?
            var lid: LadderID?
            if scene.hasPlank {
                pid = engine.insertPlank(.placed(PlacedPlank(
                    id: PlankID(0), endA: PlankEnd(window: 1, offset: 300), endB: PlankEnd(window: 2, offset: 0))))
            }
            let ladderX = w2.minX + Double(scene.ladderOffset)
            if scene.hasLadder {
                lid = engine.insertLadder(.placed(PlacedLadder(
                    id: LadderID(0), top: PlankEnd(window: 2, offset: Double(scene.ladderOffset)),
                    bottomSurface: .ground, bottom: Point(x: ladderX, y: Self.groundY))))
            }

            // 解析每位居民的放置方式；不可用的方式退回窗口 1 窗沿。
            let moveOnly = op == 0 || op == 1
            func kind(_ k: Int) -> Int {
                switch k {
                case 0: return pid != nil ? 0 : 2
                case 1: return lid != nil ? 1 : 2
                case 4: return moveOnly ? 4 : 2
                default: return k
                }
            }
            let kinds: [ResidentID: Int] = [.a: kind(placement.kindA), .b: kind(placement.kindB)]
            let fracs: [ResidentID: Double] = [.a: placement.fracA, .b: placement.fracB]

            for id in ResidentID.allCases {
                let f = fracs[id]!
                switch kinds[id]! {
                case 0: engine.place(Self.still(id, Resident(id: id, attachment: .plank(pid!, t: f))))
                case 2: engine.place(Self.still(id, Resident(id: id, attachment: .window(1, offset: 300 * f))))
                case 3: engine.place(Self.still(id, Resident(id: id, attachment: .ground(x: 50 + 1300 * f))))
                case 4: engine.place(Self.still(id, Resident(id: id, attachment: .window(2, offset: 300 * f))))
                default: break   // 爬梯居民在基线帧之后放入
                }
            }

            func step() -> StepOutput {
                now = now.addingTimeInterval(Self.dt)
                return engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: now))
            }

            // 基线帧：木板、梯子都有效。
            let baseline = step()
            guard baseline.failedPlanks.isEmpty, baseline.failedLadders.isEmpty else {
                Issue.record("baseline failed: \(baseline.failedPlanks) \(baseline.failedLadders)")
                return
            }
            let positions = Dictionary(uniqueKeysWithValues: baseline.view.residents.map { ($0.id, $0.position) })

            // 爬梯中的居民：沿梯子向上爬到一定高度。
            if let lid, kinds.values.contains(1) {
                guard let edge = engine.state.nav.allEdges.first(where: { $0.kind == .ladder(lid) && $0.from == .ground })
                else {
                    Issue.record("ladder edge missing")
                    return
                }
                let length = Self.groundY - y2
                let duration = length / engine.constants.climbSpeed
                for id in ResidentID.allCases where kinds[id] == 1 {
                    let f = fracs[id]!
                    engine.place(Resident(
                        id: id, state: .climbing, attachment: .ladder(lid, height: length * f), goal: .reach(id.other),
                        traversal: Traversal(
                            kind: .climb, from: Point(x: ladderX, y: Self.groundY), to: Point(x: ladderX, y: y2),
                            elapsed: duration * f, duration: duration, edge: edge),
                        wander: WanderState(pauseRemaining: 10_000)))
                }
            }
            let before = engine.state.residents

            // 失效操作。
            let amount = Double(placement.amount)
            switch op {
            case 0: source.move(2, to: Point(x: 400 + 170 + amount, y: y2))
            case 1: source.move(2, to: Point(x: w2.minX, y: 560 + amount * 0.5))
            case 2: source.close(2)
            default: source.move(3, to: Point(x: w2.minX - 20, y: y2 - 50))
            }
            let out = step()
            let failedPlank = pid.map { out.failedPlanks.contains($0) } ?? false
            let failedLadder = lid.map { out.failedLadders.contains($0) } ?? false
            if let pid, !failedPlank {
                Issue.record("plank \(pid) did not fail under op \(op)")
                return
            }
            if let lid, op != 0, !failedLadder {
                Issue.record("ladder \(lid) did not fail under op \(op)")
                return
            }

            var hangPoints: [ResidentID: Point] = [:]
            for id in ResidentID.allCases {
                let r = engine.state.residents[id]!
                let old = before[id]!
                switch kinds[id]! {
                case 0:
                    guard r.state == .hanging, case let .free(p) = r.attachment else {
                        Issue.record("\(id) on failed plank: state \(r.state) attachment \(r.attachment)")
                        return
                    }
                    guard let expected = positions[id] ?? nil else {
                        Issue.record("\(id) had no baseline position")
                        return
                    }
                    if abs(p.x - expected.x) > 1e-6 || abs(p.y - expected.y) > 1e-6 {
                        Issue.record("\(id) hangs at \(p), was at \(expected)")
                        return
                    }
                    hangPoints[id] = p
                case 1:
                    if failedLadder, r.state != .falling {
                        Issue.record("\(id) climbing on failed ladder: state \(r.state)")
                        return
                    }
                default:
                    if r.state != old.state || r.attachment != old.attachment {
                        Issue.record("\(id) on ledge/ground changed: \(old.state) \(old.attachment) -> \(r.state) \(r.attachment)")
                        return
                    }
                }
            }

            // 悬挂期间坐标不变，Hang_Duration（±100ms）后进入 falling；每位都从失效那一帧开始计时。
            guard !hangPoints.isEmpty else { return }
            var released: [ResidentID: Int] = [:]
            for frame in 1 ... 120 {
                _ = step()
                for (id, p) in hangPoints where released[id] == nil {
                    let r = engine.state.residents[id]!
                    if r.state == .hanging {
                        if r.attachment != .free(p) {
                            Issue.record("\(id) moved while hanging at frame \(frame): \(r.attachment)")
                            return
                        }
                    } else if r.state == .falling {
                        released[id] = frame
                    } else {
                        Issue.record("\(id) left hanging into \(r.state) at frame \(frame)")
                        return
                    }
                }
                if released.count == hangPoints.count { break }
            }
            for id in hangPoints.keys {
                guard let frames = released[id] else {
                    Issue.record("\(id) still hanging after 4s")
                    return
                }
                let hung = Double(frames) * Self.dt
                if abs(hung - engine.constants.hangDuration) > 0.1 + 1e-9 {
                    Issue.record("\(id) hung \(hung)s")
                    return
                }
            }
        }
    }
}

/// Property 26：搬运不变量。
///
/// 场景沿用 Property 23 的窗口布局与 `Gen.worldOps`（移动、缩放、隐藏、显示、关闭、换层级），
/// 相邻窗口之间随机架木板；都都持有花盆、以嘟嘟为目标，可能一开始就站在木板上（桥塌时悬挂再下落）；
/// 嘟嘟随机持有果子或空手闲逛。Ground 上另放一颗果子供玩家拖动。每个操作之后随机插入一次玩家动作：
/// 戳都都、按住都都手上的花盆拖动、或拖起地上的果子并在拖动中尝试让嘟嘟拿起它。
/// 每次 step 结束时检查持有关系、被持有物件的位置、`carrying` 状态与搬运速度。
struct CarryingInvariantTests {
    static let screen = ResidentTests.screen
    static let dt = ResidentTests.dt

    /// 玩家动作：0 无；1 点击都都；2 拖动都都手上的物件；3 拖起地上的果子并尝试让嘟嘟拿起。
    static var playerActions: Generator<[Int], some SendableSequenceType> {
        Gen<Int>.int(in: 0...3).array(of: 20)
    }

    struct Tracker {
        /// 每位居民在初始化时持有的物件；场景中没有剧情和调试命令，持有关系应始终不变。
        var expectedHeld: [ResidentID: ItemID?]
        var previous: [ResidentID: Resident] = [:]
        var previousWindows: [WindowID: Rect] = [:]
        /// 上一帧的路面；层级变化会改变遮挡、触发夹紧，即使窗口几何不变。
        var previousSurfaces: [Surface] = []
    }

    /// 一次 step 结束时检查 Property 26。返回违规描述，满足时为 nil。
    static func violation(engine: WorldEngine, out: StepOutput, tracker: inout Tracker) -> String? {
        let state = engine.state
        let holding = state.items.holdingViolations(residents: state.residents)
        if !holding.isEmpty { return "holding violations: \(holding)" }

        let constants = engine.constants
        var windows: [WindowID: Rect] = [:]
        for (id, rec) in state.windows.records where rec.visibility == .visible { windows[id] = rec.snapshot.frame }

        for id in ResidentID.allCases {
            guard let r = state.residents[id] else { return "\(id) missing" }
            let expected = tracker.expectedHeld[id] ?? nil
            if r.heldItem != expected {
                return "\(id) holds \(String(describing: r.heldItem)), expected \(String(describing: expected)) (state \(r.state))"
            }
            if let iid = r.heldItem {
                guard let item = state.items[iid] else { return "\(id) holds missing item" }
                if item.placement != .held(id) { return "held item \(iid) placement \(item.placement)" }
                if r.state == .walking { return "\(id) walking while holding an item" }
            } else if r.state == .carrying {
                return "\(id) carrying without an item"
            }

            // 被持有物件的显示位置 = 持有者位置 + 固定偏移（含悬挂、下落、爬梯、小跳和戳跳跃）。
            if let rv = out.view.residents.first(where: { $0.id == id }), let p = rv.position, !rv.isHidden,
               let iid = r.heldItem {
                guard let iv = out.view.items.first(where: { $0.id == iid }) else {
                    return "held item \(iid) of visible \(id) not in view"
                }
                let want = ItemHolding.heldPosition(residentPosition: p)
                if abs(iv.position.x - want.x) > 1e-9 || abs(iv.position.y - want.y) > 1e-9 {
                    return "held item at \(iv.position), \(id) at \(p) (state \(r.state))"
                }
                if iv.holder != id { return "item view holder \(String(describing: iv.holder))" }
                if iv.jumpLift != rv.jumpLift { return "item jumpLift \(iv.jumpLift) vs resident \(rv.jumpLift)" }
                if iv.isFalling || iv.isDragged { return "held item shown falling or dragged" }
            }

            // 搬运速度：同一 Surface 上、不在动作中、所有窗口几何都不变（排除夹紧造成的位移）时，
            // 每帧水平位移不超过 carrySpeed × dt。路面也须不变（层级变化造成的遮挡夹紧同样排除）。
            if let old = tracker.previous[id], old.state == .carrying, r.state == .carrying,
               old.traversal == nil, r.traversal == nil, tracker.previousWindows == windows,
               tracker.previousSurfaces == state.surfaces {
                var dx: Double?
                switch (old.attachment, r.attachment) {
                case let (.window(w0, o0), .window(w1, o1)) where w0 == w1:
                    dx = abs(o1 - o0)
                case let (.ground(x0), .ground(x1)):
                    dx = abs(x1 - x0)
                default:
                    break
                }
                if let dx, dx > constants.carrySpeed * engine.lastDeltaTime + 1e-6 {
                    return "\(id) carried \(dx)pt in one frame (limit \(constants.carrySpeed * engine.lastDeltaTime))"
                }
            }
        }
        tracker.previous = state.residents
        tracker.previousWindows = windows
        tracker.previousSurfaces = state.surfaces
        return nil
    }

    // Feature: v1, Property 26: 搬运不变量
    // **Validates: Requirements 11.8, 11.9, 13.3, 14.1, 14.3, 14.4, 14.5, 14.6, 18.6, 20.1**
    @Test func carryingInvariants() async {
        let c = Tunables()
        #expect(c.carrySpeedRatio > 0 && c.carrySpeedRatio <= 0.8)
        #expect(c.carrySpeed > 0 && c.carrySpeed <= 0.8 * c.walkSpeed)

        await propertyCheck(
            count: 100,
            input: ResidentTests.windowSpecs,
            Gen<Int>.int(in: 0...255),       // 位 0–3 木板掩码；4 都都站在木板上；5 嘟嘟持有果子；6 都都在 Ground；7 梯子
            Gen<Double>.double(in: 0.1...0.9),
            Gen<Double>.double(in: 0.1...0.9),
            Gen<Int>.int(in: 0...1_000_000),
            ResidentTests.worldOps,
            Self.playerActions
        ) { specs, code, fracA, fracB, seed, ops, actions in
            var windows = ResidentTests.makeWindows(specs)
            // 第 8 位：把第一扇窗口放低到 y = 680，并从它的上沿架一架梯子到 Ground；
            // 第 7 位：都都从 Ground 出发（需要爬梯子才能回到窗沿）。
            let withLadder = code & 128 != 0
            if withLadder { windows[0].frame.minY = 680 }
            let ids = windows.map(\.id)
            var now = Date(timeIntervalSince1970: 6_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: UInt64(seed)), demoResident: false)
            var source = FakeWindowSource(snapshots: windows)

            var planks: [PlankID] = []
            for i in 0 ..< max(windows.count - 1, 0) where code & (1 << i) != 0 {
                planks.append(engine.insertPlank(.placed(PlacedPlank(
                    id: PlankID(0),
                    endA: PlankEnd(window: windows[i].id, offset: windows[i].frame.width),
                    endB: PlankEnd(window: windows[i + 1].id, offset: 0)))))
            }
            let first = windows[0], last = windows[windows.count - 1]
            if withLadder {
                engine.insertLadder(.placed(PlacedLadder(
                    id: LadderID(0), top: PlankEnd(window: first.id, offset: 40),
                    bottomSurface: .ground, bottom: Point(x: first.frame.minX + 40, y: Self.screen.groundY))))
            }
            if code & 64 != 0 {
                engine.place(Resident(
                    id: .a, attachment: .ground(x: max(first.frame.minX - 40, 10)), goal: .reach(.b)))
            } else if code & 16 != 0, let pid = planks.first {
                engine.place(Resident(id: .a, attachment: .plank(pid, t: fracA), goal: .reach(.b)))
            } else {
                engine.place(Resident(
                    id: .a, attachment: .window(first.id, offset: first.frame.width * fracA), goal: .reach(.b)))
            }
            // 都都从 Ground 出发且有梯子时，嘟嘟住在梯子所在的窗口，让都都必须爬梯子去找它。
            let home = (withLadder && code & 64 != 0) ? first : last
            engine.place(Resident(
                id: .b, attachment: .window(home.id, offset: home.frame.width * fracB), facing: .left))

            let flower = Item.flowerPot(placement: .attached(.ground(x: 0)))
            guard engine.give(flower, to: .a) else { Issue.record("give flower failed"); return }
            var expected: [ResidentID: ItemID?] = [.a: flower.id, .b: nil]
            if code & 32 != 0 {
                let fruit = Item.fruit(placement: .attached(.ground(x: 0)))
                guard engine.give(fruit, to: .b) else { Issue.record("give fruit failed"); return }
                expected[.b] = fruit.id
            }
            let looseFruit = Item.fruit(placement: .attached(.ground(x: 300 + 800 * fracB)))
            engine.insertItem(looseFruit)

            var tracker = Tracker(expectedHeld: expected)
            var lastOut: StepOutput?

            func step(_ label: String, pointer: [PointerEvent] = []) -> Bool {
                now = now.addingTimeInterval(Self.dt)
                let out = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, pointer: pointer, now: now))
                lastOut = out
                if let v = Self.violation(engine: engine, out: out, tracker: &tracker) {
                    Issue.record("\(label): \(v)")
                    return false
                }
                return true
            }

            /// 物件当前的显示位置（底边中点）上方 6pt，落在物件图形内。
            func itemPoint(_ id: ItemID) -> Point? {
                lastOut?.view.items.first { $0.id == id }.map { Point(x: $0.position.x, y: $0.position.y - 6) }
            }

            func playerAction(_ kind: Int, _ label: String) -> Bool {
                switch kind {
                case 1:
                    guard let p = lastOut?.view.residents.first(where: { $0.id == .a })?.position else { return true }
                    let q = Point(x: p.x, y: p.y - 16)
                    return step("\(label) poke", pointer: [.down(q), .up(q)])
                case 2:
                    guard let p = itemPoint(flower.id) else { return true }
                    let q = Point(x: p.x + 40, y: p.y - 60)
                    return step("\(label) press held", pointer: [.down(p)])
                        && step("\(label) drag held", pointer: [.moved(q)])
                        && step("\(label) release held", pointer: [.up(q)])
                case 3:
                    guard let p = itemPoint(looseFruit.id) else { return true }
                    let q = Point(x: p.x + 30, y: p.y - 80)
                    guard step("\(label) press fruit", pointer: [.down(p)]),
                          step("\(label) drag fruit", pointer: [.moved(q)]) else { return false }
                    if case .dragged = engine.state.items[looseFruit.id]?.placement {
                        if engine.give(looseFruit, to: .b) {
                            Issue.record("\(label): resident picked up a dragged item")
                            return false
                        }
                    }
                    return step("\(label) release fruit", pointer: [.up(q)])
                default:
                    return true
                }
            }

            for f in 0 ..< 10 { guard step("initial frame \(f)") else { return } }
            for (n, op) in ops.enumerated() {
                ResidentTests.apply(op, to: &source, ids: ids)
                for f in 0 ..< op.frames {
                    guard step("op \(n) \(op) frame \(f)") else { return }
                }
                guard playerAction(actions[n % actions.count], "op \(n) action \(actions[n % actions.count])") else {
                    return
                }
            }
            // 收尾：让下落中的居民全部落地，落地后仍持有原物件（由每帧检查覆盖）。
            for f in 0 ..< 90 { guard step("settle frame \(f)") else { return } }
        }
    }
}
