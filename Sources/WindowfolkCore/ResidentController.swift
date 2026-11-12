import Foundation

/// ResidentController 每帧需要的只读世界信息。
public struct WorldContext: Sendable {
    public var windows: WindowTable
    /// 当前全部 Surface（含 Ground），按 `SurfaceID` 排序。
    public var surfaces: [Surface]
    public var screen: ScreenInfo
    public var constants: Tunables
    /// 当前通路图。只应包含可见窗口的通路（Requirement 5.5）；由 WorldEngine 在居民移动之前重建（任务 8.4）。
    public var nav: NavGraph
    /// 各居民当前所在的 Surface 和屏幕 x，供 `Goal.reach` 追踪对方（Requirement 16.6、18.5、20.4）。
    /// 下落、悬挂或所在窗口隐藏的居民不在其中。
    public var residentLocations: [ResidentID: ResidentLocation]
    /// 已架设梯子上某点的屏幕坐标查询，供爬梯时按 `.ladder(id, height:)` 定位（任务 9.2）。
    /// WorldEngine 用 `state.ladders.lookup(windows:)` 构造（任务 9.3）。
    public var ladders: LadderLookup

    public init(
        windows: WindowTable, surfaces: [Surface], screen: ScreenInfo, constants: Tunables,
        nav: NavGraph = .empty, residentLocations: [ResidentID: ResidentLocation] = [:],
        ladders: LadderLookup? = nil
    ) {
        self.windows = windows
        self.surfaces = surfaces
        self.screen = screen
        self.constants = constants
        self.nav = nav
        self.residentLocations = residentLocations
        self.ladders = ladders ?? LadderLookup(store: LadderStore(), windows: windows)
    }

    /// 按 ID 查 Surface。
    public func surface(_ id: SurfaceID) -> Surface? {
        surfaces.first { $0.id == id }
    }
}

/// 居民的每帧行为。
///
/// - `Goal.none` / `Goal.confined` 下在当前 Surface 上走走停停，走到端点掉头，
///   不使用任何通路边（Requirement 12.13）。
/// - `Goal.reach` 下沿 Nav_Graph 路线移动、等待和重新规划，见 ResidentNavigation.swift（Requirement 12.7 至 12.11、6.9、6.10）。
/// - 下落推进与落地：落地后按落点更新 Attachment，进入 `idle`（Requirement 6.8）；
///   有未完成目标时下一帧从落点重新寻路（Requirement 14.7）。
///
/// 戳、悬挂计时、搬运和爬梯细节由其他任务加入。
public enum ResidentController {
    /// 闲逛停顿时长范围（秒）。
    public static let wanderPauseRange: ClosedRange<Double> = 1.0 ... 3.0
    /// 闲逛一次行走时长范围（秒）。
    public static let wanderWalkRange: ClosedRange<Double> = 1.0 ... 4.0
    /// 判断某点是否在线段上的容差（pt）。
    static let epsilon = 1e-6

    /// 推进一帧。
    public static func update(_ r: inout Resident, world: WorldContext, dt: Double, rng: inout RandomSource) {
        let dt = dt.isFinite ? max(0, dt) : 0
        switch r.state {
        case .falling:
            advanceFall(&r, world: world, dt: dt)
        case .hanging:
            advanceHang(&r, world: world, dt: dt)
        case .idle, .walking, .carrying, .waiting, .climbing:
            if r.traversal != nil {
                // 已开始的小跳、往下跳或爬梯先完成，不依赖图中的边（design.md「路线失效」）。
                advanceTraversal(&r, world: world, dt: dt)
                return
            }
            switch r.goal {
            case .none, .confined:
                normalizeForWander(&r)
                wander(&r, world: world, dt: dt, rng: &rng)
            case let .reach(other):
                seek(&r, target: world.residentLocations[other], world: world, dt: dt)
            }
        default:
            break
        }
    }

    /// 没有目标时只用 `idle` / `walking`（持有 Item 时行走为 `carrying`，Requirement 14.1）：离开等待，清除路线。
    static func normalizeForWander(_ r: inout Resident) {
        if r.state == .waiting { leaveWaiting(&r) }
        r.route = nil
        switch r.state {
        case .waiting, .climbing: r.state = .idle
        case .carrying, .walking: r.state = movingState(r)
        default: break
        }
    }

