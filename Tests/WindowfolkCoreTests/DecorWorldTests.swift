import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// v2 Property 7：Decor 遵守 v1 的跟随、隐藏、掉落与无悬空规则（v2 Requirement 3.9、3.12）。
///
/// 随机窗口布局、窗沿 / 木板 / Ground 上和下落中的 Decor、相邻窗口之间的木板，经受随机操作序列：窗口移动
/// （含移出主显示器，按隐藏处理）、缩放、隐藏、显示、关闭、置前、置后、读取失败，玩家拖动场上 Decor
/// （放到窗沿附近、任意位置或 Toolbox）以及从 Decor_Slot 拖出新 Decor。每次 step 结束时用独立检查器验证：
///
/// - 无悬空：每个 Decor 拖动中、下落中、附着在 Hidden_Window 上，或底边落在某条 Surface 上（同时要求
///   `invariantViolations()` 为空）；
/// - 跟随与隐藏：本帧开始时放着的 Decor，若其 Attachment 所指的 Surface 仍在（窗口可见且该点未被遮住、
///   木板仍架设、Ground），本帧结束时 Attachment 完全不变，渲染位置随窗口平移；若所在窗口为
///   Hidden_Window，Attachment 不变且不渲染；
/// - 掉落：只有所在窗沿点消失（被遮住、缩短）、窗口关闭或木板失效时才离开原 Attachment，结果只能是夹紧到
///   同一窗口剩余窗沿、被动下落（`byPlayer == false`），或本帧内已落地（`placedSeq` 增大）；从可见窗口或刚关闭的
///   窗口下落时，起点 x 等于原位置 x（限制在屏幕内）。
///
/// 窗口几何与隐藏、关闭状态取自假窗口源最近一次成功的轮询（复用 v1 Property 42 的 `Truth`、`poll`、`isOnSurface`）。
struct DecorWorldTests {
    typealias Inv = NoFloatingInvariantTests
    typealias Anchor = CoreAttachment

    static let screen = Inv.screen
    static let dt = 1.0 / 30
    static let eps = 1e-6

    // MARK: - 生成器

    /// 初始 Decor：`kind` 0...5 窗沿，6...7 木板，8 Ground，9 从高处下落。
    struct DecorSpec: Sendable, CustomStringConvertible {
        var kind: Int
        var index: Int
        var frac: Int
        var lamp: Bool
        var description: String { "decor(k\(kind), i\(index), \(frac)%, \(lamp ? "lamp" : "chair"))" }
    }

