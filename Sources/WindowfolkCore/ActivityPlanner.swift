import Foundation

// ActivityPlanner 的可执行判定与选择（design.md「Core：ActivityPlanner」，任务 5.3）。
//
// 全部为纯函数：输入只有 `ActivityContext` 和注入的 `RandomSource`，同样的种子和状态得到同样的结果
// （Requirement 4.5、4.15、19.3）。推进（plan / resolve）由任务 5.6 实现。
//
// 「有路线」指 Nav_Graph 中存在从居民当前位置到目标所在 Surface 的路线（同一 Surface 视为有路线）。
// 多个目标比较远近时用标准度量（v1 寻路代价：Surface 上的水平行走距离加上每条边的固定代价），
// 与居民实际行走的路线一致；代价相同时取 ID 较小者。

public enum ActivityPlanner {
    /// 各 Activity 的权重，都大于 0（Requirement 4.5）。
    public static let weights: [ActivityKind: Double] = [
        .wander: 4, .goHome: 2, .visitNeighbor: 2, .rest: 2, .admireFlower: 1, .sleep: 1,
    ]

    // MARK: - 可执行判定（Requirement 4.3、5.3）

    /// 居民 `id` 当前可执行的 Activity 及其目标。`wander` 始终在其中。
    public static func executable(_ id: ResidentID, ctx: ActivityContext) -> [ActivityKind: ActivityTarget] {
        var out: [ActivityKind: ActivityTarget] = [.wander: ActivityTarget.none]
        guard let me = ctx.locations[id] else { return out }

        // go_home：有 Home_Window，不在其任一段窗沿上，有路线到其中一段。
        if let home = ctx.homes[id], me.surface.windowID != home {
            let ledges = ctx.nav.nodes.keys.filter { $0.windowID == home }
            if ledges.contains(where: { hasRoute(from: me, to: $0, ctx: ctx) }) {
                out[.goHome] = .home(home)
            }
        }

        // visit_neighbor：另一位不在 falling、hanging（在 locations 中），有路线到其 Surface。
        let other = id.other
        if let ol = ctx.locations[other], hasRoute(from: me, to: ol.surface, ctx: ctx) {
            out[.visitNeighbor] = .resident(other)
        }

        // rest：空闲 Chair（附着、未被占用）中标准度量下最近的一把。
        let chairs = ctx.decors.sortedIDs.compactMap { did -> (DecorID, ResidentLocation)? in
            guard let d = ctx.decors.decors[did], DecorRules.isFreeChair(d, seats: ctx.seats),
                  let loc = ctx.decorLocations[did] else { return nil }
            return (did, loc)
        }
        if let c = nearest(chairs, from: me, ctx: ctx) { out[.rest] = .chair(c) }

        // admire_flower：bloom 的 Story_Flower 中最近的一朵。
        let flowers = ctx.items.sortedIDs.compactMap { iid -> (ItemID, ResidentLocation)? in
            guard let it = ctx.items[iid], it.kind.isStoryFlower, it.stage == .bloom,
                  case .attached = it.placement, let loc = ctx.itemLocations[iid] else { return nil }
            return (iid, loc)
        }
        if let f = nearest(flowers, from: me, ctx: ctx) { out[.admireFlower] = .flower(f) }

        // sleep：Night，放在 Surface 上（不拖动、不下落）的 Lamp 中路线最短的一盏。
        if ctx.isNight {
            let lamps = ctx.decors.sortedIDs.compactMap { did -> (DecorID, ResidentLocation)? in
                guard let d = ctx.decors.decors[did], d.type == .lamp, case .attached = d.placement,
                      let loc = ctx.decorLocations[did] else { return nil }
                return (did, loc)
            }
            if let l = nearest(lamps, from: me, ctx: ctx) { out[.sleep] = .lamp(l) }
        }
        return out
    }

    // MARK: - 选择（Requirement 4.4、4.5、4.6、4.15、9.8）

    /// 为居民 `id` 选出下一个 Activity，`startedAt = ctx.now`，阶段 `moving`。
    ///
    /// - Night 且 `sleep` 可执行时直接选 `sleep`，不消耗随机数（Requirement 4.4）。
    /// - 否则在可执行集合中按 `weights` 加权随机，用一次 `rng.nextUnit()`，候选按 `ActivityKind.allCases`
    ///   的固定顺序累加权重（Requirement 4.5、4.15）。`preferHome` 中的居民：`go_home` 可执行时必在候选中，
    ///   权重不变（Requirement 9.8）；可执行集合本身已保证这一点。
    /// - 选中 `wander` 时再用一次 `rng.double(in:)` 抽取 [Activity_Min_Duration, Activity_Max_Duration] 内的时长
    ///   （Requirement 4.6）。
    public static func choose(_ id: ResidentID, ctx: ActivityContext, rng: inout RandomSource) -> Activity {
        let exec = executable(id, ctx: ctx)
        if ctx.isNight, let lamp = exec[.sleep] {
            return Activity(kind: .sleep, target: lamp, startedAt: ctx.now)
        }

        let candidates = ActivityKind.allCases.filter { exec[$0] != nil }
        let total = candidates.reduce(0) { $0 + (weights[$1] ?? 0) }
        let u = rng.nextUnit() * total
        var acc = 0.0
        var kind = candidates.last ?? .wander
        for k in candidates {
            acc += weights[k] ?? 0
            if u < acc {
                kind = k
                break
            }
        }

        let target = exec[kind] ?? .none
        if kind == .wander {
            let c = ctx.constants
            let duration = rng.double(in: c.activityMinDuration, c.activityMaxDuration)
            return Activity(
                kind: .wander, target: .none, startedAt: ctx.now,
                wanderUntil: ctx.now.addingTimeInterval(duration), surface: ctx.locations[id]?.surface)
        }
        return Activity(kind: kind, target: target, startedAt: ctx.now)
    }

    // MARK: - 路线辅助

    /// 从 `from` 是否有路线到 Surface `to`。
    static func hasRoute(from: ResidentLocation, to: SurfaceID, ctx: ActivityContext) -> Bool {
        ctx.nav.route(from: from.surface, at: from.x, to: to, targetX: from.x) != nil
    }

    /// 标准度量下从 `from` 到 `(to, targetX)` 的路线代价；无路线时为 nil。
    static func standardLength(from: ResidentLocation, to: ResidentLocation, nav: NavGraph) -> Double? {
        guard let route = nav.route(from: from.surface, at: from.x, to: to.surface, targetX: to.x) else {
            return nil
        }
        var x = from.x
        var cost = 0.0
        for e in route.steps {
            cost += abs(e.exit.x - x) + e.cost
            x = e.entry.x
        }
        return cost + abs(to.x - x)
    }

    /// 候选（已按 ID 升序）中有路线且标准代价最小者；代价相同时取先出现（ID 较小）者。
    private static func nearest<ID>(
        _ candidates: [(ID, ResidentLocation)], from: ResidentLocation, ctx: ActivityContext
    ) -> ID? {
        var best: (id: ID, cost: Double)?
        for (cid, loc) in candidates {
            guard let cost = standardLength(from: from, to: loc, nav: ctx.nav) else { continue }
            if best == nil || cost < best!.cost { best = (cid, cost) }
        }
        return best?.id
    }
}