    // MARK: - 当前 Surface

    /// 居民当前所在的 Surface 和屏幕位置。
    ///
    /// 处理 `window`、`ground` 和 `plank` 三种 Attachment；窗口隐藏或已关闭、偏移量不在任何剩余窗沿内、
    /// 木板不在当前路面中、或 Attachment 为其他取值时返回 nil（调用方不移动该居民）。
    public static func currentSurface(of r: Resident, world: WorldContext) -> (surface: Surface, position: Point)? {
        if case let .plank(pid, t) = r.attachment {
            guard let s = world.surface(.plank(pid)) else { return nil }
            let u = min(max(t, 0), 1)
            let p = Point(x: s.start.x + (s.end.x - s.start.x) * u, y: s.start.y + (s.end.y - s.start.y) * u)
            return (s, p)
        }
        guard let pos = AttachmentResolver.screenPosition(r.attachment, windows: world.windows, screen: world.screen)
        else { return nil }
        switch r.attachment {
        case let .window(id, _):
            guard let s = world.surfaces.first(where: {
                $0.id.windowID == id && $0.start.x - epsilon <= pos.x && pos.x <= $0.end.x + epsilon
            }) else { return nil }
            return (s, pos)
        case .ground:
            guard let s = world.surfaces.first(where: { $0.id == .ground }) else { return nil }
            return (s, pos)
        default:
            return nil
        }
    }

    // MARK: - 闲逛

    static func wander(_ r: inout Resident, world: WorldContext, dt: Double, rng: inout RandomSource) {
        guard let (surface, pos) = currentSurface(of: r, world: world) else { return }

        if r.state == .idle {
            r.wander.pauseRemaining -= dt
            guard r.wander.pauseRemaining <= 0 else { return }
            // 起步：随机选方向；已在端点时朝内走。
            var facing: Facing = rng.bool() ? .right : .left
            if pos.x <= surface.start.x + epsilon { facing = .right }
            if pos.x >= surface.end.x - epsilon { facing = .left }
            r.facing = facing
            r.state = movingState(r)
            r.wander.walkRemaining = rng.double(in: wanderWalkRange.lowerBound, wanderWalkRange.upperBound)
            return
        }

        // walking / carrying：沿当前 Surface 移动，走到端点掉头；持有 Item 时速度为 carrySpeed（Requirement 14.2）。
        r.state = movingState(r)
        var x = pos.x + r.facing.sign * speed(r, world.constants) * dt
        if x >= surface.end.x {
            x = surface.end.x
            r.facing = .left
        } else if x <= surface.start.x {
            x = surface.start.x
            r.facing = .right
        }
        setX(&r, x, world: world)

        r.wander.walkRemaining -= dt
        if r.wander.walkRemaining <= 0 {
            r.state = .idle
            r.wander.walkRemaining = 0
            r.wander.pauseRemaining = rng.double(in: wanderPauseRange.lowerBound, wanderPauseRange.upperBound)
        }
    }

    /// 把居民放到同一 Attachment 类型下的屏幕 x 处。
    static func setX(_ r: inout Resident, _ x: Double, world: WorldContext) {
        switch r.attachment {
        case let .window(id, _):
            guard let snap = world.windows.visibleSnapshot(id) else { return }
            r.attachment = .window(id, offset: x - snap.frame.minX)
        case .ground:
            r.attachment = .ground(x: x)
        case let .plank(pid, _):
            guard let s = world.surface(.plank(pid)) else { return }
            let dx = s.end.x - s.start.x
            r.attachment = .plank(pid, t: dx > 0 ? min(max((x - s.start.x) / dx, 0), 1) : 0)
        default:
            break
        }
    }

    /// 居民当前所在的 Surface 和屏幕 x；下落、悬挂或无法定位（如窗口隐藏）时为 nil。
    /// 供 WorldEngine 构造 `WorldContext.residentLocations`（任务 8.4）。
    public static func location(of r: Resident, world: WorldContext) -> ResidentLocation? {
        guard r.state != .falling, r.state != .hanging,
              let (s, p) = currentSurface(of: r, world: world) else { return nil }
        return ResidentLocation(surface: s.id, x: p.x)
    }

