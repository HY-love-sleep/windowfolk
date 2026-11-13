import PropertyBased
import Testing
@testable import WindowfolkCore

/// 一个随机世界：可见窗口、木板、梯子，加上起点和查询点的选择参数。
fileprivate struct HorizontalWorld: Sendable {
    var windows: [WindowSnapshot]
    var screen: ScreenInfo
    var plankSpecs: [NavGraphTests.PlankSpec]
    var ladderSpecs: [NavGraphTests.LadderSpec]
    var startIndex: Int
    var startFrac: Double
    var targetIndex: Int
    var targetFrac: Double
}

fileprivate extension Gen where Value == HorizontalWorld {
    /// 复用 v1 的窗口布局、木板和梯子生成器。
    static var horizontalWorld: Generator<HorizontalWorld, some SendableSequenceType> {
        zip(
            Gen<[WindowSnapshot]>.windowLayout,
            Gen<ScreenInfo>.screen,
            NavGraphTests.plankSpecs,
            NavGraphTests.ladderSpecs,
            Gen<Int>.int(in: 0...999),
            Gen<Double>.double(in: 0...1),
            Gen<Int>.int(in: 0...999),
            Gen<Double>.double(in: 0...1)
        ).map {
            HorizontalWorld(windows: $0, screen: $1, plankSpecs: $2, ladderSpecs: $3,
                            startIndex: $4, startFrac: $5, targetIndex: $6, targetFrac: $7)
        }
    }
}

struct NavGraphHorizontalTests {
    /// 参考实现：以「起点」和每条边的离开点、到达点为结点，同一 Surface 上的任意两点之间代价为水平距离，
    /// 每条边从离开点到到达点的代价为 |entry.x − exit.x|；反复松弛直到不动点（Bellman–Ford）。
    /// 返回每个 Surface 上的可达点 (x, d)。
    fileprivate static func referenceArrivals(_ g: NavGraph, from: SurfaceID, at x: Double) -> [SurfaceID: [(x: Double, d: Double)]] {
        guard g.nodes[from] != nil else { return [:] }
        let edges = g.allEdges
        // 结点 0：起点；结点 2i+1：边 i 的离开点；结点 2i+2：边 i 的到达点。
        var surface: [SurfaceID] = [from]
        var px: [Double] = [x]
        for e in edges {
            surface.append(e.from); px.append(e.exit.x)
            surface.append(e.to); px.append(e.entry.x)
        }
        var bySurface: [SurfaceID: [Int]] = [:]
        for (i, s) in surface.enumerated() { bySurface[s, default: []].append(i) }

        var d = [Double](repeating: .infinity, count: surface.count)
        d[0] = 0
        var changed = true
        while changed {
            changed = false
            for group in bySurface.values {
                for a in group where d[a].isFinite {
                    for b in group {
                        let c = d[a] + abs(px[a] - px[b])
                        if c < d[b] - 1e-12 { d[b] = c; changed = true }
                    }
                }
            }
            for i in edges.indices where d[2 * i + 1].isFinite {
                let c = d[2 * i + 1] + abs(px[2 * i + 2] - px[2 * i + 1])
                if c < d[2 * i + 2] - 1e-12 { d[2 * i + 2] = c; changed = true }
            }
        }
        var result: [SurfaceID: [(x: Double, d: Double)]] = [:]
        for i in d.indices where d[i].isFinite { result[surface[i], default: []].append((px[i], d[i])) }
        return result
    }

    fileprivate static func referenceLength(_ arrivals: [SurfaceID: [(x: Double, d: Double)]], to s: SurfaceID, x: Double) -> Double? {
        arrivals[s]?.map { $0.d + abs($0.x - x) }.min()
    }

