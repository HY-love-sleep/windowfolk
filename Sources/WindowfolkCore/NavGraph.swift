import Foundation

// MARK: - 边

/// 通路图中边的类型（Requirement 12.2 至 12.6）。
public enum EdgeKind: Hashable, Sendable {
    /// 两条 Surface 相邻端点 y 相同、水平间隙为 0（首尾相接或重叠），双向。
    case walk
    /// 相邻端点高差在 (0, Small_Jump_Max_Rise]、水平间隙 ≤ Small_Jump_Max_Gap，双向。
    case smallJump
    /// 从较高 Surface 的端点往下跳到正下方最近的 Surface，高差在 (0, Drop_Max_Height]，只从高到低。
    case drop
    /// Plank Surface 与两端所在 Window_Ledge 之间，双向。
    case plank
    /// 梯子下端所在 Surface 与上端所在 Window_Ledge 之间，双向（任务 9.1 由调用方传入 `NavLadder`）。
    case ladder(LadderID)

    fileprivate var rank: Int {
        switch self {
        case .walk: return 0
        case .smallJump: return 1
        case .drop: return 2
        case .plank: return 3
        case .ladder: return 4
        }
    }

    fileprivate static func order(_ a: EdgeKind, _ b: EdgeKind) -> Bool? {
        if a.rank != b.rank { return a.rank < b.rank }
        if case let .ladder(la) = a, case let .ladder(lb) = b, la != lb { return la < lb }
        return nil
    }
}

/// 一条有向边。双向连接表示为两条方向相反的边。
public struct NavEdge: Hashable, Sendable {
    public var from: SurfaceID
    public var to: SurfaceID
    public var kind: EdgeKind
    /// 在 `from` 上离开的点。
    public var exit: Point
    /// 到达 `to` 上的点。
    public var entry: Point
    /// 边本身的固定代价（不含在 Surface 上行走的距离）。
    public var cost: Double

    public init(from: SurfaceID, to: SurfaceID, kind: EdgeKind, exit: Point, entry: Point, cost: Double) {
        self.from = from
        self.to = to
        self.kind = kind
        self.exit = exit
        self.entry = entry
        self.cost = cost
    }

    /// 确定性排序：from、to、kind、exit、entry。
    fileprivate static func order(_ a: NavEdge, _ b: NavEdge) -> Bool {
        if a.from != b.from { return a.from < b.from }
        if a.to != b.to { return a.to < b.to }
        if let k = EdgeKind.order(a.kind, b.kind) { return k }
        if a.exit.x != b.exit.x { return a.exit.x < b.exit.x }
        if a.exit.y != b.exit.y { return a.exit.y < b.exit.y }
        if a.entry.x != b.entry.x { return a.entry.x < b.entry.x }
        return a.entry.y < b.entry.y
    }
}

/// 建图用的梯子输入：一架已架设梯子的两端。任务 9.1 从 `PlacedLadder` 转换得到。
/// 上端所在窗口隐藏时调用方不应传入（Requirement 5.5）。
public struct NavLadder: Hashable, Sendable {
    public var id: LadderID
    public var bottomSurface: SurfaceID
    public var bottom: Point
    public var topSurface: SurfaceID
    public var top: Point

    public init(id: LadderID, bottomSurface: SurfaceID, bottom: Point, topSurface: SurfaceID, top: Point) {
        self.id = id
        self.bottomSurface = bottomSurface
        self.bottom = bottom
        self.topSurface = topSurface
        self.top = top
    }
}

// MARK: - 路线

/// 一条寻路路线：依次经过的边，以及目标 Surface 上的目标 x。
/// `steps` 为空表示起点和目标在同一条 Surface 上，直接走过去。
public struct Route: Hashable, Sendable {
    public var steps: [NavEdge]
    public var targetSurface: SurfaceID
    public var targetX: Double

    public init(steps: [NavEdge] = [], targetSurface: SurfaceID, targetX: Double) {
        self.steps = steps
        self.targetSurface = targetSurface
        self.targetX = targetX
    }
}

// MARK: - NavGraph

/// 通路图（Requirement 12）。节点为 Surface，边见 `EdgeKind`。
///
/// 输入只应包含当前可见窗口的 Window_Ledge、Ground、两端窗口都可见的已架设 Plank，
/// 以及上端窗口可见的已架设 Ladder；Hidden_Window 相关的通路因此自动排除（Requirement 5.5）。
public struct NavGraph: Hashable, Sendable {
    public var nodes: [SurfaceID: Surface]
    /// 每个节点的出边，按确定性顺序排列。
    public var edges: [SurfaceID: [NavEdge]]
    /// 节点几何与边集合的哈希。只在同一进程内比较有意义；变化时调用方重建并校验路线（Requirement 12.1、12.9）。
    public var topologyHash: Int

    /// 端点比较的容差（pt），吸收浮点误差。
    public static let epsilon = 1e-6

    /// 小跳、往下跳的固定代价（design.md）。
    public static let smallJumpCost = 8.0
    public static let dropCost = 12.0