    // MARK: - 桥上悬挂（Requirement 13.1 至 13.4、13.6）

    /// 让居民在屏幕位置 `position` 处进入 `hanging`：抓住桥边停在原地，`hangElapsed` 从 0 开始计时。
    ///
    /// 清除路线、动作和下落状态，保留持有物（Requirement 13.3）和目标；悬挂期间不沿 Nav_Graph 移动、
    /// 不重新规划路线（Requirement 13.2）。正在进行的戳跳跃立即结束，「?」气泡照常显示。
    public static func startHanging(_ r: inout Resident, at position: Point) {
        r.state = .hanging
        r.attachment = .free(position)
        r.route = nil
        r.traversal = nil
        r.fall = nil
        r.hangElapsed = 0
        if var p = r.poke, p.jumpRemaining > 0 {
            p.jumpRemaining = 0
            r.poke = p.bubbleRemaining > 0 ? p : nil
        }
        if r.bubble == .dots { r.bubble = nil }
        r.wander.groundCenter = nil
        r.wander.groundPatrolling = false
    }

    /// 悬挂计时一帧：保持屏幕坐标不动；累计达到 Hang_Duration 时从当前坐标竖直下落（Requirement 13.4）。
    /// 计时误差不超过一帧（30Hz 时约 33ms，满足 ±100ms）。
    static func advanceHang(_ r: inout Resident, world: WorldContext, dt: Double) {
        r.hangElapsed += dt
        guard r.hangElapsed >= world.constants.hangDuration else { return }
        let p: Point
        if case let .free(fp) = r.attachment {
            p = fp
        } else if let sp = AttachmentResolver.screenPosition(r.attachment, windows: world.windows, screen: world.screen) {
            p = sp
        } else {
            return
        }
        startFalling(&r, from: p, screen: world.screen)
    }

    // MARK: - 下落与落地

    /// 让居民从屏幕位置 `position` 开始下落（x 夹紧到屏幕范围）。清除路线和动作，保留持有物和目标。
    public static func startFalling(_ r: inout Resident, from position: Point, screen: ScreenInfo) {
        let fall = Physics.startFall(at: position, screen: screen)
        r.state = .falling
        r.fall = fall
        r.attachment = .free(fall.position)
        r.route = nil
        r.traversal = nil
        r.hangElapsed = 0
    }

    /// 推进一帧下落；落地时调用 `land`。
    static func advanceFall(_ r: inout Resident, world: WorldContext, dt: Double) {
        var fall: FallState
        if let f = r.fall {
            fall = f
        } else if case let .free(p) = r.attachment {
            fall = Physics.startFall(at: p, screen: world.screen)
        } else {
            return
        }
        if let surface = Physics.advance(&fall, dt: dt, surfaces: world.surfaces, gravity: world.constants.fallGravity) {
            land(&r, on: surface, at: fall.position, world: world)
        } else {
            r.fall = fall
            r.attachment = .free(fall.position)
        }
    }

    /// 落到 Surface 上：按落点更新 Attachment（Requirement 4.2、4.3、6.6），进入 `idle`（Requirement 6.8）。
    ///
    /// 有目标（`Goal.reach`）时，下一帧的 `update` 从落点重新寻路，有路线就出发，否则进入 `waiting`
    /// （Requirement 6.9、14.7、14.8）。
    public static func land(_ r: inout Resident, on surface: Surface, at position: Point, world: WorldContext) {
        guard let a = AttachmentResolver.attachment(landingOn: surface, atX: position.x, windows: world.windows)
        else {
            // 落点窗口不可见（不应发生）：继续保持下落，下一帧重新扫掠。
            r.fall = FallState(position: position, velocityY: 0)
            r.attachment = .free(position)
            return
        }
        r.attachment = a
        r.fall = nil
        r.state = .idle
        r.wander.pauseRemaining = wanderPauseRange.lowerBound
        r.wander.walkRemaining = 0
    }
}
