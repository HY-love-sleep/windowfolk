import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// ActivityPlanner 的属性测试（design.md Property 10，任务 5.4；Property 11 由任务 5.5 追加）。
//
// 参考谓词按 Requirement 4.3、5.3 与 design.md 可执行条件表独立写出：
// - 「有路线」用 `NavGraph.isReachable`（只看连通性，同一 Surface 视为可达）。
// - 「最近」「路线最短」用 v1 标准度量：Surface 上的水平行走距离加上每条边的固定代价。参考实现用
//   Bellman-Ford 在「起点」与「经由某条边到达」的状态上独立求最小代价；代价相同时取 ID 较小者。
// 生成器只用水平窗沿、Ground 和梯子，坐标都在 5pt 网格上，代价为整数，并列可精确比较。

/// 一个世界状态。
fileprivate struct ActivityScenario: Sendable, CustomStringConvertible {
    var ctx: ActivityContext
    var surfaces: [Surface]
    var ladders: [NavLadder]

    var description: String {
        let decors = ctx.decors.sortedIDs.compactMap { ctx.decors.decors[$0] }
            .map { "\($0.id.rawValue):\($0.type) \($0.placement) @\(ctx.decorLocations[$0.id].map { "\($0)" } ?? "-")" }
        let items = ctx.items.sortedIDs.compactMap { ctx.items[$0] }
            .map { "\($0.kind) \(String(describing: $0.stage)) \($0.placement) @\(ctx.itemLocations[$0.id].map { "\($0)" } ?? "-")" }
        return "night \(ctx.isNight) locations \(ctx.locations) homes \(ctx.homes) seats \(ctx.seats) "
            + "surfaces \(surfaces.map { "\($0.id) \($0.start.x)-\($0.end.x)@\($0.start.y)" }) "
            + "ladders \(ladders.map { "\($0.bottom.x) \($0.topSurface)" }) decors \(decors) items \(items)"
    }
}

/// 一扇窗口的窗沿参数（20pt 网格）。
fileprivate struct WindowSpec: Sendable {
    var y: Int, x: Int, length: Int, segments: Int, gap: Int, length2: Int
}

/// 一个放在某条 Surface 上的对象的位置参数。
fileprivate struct SpotSpec: Sendable {
    var surface: Int, frac: Int
}

fileprivate let grid = 20.0
fileprivate let groundY = 600.0
/// 没有任何窗沿的 Home_Window。
fileprivate let ledgelessWindow: WindowID = 9

