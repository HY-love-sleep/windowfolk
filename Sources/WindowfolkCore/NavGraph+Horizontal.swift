import Foundation

// MARK: - 路线度量

/// 寻路代价的度量方式。
///
/// - `standard`：v1 度量。Surface 上的水平行走距离加上每条边的固定代价（小跳 8、往下跳 12、木板长度、梯子高度）。
/// - `horizontal`：水平总长度。Surface 上的水平行走距离加上每条边的 `|exit.x - entry.x|`
///   （Requirement 7.2、7.5、9.4、21.2、21.4）。
public enum RouteMetric: Hashable, Sendable {
    case standard
    case horizontal
}

// MARK: - 水平距离场

/// 从一个起点出发、按水平度量的单源最短距离场。
///
/// 到 `(s, x)` 的长度为 `min(起点在 s 时的 |x0 - x|, 经由边 e 到达 s 的 d(e) + |e.entry.x - x|)`。
/// 起点所在 Surface 总是可达，长度为水平距离（Requirement 20.1(d)）。
public struct HorizontalField: Sendable {
    /// 每个可达 Surface 上的到达点：(到达点 x, 到达该点的最短水平总长度)。
    fileprivate var arrivals: [SurfaceID: [(x: Double, d: Double)]]

    fileprivate init(arrivals: [SurfaceID: [(x: Double, d: Double)]]) {
        self.arrivals = arrivals
    }

    /// 到 Surface `s` 上 `x` 处的最短水平总长度；不可达时为 nil。
    public func length(to s: SurfaceID, x: Double) -> Double? {
        guard let list = arrivals[s], !list.isEmpty else { return nil }
        return list.map { $0.d + abs($0.x - x) }.min()
    }

    /// Surface `s` 是否可达。
    public func isReachable(_ s: SurfaceID) -> Bool {
        !(arrivals[s]?.isEmpty ?? true)
    }
}

// MARK: - NavGraph 扩展

extension NavGraph {
    /// 按指定度量寻路。`.standard` 与 v1 的 `route(from:at:to:targetX:)` 完全相同；
    /// `.horizontal` 返回水平总长度最短的路线，长度相同时按状态序号（起点最先，其后按确定性边顺序）选取。
    public func route(from: SurfaceID, at x: Double, to: SurfaceID, targetX: Double, metric: RouteMetric) -> Route? {
        switch metric {
        case .standard:
            return route(from: from, at: x, to: to, targetX: targetX)
        case .horizontal:
            guard nodes[from] != nil, nodes[to] != nil else { return nil }
            if from == to { return Route(steps: [], targetSurface: to, targetX: targetX) }
            let search = horizontalSearch(from: from, at: x)
            var best: (cost: Double, state: Int)?
            for s in 0..<search.dist.count where search.dist[s].isFinite {
                let (sid, sx) = search.surfaceAndX(s)
                guard sid == to else { continue }
                let total = search.dist[s] + abs(targetX - sx)
                if best == nil || total < best!.cost { best = (total, s) }
            }
            guard let b = best else { return nil }
            var steps: [NavEdge] = []
            var s = b.state
            while s > 0 {
                steps.append(search.all[s - 1])
                s = search.prev[s]
            }
            return Route(steps: steps.reversed(), targetSurface: to, targetX: targetX)
        }
    }

    /// 从 `from` 上的 `x` 出发、按水平度量的单源最短距离场。`from` 不在图中时任何 Surface 都不可达。
    public func horizontalField(from: SurfaceID, at x: Double) -> HorizontalField {
        guard nodes[from] != nil else { return HorizontalField(arrivals: [:]) }
        let search = horizontalSearch(from: from, at: x)
        var arrivals: [SurfaceID: [(x: Double, d: Double)]] = [:]
        for s in 0..<search.dist.count where search.dist[s].isFinite {
            let (sid, sx) = search.surfaceAndX(s)
            arrivals[sid, default: []].append((sx, search.dist[s]))
        }
        return HorizontalField(arrivals: arrivals)
    }

    /// 水平度量下的完整 Dijkstra。状态与 v1 `route` 相同：状态 0 为起点，状态 i（i ≥ 1）为经由 `all[i-1]` 到达其 `entry`。
    private func horizontalSearch(from: SurfaceID, at x: Double) -> HorizontalSearch {
        let all = allEdges
        var index: [NavEdge: Int] = [:]
        for (i, e) in all.enumerated() { index[e] = i + 1 }
        let n = all.count + 1
        var dist = [Double](repeating: .infinity, count: n)
        var prev = [Int](repeating: -1, count: n)
        var done = [Bool](repeating: false, count: n)
        dist[0] = 0
        let search = HorizontalSearch(from: from, x: x, all: all, dist: [], prev: [])

        while true {
            var u = -1
            for i in 0..<n where !done[i] && dist[i].isFinite {
                if u < 0 || dist[i] < dist[u] { u = i }
            }
            guard u >= 0 else { break }
            done[u] = true
            let (sid, sx) = search.surfaceAndX(u)
            for e in edges[sid] ?? [] {
                guard let v = index[e], !done[v] else { continue }
                let c = dist[u] + abs(e.exit.x - sx) + abs(e.entry.x - e.exit.x)
                if c < dist[v] {
                    dist[v] = c
                    prev[v] = u
                }
            }
        }
        return HorizontalSearch(from: from, x: x, all: all, dist: dist, prev: prev)
    }
}

/// `horizontalSearch` 的结果。
private struct HorizontalSearch {
    var from: SurfaceID
    var x: Double
    var all: [NavEdge]
    var dist: [Double]
    var prev: [Int]

    func surfaceAndX(_ s: Int) -> (SurfaceID, Double) {
        s == 0 ? (from, x) : (all[s - 1].to, all[s - 1].entry.x)
    }
}
