import Foundation

/// 一位居民当前所在的 Surface 和屏幕 x。
public struct ResidentLocation: Hashable, Sendable {
    public var surface: SurfaceID
    public var x: Double

    public init(surface: SurfaceID, x: Double) {
        self.surface = surface
        self.x = x
    }
}

extension NavGraph {
    /// 没有任何节点和边的通路图。
    public static let empty = NavGraph(nodes: [:], edges: [:])
}

// MARK: - 寻路、等待与路线重规划（Requirement 6.9、6.10、12.7 至 12.11、14.1、14.2）

extension ResidentController {
    /// 到达目标 x 的容差（pt）。
    public static let arriveTolerance = 0.5
    /// 小跳动作时长（秒）与抛物线最高点（pt，相对两端较高者）。
    public static let smallJumpDuration = 0.35
    public static let smallJumpArc = 10.0
    /// 往下跳动作的最短时长（秒）。
    public static let minDropDuration = 0.15

    /// 沿路线移动时的状态：`speedFactor > 1` 为 `running`（Requirement 21.1），否则持有 Item 为 `carrying`，
    /// 否则为 `walking`（Requirement 12.7、14.1）。
    static func movingState(_ r: Resident) -> ResidentState {
        if r.speedFactor > 1 { return .running }
        return r.heldItem == nil ? .walking : .carrying
    }

    /// 小跳、往下跳期间的状态：沿用 v1，不处于 `running`（Requirement 21.1）。
    static func traversalState(_ r: Resident) -> ResidentState {
        r.heldItem == nil ? .walking : .carrying
    }

    /// 水平移动速度：`walkSpeed × speedFactor`；`speedFactor` 不大于 1 且持有 Item 时以 carrySpeed 为基准
    /// （Requirement 14.2、21.1）。`speedFactor` 不是正有限数时按 1 处理。
    static func speed(_ r: Resident, _ c: Tunables) -> Double {
        let f = r.speedFactor.isFinite && r.speedFactor > 0 ? r.speedFactor : 1
        let base = (f > 1 || r.heldItem == nil) ? c.walkSpeed : c.carrySpeed
        return base * f
    }

    // MARK: V2 目标

    /// `Goal.hold` 的一帧：停在原地、状态为 `idle`，清除路线；`face` 指向的居民可定位时朝向对方。
    static func hold(_ r: inout Resident, face: FaceTarget?, world: WorldContext) {
        if r.state == .waiting { leaveWaiting(&r) }
        r.route = nil
        r.state = .idle
        guard let (_, pos) = currentSurface(of: r, world: world) else { return }
        faceToward(&r, face: face, fromX: pos.x, world: world)
    }

    /// `face` 指向的居民可定位时，按对方 x 相对 `x` 更新朝向；x 相等或无法定位时保持原朝向。
    static func faceToward(_ r: inout Resident, face: FaceTarget?, fromX x: Double, world: WorldContext) {
        guard case let .resident(other)? = face, let t = world.residentLocations[other] else { return }
        if t.x < x { r.facing = .left } else if t.x > x { r.facing = .right }
    }

    /// `Goal.wait` 的一帧：停在原地、状态为 `waiting`，清除路线和「...」气泡，不在 Ground 上来回走动；
    /// `face` 指向的居民可定位时朝向对方（v2 Requirement 21.3）。
    static func waitInPlace(_ r: inout Resident, face: FaceTarget?, world: WorldContext) {
        r.route = nil
        r.state = .waiting
        if r.bubble == .dots { r.bubble = nil }
        r.wander.groundCenter = nil
        r.wander.groundPatrolling = false
        guard let (_, pos) = currentSurface(of: r, world: world) else { return }
        faceToward(&r, face: face, fromX: pos.x, world: world)
    }

    /// `Goal.reachPoint` 的一帧：与目标在同一 Surface 且 x 差不超过 `within` 时停下（`idle`），
    /// 否则按 `seek` 的规则寻路、等待和重新规划。
    static func seekPoint(
        _ r: inout Resident, surface sid: SurfaceID, x: Double, within: Double, world: WorldContext, dt: Double
    ) {
        guard let (surface, pos) = currentSurface(of: r, world: world) else { return }
        if surface.id == sid, abs(pos.x - x) <= max(within, 0) {
            stop(&r)
            return
        }
        // 目标 Surface 已不存在时当作暂时无法定位：沿现有有效路线继续，否则停下。
        let target = world.surface(sid) == nil ? nil : ResidentLocation(surface: sid, x: x)
        seek(&r, target: target, world: world, dt: dt)
    }

