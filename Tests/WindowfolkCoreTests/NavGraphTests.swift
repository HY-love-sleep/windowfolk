import PropertyBased
import Testing
@testable import WindowfolkCore

struct NavGraphTests {
    /// 一块随机木板的生成参数：两条窗沿的选择和各自沿窗沿的比例位置。
    struct PlankSpec: Sendable {
        var first: Int
        var second: Int
        var fracA: Double
        var fracB: Double
    }

    static var plankSpecs: Generator<[PlankSpec], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...999),
            Gen<Int>.int(in: 0...999),
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: 0...1)
        ).map { PlankSpec(first: $0, second: $1, fracA: $2, fracB: $3) }
            .array(of: 0...3)
    }

    /// 按参数在不同窗口的两条窗沿之间架木板；端点取窗沿上的点，不做长度与高差判定。
    static func makePlanks(_ specs: [PlankSpec], windows: [WindowSnapshot]) -> [PlacedPlank] {
        let ledges = SurfaceBuilder.ledges(for: windows)
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        guard !ledges.isEmpty else { return [] }
        var planks: [PlacedPlank] = []
        for (i, s) in specs.enumerated() {
            let a = ledges[s.first % ledges.count]
            guard let wa = a.id.windowID else { continue }
            let others = ledges.filter { $0.id.windowID != wa }
            guard !others.isEmpty else { continue }
            let b = others[s.second % others.count]
            guard let wb = b.id.windowID, let fa = byID[wa], let fb = byID[wb] else { continue }
            let xa = a.start.x + (a.end.x - a.start.x) * s.fracA
            let xb = b.start.x + (b.end.x - b.start.x) * s.fracB
            planks.append(PlacedPlank(
                id: PlankID(UInt64(i + 1)),
                endA: PlankEnd(window: wa, offset: xa - fa.frame.minX),
                endB: PlankEnd(window: wb, offset: xb - fb.frame.minX)))
        }
        return planks
    }

    /// 独立的参考可达性：只用 `allEdges` 做 BFS，drop 边按其方向单向使用。
    static func referenceReachable(_ g: NavGraph, from: SurfaceID, to: SurfaceID) -> Bool {
        guard g.nodes[from] != nil, g.nodes[to] != nil else { return false }
        var adjacency: [SurfaceID: [SurfaceID]] = [:]
        for e in g.allEdges { adjacency[e.from, default: []].append(e.to) }
        var seen: Set<SurfaceID> = [from]
        var queue = [from]
        var head = 0
        while head < queue.count {
            let s = queue[head]
            head += 1
            if s == to { return true }
            for n in adjacency[s] ?? [] where seen.insert(n).inserted { queue.append(n) }
        }
        return false
    }

    /// 一架随机梯子的生成参数：指针位置占屏幕 frame 的比例。
    struct LadderSpec: Sendable {
        var fx: Double
        var fy: Double
    }

    static var ladderSpecs: Generator<[LadderSpec], some SendableSequenceType> {
        zip(Gen<Double>.double(in: 0...1), Gen<Double>.double(in: 0...1))
            .map { LadderSpec(fx: $0, fy: $1) }
            .array(of: 0...3)
    }

    /// 按指针位置在全部窗口的布局上吸附梯子：上端取最近窗沿，下端取上端正下方第一条 Surface。不做长度判定。
    static func makeLadders(_ specs: [LadderSpec], windows: [WindowSnapshot], screen: ScreenInfo) -> [PlacedLadder] {
        let surfaces = SurfaceBuilder.build(windows: windows, screen: screen)
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        var ladders: [PlacedLadder] = []
        for (i, s) in specs.enumerated() {
            let pointer = Point(x: screen.frame.minX + screen.frame.width * s.fx,
                                y: screen.frame.minY + screen.frame.height * s.fy)
            guard let (top, topID) = LadderRules.snapTop(pointer: pointer, ledges: surfaces),
                  let w = topID.windowID, let frame = byID[w]?.frame,
                  let (bottom, bottomID) = LadderRules.bottom(below: top, surfaces: surfaces) else { continue }
            ladders.append(PlacedLadder(
                id: LadderID(UInt64(i + 1)),
                top: PlankEnd(window: w, offset: top.x - frame.minX),
                bottomSurface: bottomID, bottom: bottom))
        }
        return ladders
    }

    /// 一条边在比较时的身份：类型、起点、终点。
    struct EdgeKey: Hashable, CustomStringConvertible {
        var kind: EdgeKind
        var from: SurfaceID
        var to: SurfaceID
        var description: String { "\(kind) \(from) -> \(to)" }
    }

    /// 参考实现：按五条规则逐条暴力枚举边（Requirement 12.2 至 12.6）。
    static func referenceEdges(
        surfaces: [Surface], planks: [PlacedPlank], ladders: [NavLadder],
        windows: [WindowSnapshot], constants k: Tunables
    ) -> Set<EdgeKey> {
        let eps = 1e-6
        var result: Set<EdgeKey> = []
        func both(_ kind: EdgeKind, _ a: SurfaceID, _ b: SurfaceID) {
            result.insert(EdgeKey(kind: kind, from: a, to: b))
            result.insert(EdgeKey(kind: kind, from: b, to: a))
        }
        func covers(_ s: Surface, _ x: Double) -> Bool { x >= s.start.x - eps && x <= s.end.x + eps }

        // walk / smallJump：A 的右端点与 B 的左端点（遍历全部有序对，即覆盖「或反之」）。
        for a in surfaces {
            for b in surfaces where a.id != b.id {
                let rise = abs(b.start.y - a.end.y)
                let gap = b.start.x - a.end.x
                if rise <= eps {
                    // 间隙为 0：首尾相接或重叠（B 的左端点落在 A 的范围内）。
                    if gap <= eps && covers(a, b.start.x) { both(.walk, a.id, b.id) }
                } else if rise <= k.smallJumpMaxRise + eps && abs(gap) <= k.smallJumpMaxGap + eps {
                    both(.smallJump, a.id, b.id)
                }
            }
        }

        // drop：每个端点正下方最近的一条 Surface（并列取 SurfaceID 较小者），高差在 (0, Drop_Max_Height]，单向。
        for h in surfaces {
            for p in [h.start, h.end] {
                let below = surfaces
                    .filter { $0.id != h.id && covers($0, p.x) && $0.y(atX: p.x) > p.y + eps }
                    .min { l, r in
                        let ly = l.y(atX: p.x), ry = r.y(atX: p.x)
                        return ly != ry ? ly < ry : l.id < r.id
                    }
                guard let low = below else { continue }
                let height = low.y(atX: p.x) - p.y
                if height > eps && height <= k.dropMaxHeight + eps {
                    result.insert(EdgeKey(kind: .drop, from: h.id, to: low.id))
                }
            }
        }

        // plank：木板每一端与该端 Attachment 所在窗口上、包含该端点的 Window_Ledge 之间，双向。
        let present = Set(surfaces.map(\.id))
        let frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        for plank in planks where present.contains(.plank(plank.id)) {
            for end in [plank.endA, plank.endB] {
                guard let f = frames[end.window] else { continue }
                let p = Point(x: f.minX + end.offset, y: f.minY)
                for s in surfaces where s.id.windowID == end.window
                    && abs(s.start.y - p.y) <= eps && covers(s, p.x) {
                    both(.plank, s.id, .plank(plank.id))
                }
            }
        }

        // ladder：两端 Surface 都存在且不同时，双向。
        for l in ladders where present.contains(l.bottomSurface) && present.contains(l.topSurface)
            && l.bottomSurface != l.topSurface {
            both(.ladder(l.id), l.bottomSurface, l.topSurface)
        }
        return result
    }

    /// 木板一端恰好落在两扇窗沿相接处时，走木板边连到该端 Attachment 所在窗口的窗沿（Requirement 12.5）。
    @Test func plankEdgeAtSharedLedgeBoundaryUsesOwnWindow() {
        let screen = ScreenInfo(
            frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
            visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))
        // 前方窗口 ID 较小，后方窗口的窗沿 [0, 200] 与前方窗口的窗沿 [200, 500] 在 x = 200 相接。
        let front = WindowSnapshot(id: 1, ownerName: "F", ownerPID: 1,
                                   frame: Rect(minX: 200, minY: 100, width: 300, height: 200), zIndex: 0)
        let back = WindowSnapshot(id: 2, ownerName: "B", ownerPID: 2,
                                  frame: Rect(minX: 0, minY: 100, width: 300, height: 200), zIndex: 1)
        let windows = [front, back]
        let plank = PlacedPlank(id: PlankID(1),
                                endA: PlankEnd(window: 2, offset: 200),
                                endB: PlankEnd(window: 1, offset: 100))
        let surfaces = SurfaceBuilder.build(windows: windows, planks: [plank], screen: screen)
        let graph = NavGraph.build(surfaces: surfaces, planks: [plank], constants: Tunables())
        let plankEdges = Set(graph.allEdges.filter { $0.kind == .plank }.map { EdgeKey(kind: $0.kind, from: $0.from, to: $0.to) })
        let expected = Self.referenceEdges(surfaces: surfaces, planks: [plank], ladders: [],
                                           windows: windows, constants: Tunables())
            .filter { $0.kind == .plank }
        #expect(plankEdges == expected)
        #expect(plankEdges.contains(EdgeKey(kind: .plank, from: .ledge(2, index: 0), to: .plank(PlankID(1)))))
    }

    // Feature: v1, Property 21: 通路图建边
    // **Validates: Requirements 5.5, 12.2, 12.3, 12.4, 12.5, 12.6**
    @Test func navGraphEdgesMatchReference() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen.screen,
            Self.plankSpecs,
            Self.ladderSpecs,
            Gen<Int>.int(in: 0...4095),
            Gen<Int>.int(in: 0...999),
            Gen<Int>.int(in: 0...999)
        ) { windows, screen, plankSpecs, ladderSpecs, hiddenMask, extraA, extraB in
            let k = Tunables()
            // 先在全部窗口上架木板和梯子，再隐藏一部分窗口（约一半的样例不隐藏）。
            let planks = Self.makePlanks(plankSpecs, windows: windows)
            let placedLadders = Self.makeLadders(ladderSpecs, windows: windows, screen: screen)
            let hidden: Set<WindowID> = hiddenMask % 2 == 0 ? [] : Set(
                windows.enumerated().filter { (hiddenMask >> (1 + $0.offset % 11)) & 1 == 1 }.map(\.element.id))
            let visible = windows.filter { !hidden.contains($0.id) }

            var table = WindowTable()
            for w in windows {
                table.records[w.id] = WindowRecord(
                    snapshot: w, visibility: hidden.contains(w.id) ? .hidden : .visible)
            }

            // 与 WorldEngine 相同的建图输入：Surface 只来自可见窗口；梯子经 navLadder 过滤。
            let surfaces = SurfaceBuilder.build(windows: visible, planks: planks, screen: screen)
            let presentPlanks = Set(surfaces.compactMap(\.id.plankID))
            let navPlanks = planks.filter { presentPlanks.contains($0.id) }
            var ladders = placedLadders.compactMap { $0.navLadder(windows: table, surfaces: surfaces) }
            // 额外一架任意两端的梯子（可能两端相同或指向不存在的 Surface），覆盖跳过规则。
            let ids = surfaces.map(\.id) + [.ledge(WindowID(999_999), index: 0)]
            ladders.append(NavLadder(
                id: LadderID(100), bottomSurface: ids[extraA % ids.count], bottom: Point(x: 0, y: 0),
                topSurface: ids[extraB % ids.count], top: Point(x: 0, y: 0)))

            let graph = NavGraph.build(surfaces: surfaces, planks: navPlanks, ladders: ladders, constants: k)
            let actual = Set(graph.allEdges.map { EdgeKey(kind: $0.kind, from: $0.from, to: $0.to) })
            let expected = Self.referenceEdges(
                surfaces: surfaces, planks: navPlanks, ladders: ladders, windows: visible, constants: k)

            let missing = expected.subtracting(actual).sorted { $0.description < $1.description }
            let extra = actual.subtracting(expected).sorted { $0.description < $1.description }
            #expect(missing.isEmpty && extra.isEmpty,
                    "missing \(missing) extra \(extra) hidden \(hidden.count) planks \(navPlanks.count) ladders \(ladders.count)")

            // 隐藏窗口的窗沿、端点附着在隐藏窗口上的木板和梯子不出现在图中（Requirement 5.5）。
            let hiddenPlanks = Set(planks.filter { hidden.contains($0.endA.window) || hidden.contains($0.endB.window) }.map(\.id))
            let hiddenLadders = Set(placedLadders.filter { hidden.contains($0.top.window) }.map(\.id))
            func isHiddenNode(_ id: SurfaceID) -> Bool {
                if let w = id.windowID { return hidden.contains(w) }
                if let p = id.plankID { return hiddenPlanks.contains(p) }
                return false
            }
            #expect(!graph.nodes.keys.contains(where: isHiddenNode), "hidden node in graph")
            for e in graph.allEdges {
                #expect(!isHiddenNode(e.from) && !isHiddenNode(e.to), "edge touches hidden surface: \(e)")
                if case let .ladder(lid) = e.kind {
                    #expect(!hiddenLadders.contains(lid), "ladder on hidden window: \(e)")
                }
            }
        }
    }

    // Feature: v1, Property 22: 路线有效且完整
    // **Validates: Requirements 12.7, 12.12**
    @Test func routeIsValidAndComplete() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen.screen,
            Self.plankSpecs,
            Gen<Int>.int(in: 0...999),
            Gen<Int>.int(in: 0...999),
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: 0...1)
        ) { windows, screen, specs, startIndex, targetIndex, startFrac, targetFrac in
            let k = Tunables()
            let planks = Self.makePlanks(specs, windows: windows)
            let surfaces = SurfaceBuilder.build(windows: windows, planks: planks, screen: screen)
            let graph = NavGraph.build(surfaces: surfaces, planks: planks, constants: k)

            let start = surfaces[startIndex % surfaces.count]
            // 约一半的情况从起点可达的 Surface（不含起点自身）中选目标，保证多步路线被充分覆盖。
            let reachableOthers = surfaces.filter {
                $0.id != start.id && Self.referenceReachable(graph, from: start.id, to: $0.id)
            }
            let target = targetIndex % 2 == 0 && !reachableOthers.isEmpty
                ? reachableOthers[(targetIndex / 2) % reachableOthers.count]
                : surfaces[targetIndex % surfaces.count]
            let x = start.start.x + (start.end.x - start.start.x) * startFrac
            let targetX = target.start.x + (target.end.x - target.start.x) * targetFrac

            let route = graph.route(from: start.id, at: x, to: target.id, targetX: targetX)
            let reachable = Self.referenceReachable(graph, from: start.id, to: target.id)
            let context = "start \(start.id) target \(target.id) planks \(planks.count)"

            // 非空当且仅当参考 BFS 可达
            #expect((route != nil) == reachable, "route=\(route != nil) reachable=\(reachable) \(context)")
            guard let route else { return }

            #expect(route.targetSurface == target.id, "\(context)")
            #expect(route.targetX == targetX, "\(context)")
            if start.id == target.id {
                #expect(route.steps.isEmpty, "\(context)")
            } else {
                // 从起点开始、在目标结束
                #expect(route.steps.first?.from == start.id, "\(context)")
                #expect(route.steps.last?.to == target.id, "\(context)")
            }

            // 相邻两步首尾相接
            for (a, b) in zip(route.steps, route.steps.dropFirst()) {
                #expect(a.to == b.from, "\(a) -> \(b) \(context)")
            }

            for e in route.steps {
                // 每一步都是图中的边
                #expect(graph.contains(e), "\(e) not in graph \(context)")
                // drop 边只从高到低：Core 坐标 y 向下，落点 y 更大
                if e.kind == .drop {
                    #expect(e.entry.y > e.exit.y, "drop goes up: \(e) \(context)")
                    if let from = graph.nodes[e.from], let to = graph.nodes[e.to] {
                        #expect(to.y(atX: e.exit.x) > from.y(atX: e.exit.x), "drop goes up: \(e) \(context)")
                    }
                }
            }

            #expect(graph.isValid(route, from: start.id), "\(context)")

            // 确定性：同一输入重复计算得到相同路线
            let again = NavGraph.build(surfaces: surfaces, planks: planks, constants: k)
                .route(from: start.id, at: x, to: target.id, targetX: targetX)
            #expect(again == route, "\(context)")
        }
    }
}