    public init(nodes: [SurfaceID: Surface], edges: [SurfaceID: [NavEdge]]) {
        self.nodes = nodes
        self.edges = edges
        var h = Hasher()
        for id in nodes.keys.sorted() {
            h.combine(nodes[id])
            h.combine(edges[id] ?? [])
        }
        self.topologyHash = h.finalize()
    }

    /// 全部边，按确定性顺序。
    public var allEdges: [NavEdge] {
        nodes.keys.sorted().flatMap { edges[$0] ?? [] }
    }

    public func contains(_ edge: NavEdge) -> Bool {
        edges[edge.from]?.contains(edge) ?? false
    }

    // MARK: 建图

    /// 按五条规则建边。
    ///
    /// - `surfaces`：Ground、Window_Ledge 和已架设 Plank 的 Surface（`SurfaceBuilder.build` 的输出）。
    /// - `planks`：已架设木板，用于把 Plank Surface 的两端对应到所属窗口的 Window_Ledge；
    ///   未提供某块木板时按几何匹配（端点落在哪条同 y 的 Window_Ledge 上）。
    /// - `ladders`：已架设梯子；两端 Surface 不在 `surfaces` 中的梯子被忽略。
    public static func build(
        surfaces: [Surface],
        planks: [PlacedPlank] = [],
        ladders: [NavLadder] = [],
        constants: Tunables
    ) -> NavGraph {
        let eps = epsilon
        var nodes: [SurfaceID: Surface] = [:]
        for s in surfaces { nodes[s.id] = s }
        let list = nodes.keys.sorted().compactMap { nodes[$0] }
        var out: [NavEdge] = []

        // walk 与 smallJump：A 的右端点与 B 的左端点配对（遍历全部有序对即覆盖「或反之」）。
        for a in list {
            for b in list where a.id != b.id {
                let p = a.end, q = b.start
                let dy = abs(q.y - p.y)
                let dx = q.x - p.x
                if dy <= eps {
                    // 首尾相接或重叠：B 的左端点落在 A 的范围内。
                    if dx <= eps, q.x >= a.start.x - eps {
                        let exitOnA = Point(x: q.x, y: a.y(atX: q.x))
                        out.append(NavEdge(from: a.id, to: b.id, kind: .walk, exit: exitOnA, entry: q, cost: 0))
                        out.append(NavEdge(from: b.id, to: a.id, kind: .walk, exit: q, entry: exitOnA, cost: 0))
                    }
                } else if dy <= constants.smallJumpMaxRise + eps, abs(dx) <= constants.smallJumpMaxGap + eps {
                    out.append(NavEdge(from: a.id, to: b.id, kind: .smallJump, exit: p, entry: q, cost: smallJumpCost))
                    out.append(NavEdge(from: b.id, to: a.id, kind: .smallJump, exit: q, entry: p, cost: smallJumpCost))
                }
            }
        }

        // drop：较高 Surface 的每个端点，正下方最近的 Surface（与 Physics 落地规则一致：最高者，并列取 SurfaceID 较小者）。
        for h in list {
            for p in [h.start, h.end] {
                guard let (low, ly) = nearestBelow(p, excluding: h.id, in: list) else { continue }
                let rise = ly - p.y
                guard rise > eps, rise <= constants.dropMaxHeight + eps else { continue }
                out.append(NavEdge(from: h.id, to: low.id, kind: .drop,
                                   exit: p, entry: Point(x: p.x, y: ly), cost: dropCost))
            }
        }

        // plank：Plank Surface 与两端所在 Window_Ledge。每条边代价为木板长度的一半，过一次桥合计为木板长度。
        let plankByID = Dictionary(planks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for ps in list {
            guard let pid = ps.id.plankID else { continue }
            let windowsOfPlank = plankByID[pid].map { Set([$0.endA.window, $0.endB.window]) }
            let span = hypot(ps.end.x - ps.start.x, ps.end.y - ps.start.y)
            func candidates(_ p: Point) -> [Surface] {
                list.filter { s in
                    guard let w = s.id.windowID else { return false }
                    if let ws = windowsOfPlank, !ws.contains(w) { return false }
                    return abs(s.start.y - p.y) <= eps
                        && p.x >= s.start.x - eps && p.x <= s.end.x + eps
                }
            }
            let startCandidates = candidates(ps.start), endCandidates = candidates(ps.end)
            // 端点恰好落在两扇窗沿相接处时可能同时匹配两个窗口；木板两端属于不同窗口，
            // 因此优先选两端窗口不同的组合，使每端连到自己 Attachment 所在窗口的窗沿（Requirement 12.5）。
            var pair: (Surface?, Surface?) = (startCandidates.first, endCandidates.first)
            if windowsOfPlank != nil,
               let distinct = startCandidates.lazy.compactMap({ ls in
                   endCandidates.first { $0.id.windowID != ls.id.windowID }.map { (ls, $0) }
               }).first {
                pair = (distinct.0, distinct.1)
            }
            for (p, ledge) in [(ps.start, pair.0), (ps.end, pair.1)] {
                guard let ledge else { continue }
                out.append(NavEdge(from: ledge.id, to: ps.id, kind: .plank, exit: p, entry: p, cost: span / 2))
                out.append(NavEdge(from: ps.id, to: ledge.id, kind: .plank, exit: p, entry: p, cost: span / 2))
            }
        }

        // ladder：下端 Surface 与上端 Window_Ledge，代价为竖直距离。
        for l in ladders.sorted(by: { $0.id < $1.id }) {
            guard nodes[l.bottomSurface] != nil, nodes[l.topSurface] != nil,
                  l.bottomSurface != l.topSurface else { continue }
            let height = abs(l.bottom.y - l.top.y)
            out.append(NavEdge(from: l.bottomSurface, to: l.topSurface, kind: .ladder(l.id),
                               exit: l.bottom, entry: l.top, cost: height))
            out.append(NavEdge(from: l.topSurface, to: l.bottomSurface, kind: .ladder(l.id),
                               exit: l.top, entry: l.bottom, cost: height))
        }

        var edges: [SurfaceID: [NavEdge]] = [:]
        for e in Set(out).sorted(by: NavEdge.order) {
            edges[e.from, default: []].append(e)
        }
        return NavGraph(nodes: nodes, edges: edges)
    }

    /// 点 `p` 正下方最近的 Surface 及其在 `p.x` 处的 y。
    private static func nearestBelow(_ p: Point, excluding: SurfaceID, in list: [Surface]) -> (Surface, Double)? {
        var best: (Surface, Double)?
        for s in list where s.id != excluding {
            guard p.x >= s.start.x - epsilon, p.x <= s.end.x + epsilon else { continue }
            let sy = s.y(atX: p.x)
            guard sy > p.y + epsilon else { continue }
            if let b = best, !(sy < b.1 || (sy == b.1 && s.id < b.0.id)) { continue }
            best = (s, sy)
        }
        return best
    }

    // MARK: 寻路

    /// 从 `from` 上的 `x` 出发，到 `to` 上的 `targetX` 的最低代价路线；不可达或节点不存在时返回 nil。
    ///
    /// 代价为在各 Surface 上行走的水平距离加上每条边的固定代价。Dijkstra 的状态是「起点」或「经由某条边到达」；
    /// 代价相同时按状态序号（起点最先，其后按确定性边顺序）选取，因此结果确定（Requirement 12.7、12.12）。
    public func route(from: SurfaceID, at x: Double, to: SurfaceID, targetX: Double) -> Route? {
        guard nodes[from] != nil, nodes[to] != nil else { return nil }
        if from == to { return Route(steps: [], targetSurface: to, targetX: targetX) }

        let all = allEdges
        var index: [NavEdge: Int] = [:]
        for (i, e) in all.enumerated() { index[e] = i + 1 }
        // 状态 0：起点；状态 i（i ≥ 1）：经由 all[i-1] 到达其 `to` 的 `entry`。
        let n = all.count + 1
        var dist = [Double](repeating: .infinity, count: n)
        var prev = [Int](repeating: -1, count: n)
        var done = [Bool](repeating: false, count: n)
        dist[0] = 0

        func surfaceAndX(_ s: Int) -> (SurfaceID, Double) {
            s == 0 ? (from, x) : (all[s - 1].to, all[s - 1].entry.x)
        }

        var best: (cost: Double, state: Int)?
        while true {
            var u = -1
            for i in 0..<n where !done[i] && dist[i].isFinite {
                if u < 0 || dist[i] < dist[u] { u = i }
            }
            guard u >= 0 else { break }
            if let b = best, dist[u] >= b.cost { break }
            done[u] = true
            let (sid, sx) = surfaceAndX(u)
            if sid == to {
                let total = dist[u] + abs(targetX - sx)
                if best == nil || total < best!.cost { best = (total, u) }
                continue
            }
            for e in edges[sid] ?? [] {
                guard let v = index[e], !done[v] else { continue }
                let c = dist[u] + abs(e.exit.x - sx) + e.cost
                if c < dist[v] {
                    dist[v] = c
                    prev[v] = u
                }
            }
        }

        guard let b = best else { return nil }
        var steps: [NavEdge] = []
        var s = b.state
        while s > 0 {
            steps.append(all[s - 1])
            s = prev[s]
        }
        return Route(steps: steps.reversed(), targetSurface: to, targetX: targetX)
    }

    /// 从 `from` 是否能到达 `to`（只看连通性，drop 边单向）。
    public func isReachable(from: SurfaceID, to: SurfaceID) -> Bool {
        guard nodes[from] != nil, nodes[to] != nil else { return false }
        var seen: Set<SurfaceID> = [from]
        var queue = [from]
        while let s = queue.popLast() {
            if s == to { return true }
            for e in edges[s] ?? [] where seen.insert(e.to).inserted {
                queue.append(e.to)
            }
        }
        return false
    }

    /// 路线是否仍然有效：剩余步骤的每条边都在图中且首尾相接，最后到达目标 Surface（Requirement 12.9、12.12）。
    public func isValid(_ route: Route, from start: SurfaceID) -> Bool {
        var cur = start
        for e in route.steps {
            guard e.from == cur, contains(e) else { return false }
            cur = e.to
        }
        return cur == route.targetSurface && nodes[cur] != nil
    }
}