extension Gen where Value == ActivityScenario {
    fileprivate static var activityWorld: Generator<ActivityScenario, some SendableSequenceType> {
        let window = zip(
            Gen<Int>.int(in: 15...29),  // y（y ≥ 480 时与 Ground 之间有 drop 边）
            Gen<Int>.int(in: 0...36),   // 左端 x
            Gen<Int>.int(in: 1...8),    // 第一段长度
            Gen<Int>.int(in: 1...2),    // 段数
            Gen<Int>.int(in: 0...2),    // 两段间隙（0 首尾相接）
            Gen<Int>.int(in: 1...6)     // 第二段长度
        ).map { WindowSpec(y: $0, x: $1, length: $2, segments: $3, gap: $4, length2: $5) }
        let spot = zip(Gen<Int>.int(in: 0...63), Gen<Int>.int(in: 0...4)).map { SpotSpec(surface: $0, frac: $1) }

        // 居民：0 表示不可定位（falling、hanging 等），Home：0 无、5 为无窗沿的窗口，其余按窗口下标取。
        let resident = zip(Gen<Int>.int(in: 0...3), spot, Gen<Int>.int(in: 0...5), Gen<Int>.int(in: 0...4))
        // Decor：是否 Lamp、放置方式（0、1 附着，2 拖动，3 下落）、位置模式、位置。
        let decor = zip(Gen<Bool>.bool, Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...4), spot)
        // Item：种类（0、1 Story_Flower，2 普通花，3 果子）、阶段、放置方式（0、1 附着，2 持有，3 拖动）、位置模式、位置。
        // 阶段 2、3 都是 bloom，提高 admire_flower 的覆盖。
        let item = zip(Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...3),
                       Gen<Int>.int(in: 0...4), spot)

        return zip(
            window.array(of: 1...4),
            spot.array(of: 0...4),          // 梯子：上端窗沿与位置
            resident.array(of: 2),
            decor.array(of: 0...5),
            item.array(of: 0...4),
            Gen<Bool>.bool
        ).map { windows, ladderSpecs, residents, decorSpecs, itemSpecs, isNight in
            let k = Tunables()
            var surfaces = [Surface(id: .ground, start: Point(x: 0, y: groundY), end: Point(x: 800, y: groundY))]
            for (i, w) in windows.enumerated() {
                let wid = WindowID(i + 1), y = Double(w.y) * grid
                let x0 = Double(w.x) * grid, x1 = x0 + Double(w.length) * grid
                surfaces.append(Surface(id: .ledge(wid, index: 0), start: Point(x: x0, y: y), end: Point(x: x1, y: y)))
                if w.segments == 2 {
                    let x2 = x1 + Double(w.gap) * grid
                    surfaces.append(Surface(id: .ledge(wid, index: 1), start: Point(x: x2, y: y),
                                            end: Point(x: x2 + Double(w.length2) * grid, y: y)))
                }
            }
            let ledges = surfaces.filter { $0.id != .ground }

            func point(_ s: SpotSpec, in list: [Surface]) -> ResidentLocation {
                let sf = list[s.surface % list.count]
                return ResidentLocation(surface: sf.id,
                                        x: sf.start.x + (sf.end.x - sf.start.x) * Double(s.frac) / 4)
            }

            // 梯子只在上端窗沿位于 Ground 范围内时有意义；Ground 覆盖 [0, 800]。
            var ladders: [NavLadder] = []
            for (i, s) in ladderSpecs.enumerated() {
                let top = point(s, in: ledges)
                guard top.x <= 800, let sf = ledges.first(where: { $0.id == top.surface }) else { continue }
                ladders.append(NavLadder(id: LadderID(UInt64(i + 1)), bottomSurface: .ground,
                                         bottom: Point(x: top.x, y: groundY),
                                         topSurface: top.surface, top: Point(x: top.x, y: sf.start.y)))
            }
            let nav = NavGraph.build(surfaces: surfaces, ladders: ladders, constants: k)

            var locations: [ResidentID: ResidentLocation] = [:]
            var homes: [ResidentID: WindowID] = [:]
            for (rid, r) in zip(ResidentID.allCases, residents) {
                if r.0 > 0 { locations[rid] = point(r.1, in: surfaces) }
                switch r.2 {
                case 0: break
                case 5: homes[rid] = ledgelessWindow
                default: homes[rid] = WindowID((r.2 - 1) % windows.count + 1)
                }
            }

            var decors: [DecorID: Decor] = [:]
            var decorLocations: [DecorID: ResidentLocation] = [:]
            for (i, d) in decorSpecs.enumerated() {
                let did = DecorID(UInt64(i + 1))
                let loc = point(d.3, in: surfaces)
                let placement: DecorPlacement
                switch d.1 {
                case 0, 1: placement = .attached(.ground(x: loc.x))
                case 2: placement = .dragged(grabOffset: Point(x: 0, y: 0), fresh: false)
                default: placement = .falling(FallState(position: Point(x: loc.x, y: 0)), byPlayer: true)
                }
                decors[did] = Decor(id: did, type: d.0 ? .lamp : .chair, placement: placement)
                // 附着的大多可定位（0 表示在 Hidden_Window 上）；未附着的偶尔仍带旧位置，检验放置方式也被检查。
                let attached = d.1 <= 1
                if attached ? d.2 > 0 : d.2 == 4 { decorLocations[did] = loc }
            }

            // 坐着的居民占用某把 Chair（r.3 选 Chair 下标，0 不坐）；同一把 Chair 只给一位。
            let chairIDs = decors.keys.sorted().filter { decors[$0]?.type == .chair }
            var seats: [ResidentID: DecorID] = [:]
            for (rid, r) in zip(ResidentID.allCases, residents) where r.3 > 0 && !chairIDs.isEmpty {
                let c = chairIDs[(r.3 - 1) % chairIDs.count]
                if !seats.values.contains(c) { seats[rid] = c }
            }

            var items: [ItemID: Item] = [:]
            var itemLocations: [ItemID: ResidentLocation] = [:]
            for (i, s) in itemSpecs.enumerated() {
                let iid = ItemID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i + 1))!)
                let loc = point(s.4, in: surfaces)
                let kind: ItemKind = switch s.0 {
                case 0: .flower(storyRound: 1)
                case 1: .flower(storyRound: 2)
                case 2: .flower(storyRound: nil)
                default: .fruit
                }
                let placement: ItemPlacement = switch s.2 {
                case 0, 1: .attached(.ground(x: loc.x))
                case 2: .held(.a)
                default: .dragged(grabOffset: Point(x: 0, y: 0))
                }
                let growth = kind.isFlower
                    ? FlowerGrowth(plantedAt: Date(timeIntervalSince1970: 0), reached: GrowthStage(rawValue: min(s.1, 2))!)
                    : nil
                items[iid] = Item(id: iid, kind: kind, placement: placement, growth: growth)
                let attached = s.2 <= 1
                if attached ? s.3 > 0 : s.3 == 4 { itemLocations[iid] = loc }
            }

            let ctx = ActivityContext(
                nav: nav, locations: locations, decors: DecorStore(decors: decors), seats: seats,
                items: ItemStore(items: items), homes: homes, isNight: isNight,
                now: Date(timeIntervalSince1970: 1_000_000), constants: k,
                decorLocations: decorLocations, itemLocations: itemLocations)
            return ActivityScenario(ctx: ctx, surfaces: surfaces, ladders: ladders)
        }
    }
}

