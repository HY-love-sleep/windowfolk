import Foundation

// ActivityPlanner 的推进（design.md「Core：ActivityPlanner」推进规则，任务 5.6）。
//
// 每帧两次调用，都是纯函数，只读 `ActivityContext`、只改传入的居民和 Activity：
// - `plan`（居民移动之前）：结束 Busy_Resident 和 `falling` / `hanging` 居民的 Activity；校验目标、处理放弃和
//   Activity_Reach_Timeout；`wander` 到时结束；为没有 Activity 的居民选出下一个；按 Activity 写 Goal。
// - `resolve`（居民移动之后）：到达判定、坐下与坐满、入睡、拜访停留与被拜访者暂停、赏花停留。
//
// 放弃时居民转为 `idle`、Goal 为 `hold`，不显示任何气泡（Requirement 4.11、5.5）；`plan` 在同一帧为其选出
// 下一个 Activity（Requirement 4.2）。被拜访者的 Activity 在停留期间暂停：开始暂停时把它的全部计时向后平移
// 停留时长，因此暂停期间不推进、不计超时，结束后从暂停处继续（Requirement 4.8）。

extension ActivityPlanner {
    // MARK: - plan（移动之前）

    /// 移动之前推进全部居民的 Activity。`eligible` 为可由 Activity_Planner 控制的居民（不是 Busy_Resident）；
    /// 不在其中但有 Activity 的居民同帧结束 Activity：`sitting` 转 `idle` 并释放 Chair，`sleeping` 转 `idle`
    /// 并产生 `woke(becameBusy)`（Requirement 4.12）。返回本帧事件（按居民 ID 顺序）。
    public static func plan(
        residents: inout [ResidentID: Resident], activities: inout [ResidentID: Activity],
        eligible: Set<ResidentID>, ctx: ActivityContext, rng: inout RandomSource
    ) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        for id in activities.keys.sorted() where residents[id] == nil {
            activities[id] = nil
        }
        // 本帧新成为 Busy_Resident 的被拜访者（仍带着上一帧的 Activity）：拜访停留同帧结束（Requirement 4.12）。
        // 拜访者不写 visited，清除双方因该次拜访显示的心形，拜访者在下面的循环里同帧选出下一个 Activity。
        for host in residents.keys.sorted() where !eligible.contains(host) && activities[host] != nil {
            for v in residents.keys.sorted() where v != host && eligible.contains(v) {
                guard var vr = residents[v], let va = activities[v], case .staying = va.phase,
                      va.target == .resident(host) else { continue }
                if vr.bubble == .heart { vr.bubble = nil }
                if residents[host]?.bubble == .heart { residents[host]?.bubble = nil }
                stopForNext(&vr)
                activities[v] = nil
                residents[v] = vr
            }
        }
        for id in residents.keys.sorted() {
            guard var r = residents[id] else { continue }
            var a = activities[id]

            // Busy_Resident：不保持 Activity（Requirement 4.1、4.12）。
            guard eligible.contains(id) else {
                if a != nil || r.state == .sitting || r.state == .sleeping {
                    if r.state == .sleeping {
                        r.walkDistance = 0
                        events.append(.woke(id, .becameBusy))
                    }
                    endActivity(&r, a, residents: &residents, activities: &activities, eligible: eligible)
                    if r.state == .sitting || r.state == .sleeping { r.state = .idle }
                    r.seat = nil
                    activities[id] = nil
                    residents[id] = r
                }
                continue
            }

            // 下落、悬挂：不保持 Activity（Requirement 4.1、4.11）。睡着时所在 Surface 消失而下落，补写 woke。
            if r.state == .falling || r.state == .hanging {
                dropAirborne(id, &r, residents: &residents, activities: &activities, eligible: eligible,
                             events: &events)
                residents[id] = r
                continue
            }

            if let act = a {
                a = progress(id, &r, act, residents: &residents, activities: &activities, eligible: eligible,
                             ctx: ctx, events: &events)
            }
            if a == nil, r.state != .climbing {
                // 选出下一个 Activity（Requirement 4.2）。爬梯中的居民保留 Activity，只是不重新选择。
                let chosen = choose(id, ctx: ctx, rng: &rng)
                a = progress(id, &r, pausedIfHosting(id, chosen, activities: activities, eligible: eligible,
                                                     now: ctx.now),
                             residents: &residents, activities: &activities, eligible: eligible,
                             ctx: ctx, events: &events)
            }
            activities[id] = a
            residents[id] = r
        }
        return events
    }

    /// 推进一个 Activity 并写 Goal；结束或放弃时返回 nil。
    private static func progress(
        _ id: ResidentID, _ r: inout Resident, _ act: Activity,
        residents: inout [ResidentID: Resident], activities: inout [ResidentID: Activity],
        eligible: Set<ResidentID>, ctx: ActivityContext, events: inout [ActivityEvent]
    ) -> Activity? {
        var a = act
        let now = ctx.now
        let me = ctx.locations[id]

        // 睡着：Night 结束、目标 Lamp 被拖动、收回或下落时醒来（Requirement 5.7、5.8），暂停期间也照常判定。
        if a.phase == .sleeping {
            guard r.state == .sleeping else {
                // 状态被外部改变（不应发生）：结束 Activity。
                endActivity(&r, a, residents: &residents, activities: &activities, eligible: eligible)
                return nil
            }
            var reason: WakeReason?
            if !ctx.isNight {
                reason = .nightEnded
            } else if case let .lamp(l) = a.target, !isPlacedLamp(l, ctx: ctx) {
                reason = .lampMoved
            }
            if let reason {
                wake(&r, reason: reason, events: &events)
                endActivity(&r, a, residents: &residents, activities: &activities, eligible: eligible)
                return nil
            }
            setGoal(&r, .hold(face: nil))
            return a
        }

        // 坐着：被外部改为其他状态（玩家拖动 Chair，Requirement 3.8）时结束 `rest`。
        if case .sitting = a.phase {
            guard r.state == .sitting else {
                r.seat = nil
                endActivity(&r, a, residents: &residents, activities: &activities, eligible: eligible)
                return nil
            }
            setGoal(&r, .hold(face: nil))
            return a
        }

        // 被拜访暂停中：停在原地面朝拜访者（Requirement 4.8）。
        if let until = a.pausedUntil {
            if now < until {
                setGoal(&r, .hold(face: .resident(id.other)))
                return a
            }
            a.pausedUntil = nil
        }

        if case .staying = a.phase {
            switch a.target {
            case let .resident(o):
                // 拜访停留中对方下落或悬挂：提前结束，不写 visited。
                if let other = residents[o], other.state == .falling || other.state == .hanging {
                    endActivity(&r, a, residents: &residents, activities: &activities, eligible: eligible)
                    return nil
                }
                setGoal(&r, .hold(face: .resident(o)))
            default:
                setGoal(&r, .hold(face: nil))
            }
            return a
        }

        // moving
        let c = ctx.constants
        if a.kind == .wander {
            if let until = a.wanderUntil, now >= until {
                endActivity(&r, a, residents: &residents, activities: &activities, eligible: eligible)
                stopForNext(&r)
                return nil
            }
            setGoal(&r, .confined)
            return a
        }

        // Activity_Reach_Timeout（Requirement 4.11、5.5）；时钟回拨时已用时长按 0 处理。
        if max(now.timeIntervalSince(a.startedAt), 0) >= c.activityReachTimeout {
            abandon(&r, a, residents: &residents, activities: &activities, eligible: eligible)
            return nil
        }

        guard let goal = movingGoal(id, r, a, residents: residents, ctx: ctx, me: me) else {
            abandon(&r, a, residents: &residents, activities: &activities, eligible: eligible)
            return nil
        }
        if case .goHome = a.kind, let me, case let .home(w) = a.target, me.surface.windowID == w {
            // 已站在家的窗沿上：到达，结束（Requirement 4.7）。
            endActivity(&r, a, residents: &residents, activities: &activities, eligible: eligible)
            stopForNext(&r)
            return nil
        }
        setGoal(&r, goal)
        return a
    }

    /// `moving` 阶段的 Goal；目标已不可执行时返回 nil（Requirement 4.11、5.5）。
    /// 居民自己当前无法定位（爬梯中、在 Hidden_Window 上）时只检查目标本身，不检查路线。
    private static func movingGoal(
        _ id: ResidentID, _ r: Resident, _ a: Activity, residents: [ResidentID: Resident],
        ctx: ActivityContext, me: ResidentLocation?
    ) -> Goal? {
        let c = ctx.constants
        func routeOK(_ s: SurfaceID) -> Bool {
            guard let me else { return true }
            return hasRoute(from: me, to: s, ctx: ctx)
        }
        switch (a.kind, a.target) {
        case let (.goHome, .home(w)):
            guard ctx.homes[id] == w else { return nil }
            if let me, me.surface.windowID != w {
                let ledges = ctx.nav.nodes.keys.filter { $0.windowID == w }
                guard ledges.contains(where: { hasRoute(from: me, to: $0, ctx: ctx) }) else { return nil }
            }
            return .reachWindow(w)
        case let (.visitNeighbor, .resident(o)):
            guard let other = residents[o], other.state != .falling, other.state != .hanging else { return nil }
            if let ol = ctx.locations[o], !routeOK(ol.surface) { return nil }
            return .reach(o)
        case let (.rest, .chair(ch)):
            guard let d = ctx.decors.decors[ch], d.type == .chair, case .attached = d.placement,
                  !ctx.seats.contains(where: { $0.key != id && $0.value == ch }),
                  let loc = ctx.decorLocations[ch], routeOK(loc.surface) else { return nil }
            return .reachPoint(loc.surface, x: loc.x, arriveWithin: c.giftReachDistance)
        case let (.admireFlower, .flower(f)):
            guard let it = ctx.items[f], it.kind.isStoryFlower, it.stage == .bloom, case .attached = it.placement,
                  let loc = ctx.itemLocations[f], routeOK(loc.surface) else { return nil }
            return .reachPoint(loc.surface, x: loc.x, arriveWithin: c.giftReachDistance)
        case let (.sleep, .lamp(l)):
            guard ctx.isNight, isPlacedLamp(l, ctx: ctx), let loc = ctx.decorLocations[l],
                  routeOK(loc.surface) else { return nil }
            return .reachPoint(loc.surface, x: loc.x, arriveWithin: c.lampRange)
        default:
            return nil
        }
    }

    // MARK: - resolve（移动之后）

    /// 移动之后推进到达判定与停留计时。`ctx` 应按移动之后的位置构造。返回本帧事件。
    public static func resolve(
        residents: inout [ResidentID: Resident], activities: inout [ResidentID: Activity],
        eligible: Set<ResidentID>, ctx: ActivityContext
    ) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        var seats = ctx.seats
        let now = ctx.now
        let c = ctx.constants
        for id in residents.keys.sorted() where eligible.contains(id) {
            guard var r = residents[id], var a = activities[id] else { continue }
            if r.state == .falling || r.state == .hanging { continue }
            if let until = a.pausedUntil, now < until { continue }

            switch a.phase {
            case let .sitting(until):
                // 坐满 Sit_Duration：转 idle，释放 Chair，Walk_Distance 归零，结束 rest（Requirement 4.9）。
                if now >= until, r.state == .sitting {
                    r.state = .idle
                    r.seat = nil
                    seats[id] = nil
                    r.walkDistance = 0
                    activities[id] = nil
                    residents[id] = r
                }
                continue
            case let .staying(until):
                guard now >= until else { continue }
                if case let .resident(o) = a.target {
                    // 拜访停留结束：写 visited，被拜访者从暂停处继续（Requirement 4.8）。
                    events.append(.visited(id, o))
                }
                endActivity(&r, a, residents: &residents, activities: &activities, eligible: eligible)
                activities[id] = nil
                residents[id] = r
                continue
            case .sleeping:
                continue
            case .moving:
                break
            }

            // 前往途中进入 waiting（路线在移动中消失）：放弃，不显示「...」（Requirement 4.11）。
            if r.state == .waiting, a.kind != .wander {
                abandon(&r, a, residents: &residents, activities: &activities, eligible: eligible)
                activities[id] = nil
                residents[id] = r
                continue
            }
            guard r.traversal == nil, let me = ctx.locations[id] else { continue }

            switch (a.kind, a.target) {
            case let (.goHome, .home(w)) where me.surface.windowID == w:
                // 站上家的任一段窗沿：同一帧结束（Requirement 4.7）。
                stopForNext(&r)
                activities[id] = nil

            case let (.visitNeighbor, .resident(o)):
                guard let ol = ctx.locations[o], ol.surface == me.surface,
                      abs(ol.x - me.x) <= c.giftReachDistance else { break }
                // 到达：两人停下面朝对方，停留 Visit_Stay_Duration，双方显示心形气泡（Requirement 4.8）。
                let until = now.addingTimeInterval(c.visitStayDuration)
                a.phase = .staying(until: until)
                stop(&r)
                face(&r, from: me.x, to: ol.x)
                setGoal(&r, .hold(face: .resident(o)))
                if r.bubble == nil { r.bubble = .heart }
                activities[id] = a
                if eligible.contains(o), var other = residents[o] {
                    if other.state != .sitting && other.state != .sleeping {
                        stop(&other)
                        face(&other, from: ol.x, to: me.x)
                        setGoal(&other, .hold(face: .resident(id)))
                    }
                    // 睡着的被拜访者保持 Zzz（Requirement 5.6）：同帧刚入睡、Zzz 尚未写入时也不显示心形。
                    if other.bubble == nil, other.state != .sleeping { other.bubble = .heart }
                    if var oa = activities[o] {
                        pause(&oa, until: until, now: now)
                        activities[o] = oa
                    }
                    residents[o] = other
                }

            case let (.rest, .chair(ch)):
                guard let loc = ctx.decorLocations[ch], loc.surface == me.surface,
                      abs(loc.x - me.x) <= c.giftReachDistance,
                      let d = ctx.decors.decors[ch], d.type == .chair, case .attached = d.placement else { break }
                guard !seats.contains(where: { $0.key != id && $0.value == ch }) else {
                    // Chair 在到达前被占用（Requirement 4.11）。
                    abandon(&r, a, residents: &residents, activities: &activities, eligible: eligible)
                    activities[id] = nil
                    break
                }
                // 坐下：x 设为 Chair 的 x，进入 sitting 并占用 Chair（Requirement 4.9）。
                stop(&r)
                if let world = ctx.world { ResidentController.setX(&r, loc.x, world: world) }
                r.state = .sitting
                r.seat = ch
                seats[id] = ch
                setGoal(&r, .hold(face: nil))
                a.phase = .sitting(until: now.addingTimeInterval(c.sitDuration))
                activities[id] = a
                events.append(.sat(id, ch))

            case let (.admireFlower, .flower(f)):
                guard let loc = ctx.itemLocations[f], loc.surface == me.surface,
                      abs(loc.x - me.x) <= c.giftReachDistance else { break }
                // 到达：停下面朝花，停留 Visit_Stay_Duration，显示花朵气泡（Requirement 4.10）。
                stop(&r)
                face(&r, from: me.x, to: loc.x)
                setGoal(&r, .hold(face: nil))
                if r.bubble == nil { r.bubble = .flower }
                a.phase = .staying(until: now.addingTimeInterval(c.visitStayDuration))
                activities[id] = a

            case let (.sleep, .lamp(l)):
                guard let loc = ctx.decorLocations[l], loc.surface == me.surface,
                      abs(loc.x - me.x) <= c.lampRange else { break }
                // 走到 Lamp_Range 内：进入 sleeping，写 slept（Requirement 5.4）。
                stop(&r)
                r.state = .sleeping
                setGoal(&r, .hold(face: nil))
                a.phase = .sleeping
                activities[id] = a
                events.append(.slept(id, l))

            default:
                break
            }
            residents[id] = r
        }
        return events
    }

    /// 被拜访者在拜访停留期间才选出新 Activity（例如两人互相拜访，自己的停留刚结束时对方同帧到达）：
    /// 新 Activity 同样暂停到停留结束，留在原地面朝拜访者（Requirement 4.8）。
    private static func pausedIfHosting(
        _ id: ResidentID, _ act: Activity, activities: [ResidentID: Activity], eligible: Set<ResidentID>, now: Date
    ) -> Activity {
        var a = act
        for v in activities.keys.sorted() where v != id && eligible.contains(v) {
            guard let va = activities[v], va.target == .resident(id), case let .staying(until) = va.phase,
                  now < until else { continue }
            pause(&a, until: until, now: now)
        }
        return a
    }

    // MARK: - 下落、悬挂（Requirement 4.1、4.11）

    /// 结束所有处于 `falling`、`hanging` 的居民的 Activity。居民可能在 `plan` 之后才开始下落（移动中失去支撑、
    /// 帧末的支撑校正），因此每次 step 结束前再调用一次，保证帧末这些居民没有 Activity。返回本帧事件。
    public static func endAirborneActivities(
        residents: inout [ResidentID: Resident], activities: inout [ResidentID: Activity],
        eligible: Set<ResidentID>
    ) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        for id in residents.keys.sorted() where activities[id] != nil {
            guard var r = residents[id], r.state == .falling || r.state == .hanging else { continue }
            dropAirborne(id, &r, residents: &residents, activities: &activities, eligible: eligible,
                         events: &events)
            residents[id] = r
        }
        return events
    }

    /// 放弃下落或悬挂居民的 Activity；睡着时所在 Surface 消失而下落，补写 `woke(surface_gone)`。
    private static func dropAirborne(
        _ id: ResidentID, _ r: inout Resident, residents: inout [ResidentID: Resident],
        activities: inout [ResidentID: Activity], eligible: Set<ResidentID>, events: inout [ActivityEvent]
    ) {
        if let act = activities[id] {
            if act.phase == .sleeping {
                r.walkDistance = 0
                events.append(.woke(id, .surfaceGone))
            }
            endActivity(&r, act, residents: &residents, activities: &activities, eligible: eligible)
            activities[id] = nil
        }
        r.seat = nil
    }

    // MARK: - 辅助

    /// Lamp 放在 Surface 上（附着，不在拖动中、也不在下落中）。
    static func isPlacedLamp(_ l: DecorID, ctx: ActivityContext) -> Bool {
        guard let d = ctx.decors.decors[l], d.type == .lamp, case .attached = d.placement else { return false }
        return true
    }

    /// 只在 Goal 变化时写入，避免打断现有路线。
    private static func setGoal(_ r: inout Resident, _ g: Goal) {
        if r.goal != g { r.goal = g }
    }

    /// 停下：清除路线，离开 waiting，行走中的状态转为 idle。动作（小跳、往下跳、爬梯）进行中不改状态。
    private static func stop(_ r: inout Resident) {
        if r.state == .waiting { ResidentController.leaveWaiting(&r) }
        r.route = nil
        guard r.traversal == nil else { return }
        switch r.state {
        case .walking, .carrying, .running, .waiting: r.state = .idle
        default: break
        }
    }

    /// Activity 正常结束后停在原地，等待下一个 Activity 写入新 Goal。
    private static func stopForNext(_ r: inout Resident) {
        stop(&r)
        setGoal(&r, .hold(face: nil))
    }

    /// 放弃：居民转为 idle，不进入 waiting，不显示任何气泡（Requirement 4.11、5.5）。
    private static func abandon(
        _ r: inout Resident, _ a: Activity, residents: inout [ResidentID: Resident],
        activities: inout [ResidentID: Activity], eligible: Set<ResidentID>
    ) {
        endActivity(&r, a, residents: &residents, activities: &activities, eligible: eligible)
        stopForNext(&r)
        if r.bubble == .dots { r.bubble = nil }
    }

    /// 醒来：转 idle，Walk_Distance 归零，写 woke（Requirement 5.7、5.8）。
    private static func wake(_ r: inout Resident, reason: WakeReason, events: inout [ActivityEvent]) {
        r.state = .idle
        r.walkDistance = 0
        events.append(.woke(r.id, reason))
    }

    /// 结束 Activity 时清理它带来的显示：本居民的心形或花朵气泡；拜访停留中则同时清除对方的心形气泡，
    /// 并让对方立即从暂停处继续。
    private static func endActivity(
        _ r: inout Resident, _ a: Activity?, residents: inout [ResidentID: Resident],
        activities: inout [ResidentID: Activity], eligible: Set<ResidentID>
    ) {
        guard let a else { return }
        guard case .staying = a.phase else { return }
        switch a.target {
        case let .resident(o):
            if r.bubble == .heart { r.bubble = nil }
            guard eligible.contains(o) else { return }
            if residents[o]?.bubble == .heart { residents[o]?.bubble = nil }
            // 对方从暂停处继续（停留提前结束时也立即继续）。
            if var oa = activities[o], oa.pausedUntil != nil {
                oa.pausedUntil = nil
                activities[o] = oa
            }
        case .flower:
            if r.bubble == .flower { r.bubble = nil }
        default:
            break
        }
    }

    /// 暂停到 `until`：把 Activity 的全部计时向后平移暂停时长，暂停期间不推进、不计超时（Requirement 4.8）。
    static func pause(_ a: inout Activity, until: Date, now: Date) {
        let d = max(until.timeIntervalSince(max(a.pausedUntil ?? now, now)), 0)
        a.pausedUntil = max(a.pausedUntil ?? until, until)
        guard d > 0 else { return }
        a.startedAt = a.startedAt.addingTimeInterval(d)
        a.wanderUntil = a.wanderUntil?.addingTimeInterval(d)
        switch a.phase {
        case let .staying(t): a.phase = .staying(until: t.addingTimeInterval(d))
        case let .sitting(t): a.phase = .sitting(until: t.addingTimeInterval(d))
        case .moving, .sleeping: break
        }
    }

    private static func face(_ r: inout Resident, from x: Double, to tx: Double) {
        if tx < x { r.facing = .left } else if tx > x { r.facing = .right }
    }
}