    /// 路线的水平总长度：起点到首个离开点、各边水平距离、相邻边之间的行走距离、最后一个到达点到 targetX。
    fileprivate static func horizontalLength(_ r: Route, from x: Double) -> Double {
        var total = 0.0
        var cur = x
        for e in r.steps {
            total += abs(e.exit.x - cur) + abs(e.entry.x - e.exit.x)
            cur = e.entry.x
        }
        return total + abs(r.targetX - cur)
    }

    fileprivate static func close(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= 1e-6 * max(1, abs(a), abs(b))
    }

    // Feature: V2, Property 26: 水平距离场
    // **Validates: Requirements 9.4, 21.2, 21.4**
    @Test func horizontalFieldMatchesReference() async {
        await propertyCheck(count: 100, input: Gen.horizontalWorld) { w in
            let k = Tunables()
            let planks = NavGraphTests.makePlanks(w.plankSpecs, windows: w.windows)
            let placedLadders = NavGraphTests.makeLadders(w.ladderSpecs, windows: w.windows, screen: w.screen)
            var table = WindowTable()
            for win in w.windows { table.records[win.id] = WindowRecord(snapshot: win, visibility: .visible) }
            let surfaces = SurfaceBuilder.build(windows: w.windows, planks: planks, screen: w.screen)
            let presentPlanks = Set(surfaces.compactMap(\.id.plankID))
            let navPlanks = planks.filter { presentPlanks.contains($0.id) }
            let ladders = placedLadders.compactMap { $0.navLadder(windows: table, surfaces: surfaces) }
            let graph = NavGraph.build(surfaces: surfaces, planks: navPlanks, ladders: ladders, constants: k)

            let start = surfaces[w.startIndex % surfaces.count]
            let x = start.start.x + (start.end.x - start.start.x) * w.startFrac
            let field = graph.horizontalField(from: start.id, at: x)
            let ref = Self.referenceArrivals(graph, from: start.id, at: x)

            // 每个 Surface 上随机一点：长度与参考最小值一致，不可达时都为 nil。
            for s in surfaces {
                let qx = s.start.x + (s.end.x - s.start.x) * w.targetFrac
                let actual = field.length(to: s.id, x: qx)
                let expected = Self.referenceLength(ref, to: s.id, x: qx)
                let ctx = "start \(start.id)@\(x) query \(s.id)@\(qx) planks \(navPlanks.count) ladders \(ladders.count)"
                #expect(field.isReachable(s.id) == (expected != nil), "\(ctx)")
                switch (actual, expected) {
                case (nil, nil): break
                case let (a?, e?): #expect(Self.close(a, e), "length \(a) != reference \(e) \(ctx)")
                default: #expect(Bool(false), "length \(String(describing: actual)) vs reference \(String(describing: expected)) \(ctx)")
                }
            }

            // 约一半的样例从可达的其他 Surface 中选目标，覆盖多步路线。
            let reachableOthers = surfaces.filter { $0.id != start.id && ref[$0.id] != nil }
            let target = w.targetIndex % 2 == 0 && !reachableOthers.isEmpty
                ? reachableOthers[(w.targetIndex / 2) % reachableOthers.count]
                : surfaces[w.targetIndex % surfaces.count]
            let tx = target.start.x + (target.end.x - target.start.x) * w.targetFrac
            let expected = Self.referenceLength(ref, to: target.id, x: tx)
            let route = graph.route(from: start.id, at: x, to: target.id, targetX: tx, metric: .horizontal)
            let ctx = "start \(start.id)@\(x) target \(target.id)@\(tx)"
            #expect((route != nil) == (expected != nil), "route \(route != nil) reference \(expected != nil) \(ctx)")
            if let route, let expected {
                #expect(graph.isValid(route, from: start.id), "invalid route \(ctx)")
                #expect(route.targetSurface == target.id && route.targetX == tx, "\(ctx)")
                let len = Self.horizontalLength(route, from: x)
                #expect(Self.close(len, expected), "route length \(len) != reference \(expected) \(ctx)")
            }
        }
    }
}