// MARK: - 参考谓词

/// 标准度量下从 `from` 到 `to` 的最小代价（独立于 `NavGraph.route` 的 Bellman-Ford）；不可达时为 nil。
fileprivate func referenceCost(from: ResidentLocation, to: ResidentLocation, nav: NavGraph) -> Double? {
    guard nav.nodes[from.surface] != nil, nav.nodes[to.surface] != nil else { return nil }
    let all = nav.allEdges
    var dist = [Double](repeating: .infinity, count: all.count)
    for _ in 0...all.count {
        var changed = false
        for (i, e) in all.enumerated() {
            var best = dist[i]
            if e.from == from.surface { best = min(best, abs(e.exit.x - from.x) + e.cost) }
            for (j, p) in all.enumerated() where p.to == e.from && dist[j].isFinite {
                best = min(best, dist[j] + abs(e.exit.x - p.entry.x) + e.cost)
            }
            if best < dist[i] {
                dist[i] = best
                changed = true
            }
        }
        if !changed { break }
    }
    var out: Double? = from.surface == to.surface ? abs(to.x - from.x) : nil
    for (j, p) in all.enumerated() where p.to == to.surface && dist[j].isFinite {
        let c = dist[j] + abs(to.x - p.entry.x)
        if out == nil || c < out! { out = c }
    }
    return out
}

/// 有路线的候选中代价最小者；并列取 ID 较小者。
fileprivate func referenceNearest<ID: Comparable>(
    _ candidates: [(ID, ResidentLocation)], from: ResidentLocation, nav: NavGraph
) -> ID? {
    var best: (id: ID, cost: Double)?
    for (cid, loc) in candidates where nav.isReachable(from: from.surface, to: loc.surface) {
        guard let cost = referenceCost(from: from, to: loc, nav: nav) else { continue }
        if let b = best, b.cost < cost || (b.cost == cost && b.id < cid) { continue }
        best = (cid, cost)
    }
    return best?.id
}

/// 按 Requirement 4.3、5.3 写出的可执行集合。
fileprivate func referenceExecutable(_ id: ResidentID, ctx: ActivityContext) -> [ActivityKind: ActivityTarget] {
    var out: [ActivityKind: ActivityTarget] = [.wander: ActivityTarget.none]
    guard let me = ctx.locations[id] else { return out }
    let nav = ctx.nav

    // go_home：有 Home_Window、不在其任一段窗沿上、能到其中一段。
    if let home = ctx.homes[id], me.surface.windowID != home,
       nav.nodes.keys.contains(where: { $0.windowID == home && nav.isReachable(from: me.surface, to: $0) }) {
        out[.goHome] = .home(home)
    }

    // visit_neighbor：另一位可定位（不处于 falling、hanging），能到其 Surface。
    if let o = ctx.locations[id.other], nav.isReachable(from: me.surface, to: o.surface) {
        out[.visitNeighbor] = .resident(id.other)
    }

    let occupied = Set(ctx.seats.values)
    func attachedDecors(_ t: DecorType) -> [(DecorID, ResidentLocation)] {
        ctx.decors.decors.values.compactMap { d in
            guard d.type == t, case .attached = d.placement, let loc = ctx.decorLocations[d.id] else { return nil }
            return (d.id, loc)
        }
    }

    // rest：未被占用、附着（不拖动、不下落）的 Chair。
    let chairs = attachedDecors(.chair).filter { !occupied.contains($0.0) }
    if let c = referenceNearest(chairs, from: me, nav: nav) { out[.rest] = .chair(c) }

    // admire_flower：附着、bloom 的 Story_Flower。
    let flowers = ctx.items.items.values.compactMap { it -> (ItemID, ResidentLocation)? in
        guard case .flower(storyRound: .some) = it.kind, it.growth?.reached == .bloom,
              case .attached = it.placement, let loc = ctx.itemLocations[it.id] else { return nil }
        return (it.id, loc)
    }
    if let f = referenceNearest(flowers, from: me, nav: nav) { out[.admireFlower] = .flower(f) }

    // sleep（Requirement 5.3）：Night，附着的 Lamp 中路线最短者。
    if ctx.isNight, let l = referenceNearest(attachedDecors(.lamp), from: me, nav: nav) {
        out[.sleep] = .lamp(l)
    }
    return out
}