    /// `Goal.reachWindow` 的一帧：站在窗口 `w` 的任一段 Window_Ledge 上即到达并停下；
    /// 否则沿现有有效路线继续，没有时对每段可见窗沿求路线，取代价最小者；都不可达时等待。
    static func seekWindow(_ r: inout Resident, window w: WindowID, world: WorldContext, dt: Double) {
        guard let (surface, pos) = currentSurface(of: r, world: world) else { return }
        if surface.id.windowID == w {
            stop(&r)
            return
        }
        let ledges = world.surfaces.filter { $0.id.windowID == w }
        let nav = world.nav
        if let route = r.route, route.targetSurface.windowID == w, nav.isValid(route, from: surface.id) {
            // 现有路线仍有效，继续。
        } else {
            var best: (cost: Double, route: Route)?
            for ledge in ledges {
                let tx = min(max(pos.x, ledge.start.x), ledge.end.x)
                guard let route = nav.route(from: surface.id, at: pos.x, to: ledge.id, targetX: tx,
                                            metric: r.routeMetric) else { continue }
                let cost = routeCost(route, from: pos.x, metric: r.routeMetric)
                if best == nil || cost < best!.cost { best = (cost, route) }
            }
            r.route = best?.route
        }
        guard let route = r.route else {
            if let ledge = ledges.first {
                let tx = min(max(pos.x, ledge.start.x), ledge.end.x)
                wait(&r, on: surface, at: pos, targetX: tx, world: world, dt: dt)
            } else if r.state == .walking || r.state == .carrying || r.state == .running {
                r.state = .idle
            }
            return
        }
        if r.state == .waiting { leaveWaiting(&r) }
        follow(&r, route: route, on: surface, at: pos, world: world, dt: dt)
    }

    /// 从 `x` 出发走完路线各条边、到达最后一条边入口点的代价（不含在目标 Surface 上继续行走的距离）。
    static func routeCost(_ route: Route, from x: Double, metric: RouteMetric) -> Double {
        var cur = x
        var total = 0.0
        for e in route.steps {
            total += abs(e.exit.x - cur)
            total += metric == .standard ? e.cost : abs(e.entry.x - e.exit.x)
            cur = e.entry.x
        }
        return total
    }

    /// 到达目标：清除路线、离开等待，状态为 `idle`。
    static func stop(_ r: inout Resident) {
        if r.state == .waiting { leaveWaiting(&r) }
        r.route = nil
        r.state = .idle
    }

    /// `Goal.reach` 的一帧：更新路线目标，必要时重新寻路；有路线就沿路线走，否则等待。
    ///
    /// - 目标 Surface 不变且现有路线仍有效时只更新 `targetX`；否则从当前位置重新寻路（Requirement 12.9）。
    /// - 目标暂时无法定位（对方下落中或在隐藏窗口上）时沿现有有效路线继续；没有路线时停下。
    static func seek(_ r: inout Resident, target: ResidentLocation?, world: WorldContext, dt: Double) {
        guard let (surface, pos) = currentSurface(of: r, world: world) else { return }
        let nav = world.nav

        if let target {
            if var route = r.route, route.targetSurface == target.surface, nav.isValid(route, from: surface.id) {
                route.targetX = target.x
                r.route = route
            } else {
                r.route = nav.route(from: surface.id, at: pos.x, to: target.surface, targetX: target.x,
                                    metric: r.routeMetric)
            }
        } else if let route = r.route, !nav.isValid(route, from: surface.id) {
            r.route = nil
        }

        guard let route = r.route else {
            if let target {
                wait(&r, on: surface, at: pos, targetX: target.x, world: world, dt: dt)
            } else if r.state == .walking || r.state == .carrying || r.state == .running {
                r.state = .idle
            }
            return
        }

        if r.state == .waiting { leaveWaiting(&r) }
        follow(&r, route: route, on: surface, at: pos, world: world, dt: dt)
    }

    /// 沿路线走一帧：先走到下一条边的离开点再通过该边；没有剩余边时走到目标 x，到达后停下并清除路线（Requirement 12.8）。
    static func follow(_ r: inout Resident, route: Route, on surface: Surface, at pos: Point, world: WorldContext, dt: Double) {
        let step = speed(r, world.constants) * dt
        if let edge = route.steps.first {
            if walk(&r, toward: edge.exit.x, on: surface, from: pos, maxStep: step, world: world) {
                r.route?.steps.removeFirst()
                let exitX = min(max(edge.exit.x, surface.start.x), surface.end.x)
                take(edge, &r, from: Point(x: exitX, y: surface.y(atX: exitX)), world: world)
            } else {
                r.state = movingState(r)
            }
            return
        }
        if abs(pos.x - route.targetX) <= arriveTolerance {
            setX(&r, min(max(route.targetX, surface.start.x), surface.end.x), world: world)
            r.route = nil
            r.state = .idle
            return
        }
        if walk(&r, toward: route.targetX, on: surface, from: pos, maxStep: step, world: world) {
            r.route = nil
            r.state = .idle
        } else {
            r.state = movingState(r)
        }
    }

