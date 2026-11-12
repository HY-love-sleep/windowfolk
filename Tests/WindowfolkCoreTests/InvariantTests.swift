import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// Property 42：无悬空不变量（Requirement 6.1、6.2、9.10、29.5、29.6）。
///
/// 随机世界（窗口、两位居民、窗沿上和被持有的物件、木板、梯子）经受长随机操作序列：窗口移动（含移出主显示器）、
/// 缩放、隐藏、显示、关闭、置前、置后、读取失败，玩家从 Toolbox 拖出木板和梯子、拖动场上的物件，
/// 以及「让都都去找嘟嘟」「给都都一个花盆」两项调试命令。每次 step 结束时用独立的检查器验证不变量：
/// 窗口几何与隐藏、关闭状态取自假窗口源最近一次成功的轮询（而不是引擎的窗口表），路面按 Property 3
/// 的逐点刻画和木板两端点自行计算，对象位置由 Attachment 自行换算。同时要求 `invariantViolations()` 为空。
struct NoFloatingInvariantTests {
    static let screen = WindowFilterTests.pollScreen
    static let dt = 1.0 / 30
    static let eps = 1e-6

    // MARK: - 操作

    struct Op: Sendable, CustomStringConvertible {
        var kind: Int
        var index: Int
        var a: Int
        var b: Int
        var frames: Int

        static let names = [
            "move", "move", "move", "resize", "hide", "show", "close", "front", "behind", "failPoll",
            "seek", "giveFlower", "dragNewPlank", "dragNewLadder", "dragObject", "wait",
        ]
        var description: String { "\(Self.names[kind])(w\(index), \(a), \(b)) + \(frames)f" }
    }