@Suite("ActivityPlanner 属性测试")
struct ActivityPlannerTests {
    // Feature: V2, Property 10: Activity 可执行判定
    /// **Validates: Requirements 4.3, 5.3**
    @Test func executableMatchesReference() async {
        await propertyCheck(count: 200, input: Gen<ActivityScenario>.activityWorld) { sc in
            for rid in ResidentID.allCases {
                let got = ActivityPlanner.executable(rid, ctx: sc.ctx)
                let want = referenceExecutable(rid, ctx: sc.ctx)
                #expect(got == want, "resident \(rid)")
            }
        }
    }

    // Feature: V2, Property 11: Activity 选择
    /// **Validates: Requirements 4.4, 4.5, 4.6, 4.15**
    @Test func chooseFollowsWeightedRule() async {
        #expect(ActivityKind.allCases.allSatisfy { (ActivityPlanner.weights[$0] ?? 0) > 0 })
        await propertyCheck(count: 200, input: Gen<ActivityScenario>.activityWorld, Gen<UInt64>.uint64()) { sc, seed in
            let ctx = sc.ctx, k = ctx.constants
            for rid in ResidentID.allCases {
                var rng = RandomSource(seed: seed)
                let got = ActivityPlanner.choose(rid, ctx: ctx, rng: &rng)
                let want = referenceChoice(rid, ctx: ctx, seed: seed)
                let exec = referenceExecutable(rid, ctx: ctx)

                // 选出的 Activity 属于可执行集合，目标与可执行判定一致。
                #expect(exec[got.kind] != nil, "resident \(rid) chose \(got.kind)")
                #expect(got.target == exec[got.kind], "resident \(rid)")
                #expect(got.startedAt == ctx.now && got.phase == .moving, "resident \(rid)")

                // Night 且 sleep 可执行时一定选 sleep，且不消耗随机数（Requirement 4.4）。
                if ctx.isNight, exec[.sleep] != nil {
                    #expect(got.kind == .sleep, "resident \(rid)")
                    #expect(rng == RandomSource(seed: seed), "resident \(rid)")
                }

                // 加权随机选择与参考一致，随机数消耗也一致（Requirement 4.5、4.15）。
                #expect(got.kind == want.kind, "resident \(rid)")
                #expect(rng == want.rng, "resident \(rid)")

                // wander 的时长在闭区间内，并与参考抽取一致（Requirement 4.6）。
                if got.kind == .wander {
                    let d = got.wanderUntil.map { $0.timeIntervalSince(ctx.now) }
                    #expect(d.map { $0 >= k.activityMinDuration && $0 <= k.activityMaxDuration } == true,
                            "resident \(rid) duration \(String(describing: d))")
                    #expect(d.map { abs($0 - (want.duration ?? -1)) < 1e-6 } == true, "resident \(rid)")
                    #expect(got.surface == ctx.locations[rid]?.surface, "resident \(rid)")
                } else {
                    #expect(got.wanderUntil == nil, "resident \(rid)")
                }

                // 同一种子、同一状态再调用一次，结果和随机源状态都相同（确定性）。
                var rng2 = RandomSource(seed: seed)
                let again = ActivityPlanner.choose(rid, ctx: ctx, rng: &rng2)
                #expect(again == got && rng2 == rng, "resident \(rid)")
            }
        }
    }
}

/// 按 Requirement 4.4、4.5、4.6、4.15 写出的参考选择：Night 且 sleep 可执行时直接选 sleep；否则一次
/// `nextUnit()` 在可执行集合中按 `ActivityKind.allCases` 顺序累加权重；选中 wander 时再抽一次时长。
fileprivate func referenceChoice(
    _ id: ResidentID, ctx: ActivityContext, seed: UInt64
) -> (kind: ActivityKind, duration: Double?, rng: RandomSource) {
    var rng = RandomSource(seed: seed)
    let exec = referenceExecutable(id, ctx: ctx)
    if ctx.isNight, exec[.sleep] != nil { return (.sleep, nil, rng) }

    let candidates = ActivityKind.allCases.filter { exec[$0] != nil }
    let weight = { (k: ActivityKind) in ActivityPlanner.weights[k]! }
    let total = candidates.map(weight).reduce(0, +)
    let u = rng.nextUnit() * total
    var acc = 0.0
    var kind = candidates.last!
    for c in candidates {
        acc += weight(c)
        if u < acc {
            kind = c
            break
        }
    }
    guard kind == .wander else { return (kind, nil, rng) }
    let lo = ctx.constants.activityMinDuration, hi = ctx.constants.activityMaxDuration
    return (kind, lo + (hi - lo) * rng.nextUnit(), rng)
}