    static var decorSpecs: Generator<[DecorSpec], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...9),
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: 0...100),
            Gen<Bool>.bool
        ).map { DecorSpec(kind: $0, index: $1, frac: $2, lamp: $3) }
            .array(of: 1...6)
    }

    struct Op: Sendable, CustomStringConvertible {
        var kind: Int
        var index: Int
        var a: Int
        var b: Int
        var frames: Int

        static let names = [
            "move", "move", "move", "resize", "hide", "show", "close", "front", "behind", "failPoll",
            "dragDecor", "dragDecor", "dragNewDecor", "wait",
        ]
        var description: String { "\(Self.names[kind])(w\(index), \(a), \(b)) + \(frames)f" }
    }

    static var ops: Generator<[Op], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...13),
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: -24...24),
            Gen<Int>.int(in: -24...24),
            Gen<Int>.int(in: 1...12)
        ).map { Op(kind: $0, index: $1, a: $2, b: $3, frames: $4) }
            .array(of: 1...15)
    }

    // MARK: - 独立检查

    /// Attachment 自身所指的 Surface 在 `p` 处仍存在：窗口可见、x 在上沿范围内且该点未被前方窗口遮住；
    /// 木板仍架设且两端可见；Ground 上 x 在屏幕范围内。
    static func ownSurfaceHolds(_ a: Anchor, _ p: Point, truth: Inv.Truth, world: WorldState) -> Bool {
        switch a {
        case let .window(wid, _):
            guard let i = truth.visible.firstIndex(where: { $0.id == wid }) else { return false }
            let f = truth.visible[i].frame
            func open(_ x: Double) -> Bool {
                guard x >= f.minX - eps, x <= f.maxX + eps else { return false }
                return !truth.visible[..<i].contains { g in
                    g.frame.minY <= f.minY && f.minY <= g.frame.maxY
                        && g.frame.minX + eps < x && x < g.frame.maxX - eps
                }
            }
            // 该点还须属于一段长度 > 0 的可见窗沿：整条上沿被遮住、只剩遮挡边界上的一个点时，Surface 已不存在。
            let delta = 0.5
            return open(p.x) && (open(p.x - delta) || open(p.x + delta))
        case .plank:
            return Inv.isOnSurface(p, truth: truth, planks: world.planks)
        case .ground:
            return Inv.isOnSurface(p, truth: truth, planks: world.planks)
        case .ladder, .free:
            return false
        }
    }

    /// 起点 x 在屏幕内留有余量时才比较（`Physics.startFall` 会把 x 限制到屏幕内）。
    static func fallXMatches(_ actual: Double, expected: Double) -> Bool {
        let v = screen.visibleFrame
        guard expected > v.minX + 1, expected < v.maxX - 1 else { return true }
        return abs(actual - expected) <= 1e-6
    }

    /// 本帧的跟随、隐藏、掉落规则与无悬空检查。返回违规描述。
    static func violations(
        before: [DecorID: Decor], world: WorldState, view: WorldView,
        prevTruth: Inv.Truth, truth: Inv.Truth, lastVisible: [WindowID: Rect]
    ) -> [String] {
        var out: [String] = []
        let after = world.decors.decors
        let views = Dictionary(view.decors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 无悬空与渲染位置。
        for id in after.keys.sorted() {
            guard let d = after[id] else { continue }
            guard case let .attached(a) = d.placement else { continue }
            switch Inv.resolve(a, truth: truth, world: world) {
            case .exemptHidden:
                if views[id] != nil { out.append("decor \(id.rawValue) on hidden window is rendered") }
            case let .unresolved(why):
                out.append("decor \(id.rawValue) unsupported: \(why)")
            case let .position(p):
                if !Inv.isOnSurface(p, truth: truth, planks: world.planks) {
                    out.append("decor \(id.rawValue) floating at \(p) (\(a))")
                }
                if let v = views[id]?.position {
                    if abs(v.x - p.x) > eps || abs(v.y - p.y) > eps {
                        out.append("decor \(id.rawValue) rendered at \(v), expected \(p) (\(a))")
                    }
                } else {
                    out.append("decor \(id.rawValue) attached at \(p) but not rendered")
                }
            }
        }

        // 本帧开始时放着的 Decor 的去向。
        for id in before.keys.sorted() {
            guard let old = before[id], case let .attached(a) = old.placement else { continue }
            guard let new = after[id] else {
                out.append("decor \(id.rawValue) attached at \(a) vanished")
                continue
            }
            if new.placement.isDragged { continue }   // 本帧被玩家拿起

            let resolved = Inv.resolve(a, truth: truth, world: world)
            if case .exemptHidden = resolved {
                if new.placement != old.placement {
                    out.append("decor \(id.rawValue) on hidden window changed \(old.placement) -> \(new.placement)")
                }
                continue
            }
            if case let .position(p) = resolved, ownSurfaceHolds(a, p, truth: truth, world: world) {
                if new.placement != old.placement {
                    out.append("decor \(id.rawValue) left a surviving surface \(a) -> \(new.placement)")
                }
                continue
            }

            // 原 Surface 已不在：夹紧到同一窗口、被动下落或本帧已落地。
            switch new.placement {
            case let .attached(b):
                var clamped = false
                if case let .window(w0, o0) = a, case let .window(w1, o1) = b, w0 == w1, o0 != o1 { clamped = true }
                if !clamped && new.placedSeq <= old.placedSeq {
                    out.append("decor \(id.rawValue) moved \(a) -> \(b) without falling")
                }
            case let .falling(f, byPlayer):
                if byPlayer { out.append("decor \(id.rawValue) fell with byPlayer = true") }
                if case let .window(wid, offset) = a {
                    let closedNow = prevTruth.existing.contains(wid) && !truth.existing.contains(wid)
                    let base: Rect? = closedNow ? lastVisible[wid] : truth.frame(wid)
                    if let base, !fallXMatches(f.position.x, expected: base.minX + offset) {
                        out.append("decor \(id.rawValue) fell from x \(f.position.x), expected \(base.minX + offset)")
                    }
                }
            case .dragged:
                break
            }
        }
        return out
    }

    // MARK: - 属性

    // Feature: V2, Property 7: Decor 遵守 v1 的跟随、隐藏、掉落与无悬空规则
    // **Validates: Requirements 3.9, 3.12**
    @Test func decorFollowsHidesFallsAndNeverFloats() async {
        await propertyCheck(
            count: 100,
            input: ResidentTests.windowSpecs,
            Self.decorSpecs,
            Gen<Int>.int(in: 0...31),            // 位 0...3：相邻窗口之间的木板；位 4：解锁 Decor
            Gen<Int>.int(in: 0...1_000_000),
            Self.ops
        ) { specs, decorSpecs, mask, seed, ops in
            let windows = ResidentTests.makeWindows(specs)
            var ids = windows.map(\.id)
            var source = FakeWindowSource(snapshots: windows)
            var now = Date(timeIntervalSince1970: 5_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: UInt64(seed)), demoResident: false)

            var planks: [PlankID] = []
            for i in 0 ..< max(windows.count - 1, 0) where mask & (1 << i) != 0 {
                planks.append(engine.insertPlank(.placed(PlacedPlank(
                    id: PlankID(0),
                    endA: PlankEnd(window: windows[i].id, offset: windows[i].frame.width),
                    endB: PlankEnd(window: windows[i + 1].id, offset: 0)))))
            }
            if mask & 16 != 0 {
                engine.unlockDecor(.chair)
                engine.unlockDecor(.lamp)
            }
            for (k, s) in decorSpecs.enumerated() {
                let u = Double(s.frac) / 100
                let placement: DecorPlacement
                switch s.kind {
                case 0...5 where !windows.isEmpty:
                    let w = windows[s.index % windows.count]
                    placement = .attached(.window(w.id, offset: w.frame.width * u))
                case 6...7 where !planks.isEmpty:
                    placement = .attached(.plank(planks[s.index % planks.count], t: u))
                case 9:
                    placement = .falling(
                        FallState(position: Point(x: 40 + 1360 * u, y: 100)), byPlayer: false)
                default:
                    placement = .attached(.ground(x: 20 + 1400 * u))
                }
                engine.insertDecor(Decor(
                    id: DecorID(UInt64(k + 1)), type: s.lamp ? .lamp : .chair, placement: placement))
            }

            var truth = Inv.Truth()
            var lastVisible: [WindowID: Rect] = [:]
            var lastOut: StepOutput?

            func step(_ label: String, pointer: [PointerEvent] = []) -> Bool {
                let before = engine.state.decors.decors
                let prevTruth = truth
                let result = Inv.poll(&source)
                if case let .success(eligible, existing) = result {
                    truth = Inv.Truth(visible: eligible, existing: existing)
                }
                now = now.addingTimeInterval(Self.dt)
                let out = engine.step(FrameInput(poll: result, screen: Self.screen, pointer: pointer, now: now))
                lastOut = out
                let mine = Self.violations(
                    before: before, world: engine.state, view: out.view,
                    prevTruth: prevTruth, truth: truth, lastVisible: lastVisible)
                let engines = engine.invariantViolations()
                for w in truth.visible { lastVisible[w.id] = w.frame }
                guard mine.isEmpty, engines.isEmpty else {
                    Issue.record("\(label): checker \(mine); engine \(engines)")
                    return false
                }
                return true
            }

            func drag(from p: Point, to q: Point, _ label: String) -> Bool {
                step("\(label) down", pointer: [.down(p)])
                    && step("\(label) move", pointer: [.moved(Point(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2))])
                    && step("\(label) move", pointer: [.moved(q)])
                    && step("\(label) up", pointer: [.up(q)])
            }

            /// 拖放目标：某扇窗口上沿附近、Toolbox 中心，或屏幕上的任意位置。
            func target(_ op: Op) -> Point {
                if op.b > 18 {
                    let t = ToolboxLayout.frame(screen: Self.screen, unlocked: engine.state.decors.unlocked)
                    return Point(x: t.midX, y: t.midY)
                }
                if let w = source.window(ids.isEmpty ? 0 : ids[op.index % ids.count]), op.b >= -12 {
                    let f = w.snapshot.frame
                    return Point(x: f.minX + f.width * Double(op.a + 24) / 48, y: f.minY - Double(op.b + 12))
                }
                return Point(x: 720 + Double(op.a) * 28, y: 450 + Double(op.b) * 15)
            }

            for f in 0 ..< 3 { guard step("initial frame \(f)") else { return } }

            for (n, op) in ops.enumerated() {
                let label = "op \(n) \(op)"
                let id = ids.isEmpty ? nil : ids[op.index % ids.count]
                let frame = id.flatMap { source.window($0)?.snapshot.frame }
                var pointerDone = true

                switch op.kind {
                case 0...2:
                    if let id, let f = frame {
                        source.move(id, to: Point(x: f.minX + Double(op.a) * 16, y: f.minY + Double(op.b) * 8))
                    }
                case 3:
                    if let id, let f = frame {
                        source.resize(id, to: (max(120, f.width + Double(op.a) * 8), max(120, f.height + Double(op.b) * 4)))
                    }
                case 4:
                    if let id { source.hide(id) }
                case 5:
                    if let id { source.show(id) }
                case 6:
                    if let id, abs(op.a) >= 12 {
                        source.close(id)
                        ids.removeAll { $0 == id }
                    } else if let id {
                        source.show(id)
                    }
                case 7:
                    if let id { source.bringToFront(id) }
                case 8:
                    if let id, ids.count >= 2 { source.sendBehind(id, ids[(op.index + 1) % ids.count]) }
                case 9:
                    source.failNextPoll = true
                case 10, 11:
                    let regions = (lastOut?.view.hitRegions ?? []).filter {
                        if case .decor = $0.target { return true }
                        return false
                    }
                    if !regions.isEmpty {
                        let r = regions[abs(op.a) % regions.count].rect
                        pointerDone = drag(from: Point(x: r.midX, y: r.midY), to: target(op), label)
                    }
                case 12:
                    let unlocked = engine.state.decors.unlocked
                    let type: DecorType = op.a >= 0 ? .chair : .lamp
                    if let z = ToolboxLayout.zoneFrame(.decor(type), screen: Self.screen, unlocked: unlocked) {
                        pointerDone = drag(from: Point(x: z.midX, y: z.midY), to: target(op), label)
                    }
                default:
                    break
                }
                guard pointerDone else { return }
                for f in 0 ..< op.frames {
                    guard step("\(label) frame \(f)") else { return }
                }
            }
            for f in 0 ..< 45 { guard step("settle frame \(f)") else { return } }
        }
    }

    // Feature: V2, Property 8: Decor 不影响通路
    // **Validates: Requirements 3.11**
    //
    // 两个引擎使用相同的窗口、木板、梯子和随机种子，只有一个放入 Decor（每个 Decor 再复制一份放在同一位置，
    // 保证互相重叠，另有下落中的 Decor）。两边经受相同的窗口操作序列，每次 step 后 Surface 列表和 Nav_Graph
    // 的节点、边必须完全相同。
    @Test func decorsDoNotAffectNavGraph() async {
        await propertyCheck(
            count: 100,
            input: ResidentTests.windowSpecs,
            Self.decorSpecs,
            Gen<Int>.int(in: 0...255),           // 位 0...3：相邻窗口之间的木板；位 4...7：窗口上的梯子
            Gen<Int>.int(in: 0...1_000_000),
            ResidentTests.worldOps
        ) { specs, decorSpecs, mask, seed, ops in
            let windows = ResidentTests.makeWindows(specs)
            let ids = windows.map(\.id)
            var plainSource = FakeWindowSource(snapshots: windows)
            var decorSource = FakeWindowSource(snapshots: windows)
            var now = Date(timeIntervalSince1970: 5_000_000)

            func makeEngine() -> (WorldEngine, [PlankID]) {
                let engine = WorldEngine(
                    clockStart: now, screen: Self.screen, rng: RandomSource(seed: UInt64(seed)), demoResident: false)
                var planks: [PlankID] = []
                for i in 0 ..< max(windows.count - 1, 0) where mask & (1 << i) != 0 {
                    planks.append(engine.insertPlank(.placed(PlacedPlank(
                        id: PlankID(0),
                        endA: PlankEnd(window: windows[i].id, offset: windows[i].frame.width),
                        endB: PlankEnd(window: windows[i + 1].id, offset: 0)))))
                }
                for i in 0 ..< min(windows.count, 4) where mask & (16 << i) != 0 {
                    let w = windows[i]
                    let off = (w.frame.width * Double(i + 1) / 5).rounded()
                    engine.insertLadder(.placed(PlacedLadder(
                        id: LadderID(0), top: PlankEnd(window: w.id, offset: off),
                        bottomSurface: .ground, bottom: Point(x: w.frame.minX + off, y: Self.screen.groundY))))
                }
                return (engine, planks)
            }

            let (plain, _) = makeEngine()
            let (decorated, planks) = makeEngine()
            var next: UInt64 = 1
            for s in decorSpecs {
                let u = Double(s.frac) / 100
                let placement: DecorPlacement
                switch s.kind {
                case 0...5:
                    let w = windows[s.index % windows.count]
                    placement = .attached(.window(w.id, offset: w.frame.width * u))
                case 6...7 where !planks.isEmpty:
                    placement = .attached(.plank(planks[s.index % planks.count], t: u))
                case 9:
                    placement = .falling(FallState(position: Point(x: 40 + 1360 * u, y: 100)), byPlayer: false)
                default:
                    placement = .attached(.ground(x: 20 + 1400 * u))
                }
                // 同一位置放两个（类型可不同），保证有重叠的 Decor。
                for type in [s.lamp ? DecorType.lamp : .chair, s.lamp ? .chair : .lamp] {
                    decorated.insertDecor(Decor(id: DecorID(next), type: type, placement: placement))
                    next += 1
                }
            }

            func step(_ label: String) -> Bool {
                now = now.addingTimeInterval(Self.dt)
                let p1 = Inv.poll(&plainSource), p2 = Inv.poll(&decorSource)
                plain.step(FrameInput(poll: p1, screen: Self.screen, now: now))
                decorated.step(FrameInput(poll: p2, screen: Self.screen, now: now))
                let a = plain.state, b = decorated.state
                guard a.surfaces == b.surfaces, a.nav == b.nav else {
                    Issue.record("""
                        \(label): nav differs with decors \(b.decors.decors.values.map(\.placement))
                        surfaces equal: \(a.surfaces == b.surfaces)
                        nodes without decor: \(a.nav.nodes.keys.sorted { "\($0)" < "\($1)" })
                        nodes with decor: \(b.nav.nodes.keys.sorted { "\($0)" < "\($1)" })
                        """)
                    return false
                }
                return true
            }

            for f in 0 ..< 3 { guard step("initial frame \(f)") else { return } }
            for (n, op) in ops.enumerated() {
                ResidentTests.apply(op, to: &plainSource, ids: ids)
                ResidentTests.apply(op, to: &decorSource, ids: ids)
                for f in 0 ..< op.frames {
                    guard step("op \(n) \(op) frame \(f)") else { return }
                }
            }
        }
    }
}