    static var ops: Generator<[Op], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...15),
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: -24...24),
            Gen<Int>.int(in: -24...24),
            Gen<Int>.int(in: 1...20)
        ).map { Op(kind: $0, index: $1, a: $2, b: $3, frames: $4) }
            .array(of: 1...25)
    }

    // MARK: - 真实窗口（检查器的数据来源）

    /// 最近一次成功轮询看到的窗口：可见窗口按从前到后排列，`existing` 含隐藏窗口。
    struct Truth {
        var visible: [WindowSnapshot] = []
        var existing: Set<WindowID> = []

        func frame(_ id: WindowID) -> Rect? { visible.first { $0.id == id }?.frame }
        func isHidden(_ id: WindowID) -> Bool { existing.contains(id) && frame(id) == nil }
    }

    /// 像 CGWindowSource 一样，把中心点不在主显示器内的窗口排除在 Eligible_Window 之外（Requirement 2.6）。
    static func poll(_ source: inout FakeWindowSource) -> WindowPollResult {
        guard case let .success(eligible, existing) = source.poll() else { return .failure }
        let f = screen.frame
        let kept = eligible.filter { w in
            let cx = w.frame.minX + w.frame.width / 2, cy = w.frame.minY + w.frame.height / 2
            return cx >= f.minX && cx <= f.maxX && cy >= f.minY && cy <= f.maxY
        }
        let renumbered = kept.enumerated().map { i, w in var w = w; w.zIndex = i; return w }
        return .success(eligible: renumbered, existingIDs: existing)
    }

    // MARK: - 独立检查器

    /// 点 `p` 站在某条路面上：Ground、某个可见窗口未被前方窗口遮住的上沿，或两端窗口都可见的已架设木板。
    /// 窗沿按逐点刻画判定：前方窗口覆盖该上沿 y、且 x 落在其开区间 (minX, maxX) 内才算被遮住
    /// （区间端点是剩余窗沿的端点，仍可站立）。
    static func isOnSurface(_ p: Point, truth: Truth, planks: PlankStore) -> Bool {
        let tol = WorldEngine.supportTolerance
        let v = screen.visibleFrame
        if abs(p.y - v.maxY) <= tol, p.x >= v.minX - eps, p.x <= v.maxX + eps { return true }

        for (i, w) in truth.visible.enumerated() {
            let y = w.frame.minY
            guard abs(p.y - y) <= tol, p.x >= w.frame.minX - eps, p.x <= w.frame.maxX + eps else { continue }
            let covered = truth.visible[..<i].contains { f in
                f.frame.minY <= y && y <= f.frame.maxY && f.frame.minX + eps < p.x && p.x < f.frame.maxX - eps
            }
            if !covered { return true }
        }

        for state in planks.planks.values {
            guard let placed = state.placed, let (l, r) = plankEnds(placed, truth: truth) else { continue }
            guard p.x >= l.x - eps, p.x <= r.x + eps else { continue }
            let y = r.x == l.x ? min(l.y, r.y) : l.y + (r.y - l.y) * (p.x - l.x) / (r.x - l.x)
            if abs(p.y - y) <= tol { return true }
        }
        return false
    }

    /// 已架设木板两端的当前屏幕坐标（按 x 排序）；任一端窗口不可见时为 nil。
    static func plankEnds(_ p: PlacedPlank, truth: Truth) -> (Point, Point)? {
        guard let fa = truth.frame(p.endA.window), let fb = truth.frame(p.endB.window) else { return nil }
        let a = Point(x: fa.minX + p.endA.offset, y: fa.minY)
        let b = Point(x: fb.minX + p.endB.offset, y: fb.minY)
        return b.x < a.x ? (b, a) : (a, b)
    }

    /// 一个 Attachment 的支撑判定结果。
    enum Support { case exemptHidden, position(Point), unresolved(String) }

    /// `WindowfolkCore` 的 Attachment（与 `Testing.Attachment` 同名，因此由属性类型推得）。
    typealias Anchor = CoreAttachment

    static func resolve(_ a: Anchor, truth: Truth, world: WorldState) -> Support {
        switch a {
        case let .window(wid, offset):
            if truth.isHidden(wid) { return .exemptHidden }
            guard let f = truth.frame(wid) else { return .unresolved("window \(wid) is closed") }
            return .position(Point(x: f.minX + offset, y: f.minY))
        case let .ground(x):
            return .position(Point(x: x, y: screen.groundY))
        case let .plank(pid, t):
            guard let placed = world.planks.planks[pid]?.placed else { return .unresolved("plank \(pid) not placed") }
            if truth.isHidden(placed.endA.window) || truth.isHidden(placed.endB.window) { return .exemptHidden }
            guard let (l, r) = plankEnds(placed, truth: truth) else { return .unresolved("plank end window closed") }
            let u = min(max(t, 0), 1)
            return .position(Point(x: l.x + (r.x - l.x) * u, y: l.y + (r.y - l.y) * u))
        case let .ladder(lid, height):
            guard let placed = world.ladders.ladders[lid]?.placed else { return .unresolved("ladder \(lid) not placed") }
            if truth.isHidden(placed.top.window) { return .exemptHidden }
            guard let f = truth.frame(placed.top.window) else { return .unresolved("ladder top window closed") }
            let top = Point(x: f.minX + placed.top.offset, y: f.minY)
            let h = min(max(height, 0), max(placed.bottom.y - top.y, 0))
            return .position(Point(x: top.x, y: placed.bottom.y - h))
        case let .free(p):
            return .position(p)
        }
    }

    /// 返回违规描述；满足不变量时为空。
    static func violations(_ world: WorldState, truth: Truth) -> [String] {
        var out: [String] = []
        for (id, r) in world.residents.sorted(by: { $0.key < $1.key }) {
            if r.state == .falling || r.state == .hanging { continue }
            // (b) 在已架设梯子上爬梯。
            if r.state == .climbing, case let .ladder(lid, _) = r.attachment,
               world.ladders.ladders[lid]?.placed != nil { continue }
            switch resolve(r.attachment, truth: truth, world: world) {
            case .exemptHidden:
                continue   // (d)
            case let .unresolved(why):
                out.append("\(id) in \(r.state) unsupported: \(why)")
            case let .position(p):
                if !isOnSurface(p, truth: truth, planks: world.planks) {
                    out.append("\(id) in \(r.state) floating at \(p) (\(r.attachment))")
                }
            }
        }
        for iid in world.items.sortedIDs {
            guard let item = world.items[iid] else { continue }
            switch item.placement {
            case .falling, .dragged:
                continue
            case let .held(rid):
                // (c) 被某位居民持有：持有关系必须双向一致。
                if world.residents[rid]?.heldItem != iid { out.append("item \(iid) held by \(rid) who does not hold it") }
            case let .attached(a):
                switch resolve(a, truth: truth, world: world) {
                case .exemptHidden:
                    continue
                case let .unresolved(why):
                    out.append("item \(iid) unsupported: \(why)")
                case let .position(p):
                    if !isOnSurface(p, truth: truth, planks: world.planks) {
                        out.append("item \(iid) floating at \(p) (\(a))")
                    }
                }
            }
        }
        return out
    }

    // MARK: - 属性

    // Feature: v1, Property 42: 无悬空不变量
    // **Validates: Requirements 6.1, 6.2, 9.10, 29.5, 29.6**
    @Test func noFloatingObjects() async {
        await propertyCheck(
            count: 100,
            input: ResidentTests.windowSpecs,
            Gen<Int>.int(in: 0...9_999).array(of: 40),
            Gen<Int>.int(in: 0...255),       // 相邻窗口之间的木板掩码；位 7：嘟嘟照常闲逛
            Gen<Int>.int(in: 0...1_000_000),
            Self.ops
        ) { specs, params, mask, seed, ops in
            let windows = ResidentTests.makeWindows(specs)
            var ids = windows.map(\.id)
            var source = FakeWindowSource(snapshots: windows)
            var now = Date(timeIntervalSince1970: 4_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: UInt64(seed)), demoResident: false)

            WindowFilterTests.buildWorld(engine, windows: windows, params: params)
            for i in 0 ..< max(windows.count - 1, 0) where mask & (1 << i) != 0 {
                engine.insertPlank(.placed(PlacedPlank(
                    id: PlankID(0),
                    endA: PlankEnd(window: windows[i].id, offset: windows[i].frame.width),
                    endB: PlankEnd(window: windows[i + 1].id, offset: 0))))
            }
            if mask & 128 != 0, let b = engine.state.residents[.b] {
                engine.place(Resident(id: .b, attachment: b.attachment, heldItem: b.heldItem))
            }

            var truth = Truth()
            var lastOut: StepOutput?

            func step(_ label: String, pointer: [PointerEvent] = [], commands: [Command] = []) -> Bool {
                let result = Self.poll(&source)
                if case let .success(eligible, existing) = result {
                    truth = Truth(visible: eligible, existing: existing)
                }
                now = now.addingTimeInterval(Self.dt)
                lastOut = engine.step(FrameInput(
                    poll: result, screen: Self.screen, pointer: pointer, commands: commands, now: now))
                let mine = Self.violations(engine.state, truth: truth)
                let engines = engine.invariantViolations()
                guard mine.isEmpty, engines.isEmpty else {
                    Issue.record("\(label): checker \(mine); engine \(engines)")
                    return false
                }
                return true
            }

            /// 按下、拖到目标点、松开，每一步各推进一帧。
            func drag(from p: Point, to q: Point, _ label: String) -> Bool {
                step("\(label) down", pointer: [.down(p)])
                    && step("\(label) move", pointer: [.moved(Point(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2))])
                    && step("\(label) move", pointer: [.moved(q)])
                    && step("\(label) up", pointer: [.up(q)])
            }

            /// 拖动目标：某扇窗口上沿附近，或屏幕上的任意位置（含屏幕外）。
            func target(_ op: Op) -> Point {
                if let w = source.window(ids.isEmpty ? 0 : ids[op.index % ids.count]), op.b >= -12 {
                    let f = w.snapshot.frame
                    return Point(x: f.minX + f.width * Double(op.a + 24) / 48, y: f.minY - Double(op.b + 12))
                }
                return Point(x: 720 + Double(op.a) * 40, y: 450 + Double(op.b) * 20)
            }

            for f in 0 ..< 5 { guard step("initial frame \(f)") else { return } }

            for (n, op) in ops.enumerated() {
                let label = "op \(n) \(op)"
                let id = ids.isEmpty ? nil : ids[op.index % ids.count]
                let frame = id.flatMap { source.window($0)?.snapshot.frame }
                var pointerDone = true
                var commands: [Command] = []

                switch op.kind {
                case 0...2:
                    // 移动；位移较大时可能把窗口移出主显示器（按隐藏处理）。
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
                    if let id, abs(op.a) >= 16 {
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
                case 10:
                    commands = [.debugSeek]
                case 11:
                    commands = [.debugGiveFlower]
                case 12, 13:
                    let zone: ToolboxZone = op.kind == 12 ? .plank : .ladder
                    let z = ToolboxLayout.zoneFrame(zone, screen: Self.screen)
                    let p = Point(x: z.minX + z.width / 2, y: z.minY + z.height / 2)
                    pointerDone = drag(from: p, to: target(op), label)
                case 14:
                    // 拖动场上的一个物件、落下的木板或梯子（命中区域中心）；没有可拖对象时什么都不做。
                    let regions = (lastOut?.view.hitRegions ?? []).filter {
                        switch $0.target {
                        case .item, .plank, .ladder: return true
                        default: return false
                        }
                    }
                    if !regions.isEmpty {
                        let r = regions[abs(op.a) % regions.count].rect
                        pointerDone = drag(from: Point(x: r.minX + r.width / 2, y: r.minY + r.height / 2),
                                           to: target(op), label)
                    }
                default:
                    break
                }
                guard pointerDone else { return }
                guard step("\(label) frame 0", commands: commands) else { return }
                for f in 1 ..< op.frames {
                    guard step("\(label) frame \(f)") else { return }
                }
            }
            for f in 0 ..< 60 { guard step("settle frame \(f)") else { return } }
        }
    }
}