    /// 在当前 Surface 上朝 `x`（夹紧到 Surface 范围）移动最多 `maxStep`。到达时返回 true。
    @discardableResult
    static func walk(
        _ r: inout Resident, toward x: Double, on surface: Surface, from pos: Point, maxStep: Double, world: WorldContext
    ) -> Bool {
        let goal = min(max(x, surface.start.x), surface.end.x)
        let d = goal - pos.x
        if abs(d) <= max(maxStep, epsilon) {
            if d != 0 { r.facing = d < 0 ? .left : .right }
            setX(&r, goal, world: world)
            return true
        }
        r.facing = d < 0 ? .left : .right
        setX(&r, pos.x + r.facing.sign * maxStep, world: world)
        return false
    }

    /// 通过一条边。walk 和 plank 边两端是同一点，立即换到下一条 Surface；
    /// 小跳、往下跳、爬梯开始一个 `Traversal`，完成后再落到下一条 Surface。
    static func take(_ edge: NavEdge, _ r: inout Resident, from: Point, world: WorldContext) {
        let c = world.constants
        switch edge.kind {
        case .walk, .plank:
            arrive(&r, on: edge.to, at: edge.entry, world: world)
        case .smallJump:
            r.traversal = Traversal(kind: .smallJump, from: from, to: edge.entry,
                                    duration: smallJumpDuration, edge: edge)
            r.state = traversalState(r)
        case .drop:
            let h = max(edge.entry.y - from.y, 0)
            let g = c.fallGravity > 0 ? c.fallGravity : 2000
            r.traversal = Traversal(kind: .drop, from: from, to: edge.entry,
                                    duration: max(minDropDuration, (2 * h / g).squareRoot()), edge: edge)
            r.state = traversalState(r)
        case let .ladder(lid):
            r.state = .climbing
            let v = c.climbSpeed > 0 ? c.climbSpeed : 30
            if let (bottom, top) = ladderEnds(lid, world: world) {
                // 爬梯期间附着在梯子上（距下端的竖直距离），跟随上端窗口移动；
                // 梯子失效时 WorldEngine 据此让居民直接下落（Requirement 13.5）。
                let up = edge.entry.y < from.y
                let length = max(bottom.y - top.y, 0)
                r.attachment = .ladder(lid, height: up ? 0 : length)
                r.traversal = Traversal(kind: .climb, from: up ? bottom : top, to: up ? top : bottom,
                                        duration: max(length / v, 0.05), edge: edge)
            } else {
                // 没有梯子几何（例如只给了通路图的测试上下文）：按边的两端匀速移动。
                let h = abs(edge.entry.y - from.y)
                r.traversal = Traversal(kind: .climb, from: from, to: edge.entry,
                                        duration: max(h / v, 0.05), edge: edge)
            }
        }
    }

    /// 已架设梯子当前的下端和上端屏幕坐标；梯子不存在、未架设或上端窗口不可见时为 nil。
    static func ladderEnds(_ id: LadderID, world: WorldContext) -> (bottom: Point, top: Point)? {
        guard let b = world.ladders.point(onLadder: id, height: 0),
              let t = world.ladders.point(onLadder: id, height: .greatestFiniteMagnitude) else { return nil }
        return (b, t)
    }

    /// 爬梯一帧（附着为 `.ladder(id, height:)` 时）：以 climbSpeed 沿梯子朝目标端移动，
    /// 到达后落到边的终点 Surface 上，状态回到 `walking` / `carrying`（Requirement 12.7）。
    ///
    /// 梯子长度随上端窗口移动而变化时，高度夹紧到当前长度。上端窗口隐藏时暂停（Requirement 5.3）；
    /// 梯子已不存在或已失效时从当前位置竖直下落，不经过 `hanging`（Requirement 13.5 的兜底，
    /// 正常情况由 WorldEngine 在校验梯子的同一帧处理）。
    static func advanceClimb(_ r: inout Resident, _ t: Traversal, ladder lid: LadderID, height: Double,
                             world: WorldContext, dt: Double) {
        guard let edge = t.edge, let (bottom, top) = ladderEnds(lid, world: world) else {
            if let w = world.ladders.store.ladders[lid]?.placed?.top.window, world.windows.isHidden(w) { return }
            let bottomY = t.from.y < t.to.y ? t.to.y : t.from.y
            startFalling(&r, from: Point(x: t.from.x, y: bottomY - max(height, 0)), screen: world.screen)
            return
        }
        let length = max(bottom.y - top.y, 0)
        let up = t.to.y < t.from.y
        let goal = up ? length : 0
        let step = (world.constants.climbSpeed > 0 ? world.constants.climbSpeed : 30) * dt
        var h = min(max(height, 0), length)
        h = goal > h ? min(h + step, goal) : max(h - step, goal)
        var next = t
        next.elapsed += dt
        // 记下梯子当前两端，供绘制和梯子消失时的兜底下落使用。
        (next.from, next.to) = up ? (bottom, top) : (top, bottom)
        r.state = .climbing
        guard abs(h - goal) <= epsilon else {
            r.attachment = .ladder(lid, height: h)
            r.traversal = next
            return
        }
        r.traversal = nil
        r.state = movingState(r)
        arrive(&r, on: edge.to, at: up ? top : bottom, world: world)
    }

