import Foundation

// Activity 模型（design.md「Core：ActivityPlanner」，任务 5.3）。
//
// - Activity 的计时都记录为 `Date` 时间点，按 `now - 起点` 判定（design.md「两类时钟」）。
// - 选择规则与可执行判定见 `ActivityPlanner.swift`；推进（plan / resolve）见 `ActivityPlanner+Progress.swift`。

/// Activity 种类。声明顺序即加权随机时累加权重的固定顺序（Requirement 4.5、4.15）。
public enum ActivityKind: String, Hashable, Sendable, CaseIterable {
    case wander
    case goHome = "go_home"
    case visitNeighbor = "visit_neighbor"
    case rest
    case admireFlower = "admire_flower"
    case sleep
}

/// Activity 的目标。
public enum ActivityTarget: Hashable, Sendable {
    case none
    case home(WindowID)
    case resident(ResidentID)
    case chair(DecorID)
    case flower(ItemID)
    case lamp(DecorID)
}

/// Activity 的阶段。
public enum ActivityPhase: Hashable, Sendable {
    /// 前往目标；`wander` 时在当前 Surface 闲逛。
    case moving
    /// `visit_neighbor`、`admire_flower` 到达后停留。
    case staying(until: Date)
    /// `rest` 坐满 Sit_Duration。
    case sitting(until: Date)
    /// `sleep` 到达后。
    case sleeping
}

/// 一位居民的当前 Activity。
public struct Activity: Hashable, Sendable {
    public var kind: ActivityKind
    public var target: ActivityTarget
    public var startedAt: Date
    public var phase: ActivityPhase
    /// 仅 `wander`：到时结束的时间点，`startedAt + 时长`。
    public var wanderUntil: Date?
    /// 仅 `wander`：开始时所在 Surface。
    public var surface: SurfaceID?
    /// 被拜访期间的暂停结束时间；期间不推进、不计超时（Requirement 4.8，任务 5.6 使用）。
    public var pausedUntil: Date?

    public init(
        kind: ActivityKind, target: ActivityTarget, startedAt: Date, phase: ActivityPhase = .moving,
        wanderUntil: Date? = nil, surface: SurfaceID? = nil, pausedUntil: Date? = nil
    ) {
        self.kind = kind
        self.target = target
        self.startedAt = startedAt
        self.phase = phase
        self.wanderUntil = wanderUntil
        self.surface = surface
        self.pausedUntil = pausedUntil
    }

    /// `wander` 的持续时长（秒）；其他种类为 nil。
    public var wanderDuration: TimeInterval? {
        wanderUntil.map { $0.timeIntervalSince(startedAt) }
    }
}

/// ActivityPlanner 的输入。由 WorldEngine 每帧构造，ActivityPlanner 只读它，不访问 WorldState。
public struct ActivityContext: Sendable {
    public var nav: NavGraph
    /// 各居民当前所在的 Surface 和屏幕 x。下落、悬挂、爬梯或在 Hidden_Window 上的居民不在其中。
    public var locations: [ResidentID: ResidentLocation]
    public var decors: DecorStore
    /// 正在坐的 Chair。
    public var seats: [ResidentID: DecorID]
    public var items: ItemStore
    /// Home_Window；未分配的居民不在其中。
    public var homes: [ResidentID: WindowID]
    public var isNight: Bool
    public var now: Date
    public var constants: Tunables
    /// Visit_Wish 刚完成的居民（Requirement 9.8）。
    public var preferHome: Set<ResidentID>
    /// 附着在可见 Surface 上的 Decor 所在的 Surface 和屏幕 x。拖动中、下落中或在 Hidden_Window 上的不在其中。
    /// 可用 `ActivityContext.location(of:world:)` 从 Attachment 求出。
    public var decorLocations: [DecorID: ResidentLocation]
    /// 附着在可见 Surface 上的 Item 所在的 Surface 和屏幕 x。被持有、拖动中、下落中或在 Hidden_Window 上的不在其中。
    public var itemLocations: [ItemID: ResidentLocation]
    /// 居民移动使用的只读世界信息；`resolve` 坐下时据此把居民放到 Chair 的 x 处。为 nil 时坐下不挪位置。
    public var world: WorldContext?

    public init(
        nav: NavGraph, locations: [ResidentID: ResidentLocation] = [:],
        decors: DecorStore = DecorStore(), seats: [ResidentID: DecorID] = [:],
        items: ItemStore = ItemStore(), homes: [ResidentID: WindowID] = [:],
        isNight: Bool = false, now: Date, constants: Tunables = Tunables(),
        preferHome: Set<ResidentID> = [],
        decorLocations: [DecorID: ResidentLocation] = [:],
        itemLocations: [ItemID: ResidentLocation] = [:],
        world: WorldContext? = nil
    ) {
        self.world = world
        self.nav = nav
        self.locations = locations
        self.decors = decors
        self.seats = seats
        self.items = items
        self.homes = homes
        self.isNight = isNight
        self.now = now
        self.constants = constants
        self.preferHome = preferHome
        self.decorLocations = decorLocations
        self.itemLocations = itemLocations
    }

    /// 附着在 `window`、`ground` 或 `plank` 上的对象所在的 Surface 和屏幕 x。
    /// 窗口隐藏或已关闭、不在任何剩余 Surface 内、或为其他 Attachment 时返回 nil。
    public static func location(of a: Attachment, world: WorldContext) -> ResidentLocation? {
        let eps = 1e-6
        switch a {
        case let .window(id, offset):
            guard let snap = world.windows.visibleSnapshot(id) else { return nil }
            let x = snap.frame.minX + offset
            guard let s = world.surfaces.sorted(by: { $0.id < $1.id }).first(where: {
                $0.id.windowID == id && $0.start.x - eps <= x && x <= $0.end.x + eps
            }) else { return nil }
            return ResidentLocation(surface: s.id, x: x)
        case let .ground(x):
            guard world.surfaces.contains(where: { $0.id == .ground }) else { return nil }
            return ResidentLocation(surface: .ground, x: x)
        case let .plank(pid, t):
            guard let s = world.surface(.plank(pid)) else { return nil }
            let u = min(max(t, 0), 1)
            return ResidentLocation(surface: s.id, x: s.start.x + (s.end.x - s.start.x) * u)
        case .ladder, .free:
            return nil
        }
    }
}

/// ActivityPlanner 推进时产生的事件，由 WorldEngine 写入 Event_Log。
public enum ActivityEvent: Hashable, Sendable {
    case sat(ResidentID, DecorID)
    case slept(ResidentID, DecorID)
    case woke(ResidentID, WakeReason)
    case visited(ResidentID, ResidentID)
}

/// 离开 `sleeping` 的原因（Requirement 18.6）。
public enum WakeReason: String, Hashable, Sendable {
    case nightEnded = "night_ended"
    case lampMoved = "lamp_moved"
    case surfaceGone = "surface_gone"
    case becameBusy = "became_busy"
}