    /// 推进正在执行的动作；完成时落到边的终点 Surface 上，状态回到 `walking` / `carrying`。
    static func advanceTraversal(_ r: inout Resident, world: WorldContext, dt: Double) {
        guard var t = r.traversal else { return }
        if t.kind == .climb, case let .ladder(lid, height) = r.attachment {
            advanceClimb(&r, t, ladder: lid, height: height, world: world, dt: dt)
            return
        }
        t.elapsed += dt
        guard t.elapsed >= t.duration else {
            r.traversal = t
            return
        }
        r.traversal = nil
        r.state = movingState(r)
        guard let edge = t.edge else { return }
        arrive(&r, on: edge.to, at: t.to, world: world)
    }

    /// 放到 Surface `id` 上 `point.x` 处（夹紧到 Surface 范围）。该 Surface 已不存在或其窗口不可见时，
    /// 从 `point` 开始下落（保留目标，落地后重新寻路）。
    static func arrive(_ r: inout Resident, on id: SurfaceID, at point: Point, world: WorldContext) {
        guard let s = world.surface(id),
              let a = AttachmentResolver.attachment(
                  landingOn: s, atX: min(max(point.x, s.start.x), s.end.x), windows: world.windows)
        else {
            startFalling(&r, from: point, screen: world.screen)
            return
        }
        r.attachment = a
    }

    /// 动作的绘制位置：小跳为抛物线，往下跳为水平匀速、竖直加速，爬梯为匀速直线。
    public static func traversalPoint(_ t: Traversal) -> Point {
        let u = t.duration > 0 ? min(max(t.elapsed / t.duration, 0), 1) : 1
        let x = t.from.x + (t.to.x - t.from.x) * u
        switch t.kind {
        case .smallJump:
            let base = t.from.y + (t.to.y - t.from.y) * u
            return Point(x: x, y: base - smallJumpArc * 4 * u * (1 - u))
        case .drop:
            return Point(x: x, y: t.from.y + (t.to.y - t.from.y) * u * u)
        case .climb:
            return Point(x: x, y: t.from.y + (t.to.y - t.from.y) * u)
        }
    }

    // MARK: 等待

    /// 目标不可达时等待。
    ///
    /// - 不在 Ground 上：停在原地，朝向目标 x 所在一侧，显示「...」气泡（Requirement 12.10）。
    /// - 在 Ground 上：先走到 Ground 上离目标 x 最近的点，再以该点为中心在 ±Ground_Wander_Range 内来回走动
    ///   （Requirement 6.9）。
    static func wait(_ r: inout Resident, on surface: Surface, at pos: Point, targetX: Double, world: WorldContext, dt: Double) {
        let entering = r.state != .waiting
        r.state = .waiting
        r.route = nil

        guard surface.id == .ground else {
            if targetX < pos.x { r.facing = .left } else if targetX > pos.x { r.facing = .right }
            r.bubble = .dots
            r.wander.groundCenter = nil
            r.wander.groundPatrolling = false
            return
        }

        if entering || r.wander.groundCenter == nil {
            r.wander.groundCenter = min(max(targetX, surface.start.x), surface.end.x)
            r.wander.groundPatrolling = false
        }
        if r.bubble == .dots { r.bubble = nil }
        let center = r.wander.groundCenter!
        let step = speed(r, world.constants) * dt

        if !r.wander.groundPatrolling {
            if walk(&r, toward: center, on: surface, from: pos, maxStep: step, world: world) {
                r.wander.groundPatrolling = true
            }
            return
        }

        let range = max(world.constants.groundWanderRange, 0)
        let lo = max(surface.start.x, center - range)
        let hi = min(surface.end.x, center + range)
        var x = min(max(pos.x, lo), hi) + r.facing.sign * step
        if x >= hi {
            x = hi
            r.facing = .left
        } else if x <= lo {
            x = lo
            r.facing = .right
        }
        setX(&r, x, world: world)
    }

    /// 离开 `waiting`：隐藏「...」气泡，清除地面等待中心（Requirement 6.10、12.11）。
    static func leaveWaiting(_ r: inout Resident) {
        if r.bubble == .dots { r.bubble = nil }
        r.wander.groundCenter = nil
        r.wander.groundPatrolling = false
        if r.state == .waiting { r.state = .idle }
    }
}
