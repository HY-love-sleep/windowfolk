import Foundation

// MARK: - 状态与标识

/// 居民状态（Resident_State），共 12 个取值（V2 新增 sitting、sleeping、running）。
public enum ResidentState: String, Hashable, Sendable, Codable, CaseIterable {
    case idle, walking, carrying, waiting, falling, hanging, climbing, planting, celebrating
    case sitting, sleeping, running
}

/// 居民标识。`a` 为都都（Resident_A），`b` 为嘟嘟（Resident_B）。
public enum ResidentID: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case a = "resident_a"
    case b = "resident_b"

    public static func < (lhs: ResidentID, rhs: ResidentID) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 另一位居民。
    public var other: ResidentID { self == .a ? .b : .a }
}

/// 居民当前的目标。
public enum Goal: Hashable, Sendable {
    /// 没有目标：在当前 Surface 内闲逛。
    case none
    /// 剧情要求：只在当前 Surface 内 idle / walking。
    case confined
    /// 每帧追踪另一位居民的当前位置，沿 Nav_Graph 路线移动；不可达时等待。
    case reach(ResidentID)
    /// 停在原地，不水平移动，状态为 `idle`；`face` 非空时每帧朝向该目标（V2）。
    case hold(face: FaceTarget?)
    /// 停在原地，不水平移动，状态为 `waiting` 且不显示「...」气泡；`face` 非空时每帧朝向该目标
    /// （追逐中 Chaser 没有路线可达 Runner 时，v2 Requirement 21.3）。
    case wait(face: FaceTarget?)
    /// 前往 Surface 上的某个 x：同一 Surface 且 `|x - 目标 x| <= arriveWithin` 时到达并停下
    /// （Chair、Lamp、Story_Flower、Flee_Target，V2）。
    case reachPoint(SurfaceID, x: Double, arriveWithin: Double)
    /// 前往该窗口任意一段 Window_Ledge；站在其中任一段上即到达并停下（`go_home`、Visit_Wish，V2）。
    case reachWindow(WindowID)
}

/// `Goal.hold` 的朝向目标。
public enum FaceTarget: Hashable, Sendable {
    case resident(ResidentID)
}

/// 朝向。
public enum Facing: String, Hashable, Sendable, Codable {
    case left, right

    public var flipped: Facing { self == .left ? .right : .left }
    /// 水平方向符号：左为 -1，右为 +1。
    public var sign: Double { self == .left ? -1 : 1 }
}

// MARK: - 后续任务使用的字段类型（先声明，行为在后续任务实现）

// `ItemID` 定义在 Item.swift 中。

// `Route` 定义在 NavGraph.swift 中。

/// 正在执行的小跳、往下跳或爬梯动作（任务 8.3 实现，爬梯由任务 9.2 完善）。
///
/// 小跳和往下跳期间居民的 Attachment 保持在出发点（离开 `edge.from` 的点），动作完成时才换到 `edge.to` 上的落点；
/// 绘制位置由 `ResidentController.traversalPoint(_:)` 给出。
/// 爬梯期间（梯子几何可查时）Attachment 为 `.ladder(id, height:)`，按 climbSpeed 推进高度，绘制位置取该 Attachment
/// 的屏幕坐标；`from` / `to` 为梯子当前的出发端和目标端。
public struct Traversal: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case smallJump, drop, climb }
    public var kind: Kind
    public var from: Point
    public var to: Point
    /// 已执行时长与总时长，单位秒。
    public var elapsed: Double
    public var duration: Double
    /// 正在执行的通路边；完成时落到 `edge.to` 上。
    public var edge: NavEdge?

    public init(kind: Kind, from: Point, to: Point, elapsed: Double = 0, duration: Double, edge: NavEdge? = nil) {
        self.kind = kind
        self.from = from
        self.to = to
        self.elapsed = elapsed
        self.duration = duration
        self.edge = edge
    }
}

/// 戳居民的状态：跳跃剩余时间和「?」气泡剩余时间（任务 6.7 实现）。
public struct PokeState: Hashable, Sendable {
    /// 跳跃剩余时间；0 表示没有跳跃。
    public var jumpRemaining: Double
    /// 「?」气泡剩余时间。
    public var bubbleRemaining: Double

    public init(jumpRemaining: Double, bubbleRemaining: Double) {
        self.jumpRemaining = jumpRemaining
        self.bubbleRemaining = bubbleRemaining
    }
}

/// 剧情气泡。只用图标表达，不含任何文字（Requirement 15.9）。
public enum Bubble: Hashable, Sendable {
    /// 「花盆 + Receiver 头像」许愿气泡。
    case wish(receiver: ResidentID)
    /// 「...」等待气泡。
    case dots
    /// 心形气泡。
    case heart
    /// 「Zzz」图标气泡：居民处于 `sleeping` 时显示（v2 Requirement 5.6）。
    case zzz
    /// 花朵图标气泡：`admire_flower` 停留期间显示（v2 Requirement 4.10）。
    case flower
    /// Wish_Bubble（v2 Requirement 6.8、6.9、7.1、7.4、9.3、20.3）：以图形绘制的心愿图标，不含文字。
    /// Flower_Wish 仍用 v1 的 `wish(receiver:)`。
    case wishIcon(WishIcon)
}

/// 闲逛计时与地面等待中心。
public struct WanderState: Hashable, Sendable {
    /// `idle` 时距离下次起步的剩余时间。
    public var pauseRemaining: Double
    /// `walking` 时距离停下的剩余时间。
    public var walkRemaining: Double
    /// 地面等待时来回走动的中心 x：Ground 上离目标 x 最近的点（Requirement 6.9）。
    public var groundCenter: Double?
    /// 地面等待中已走到 `groundCenter`，开始在 ±Ground_Wander_Range 内来回走动。
    public var groundPatrolling: Bool

    public init(
        pauseRemaining: Double = 1.0, walkRemaining: Double = 0, groundCenter: Double? = nil,
        groundPatrolling: Bool = false
    ) {
        self.pauseRemaining = pauseRemaining
        self.walkRemaining = walkRemaining
        self.groundCenter = groundCenter
        self.groundPatrolling = groundPatrolling
    }
}

// MARK: - Resident

/// 一位居民。位置由 `attachment` 决定；下落中 `attachment` 为 `.free`，速度在 `fall` 中。
public struct Resident: Hashable, Sendable {
    public var id: ResidentID
    public var state: ResidentState
    public var attachment: Attachment
    public var facing: Facing
    public var goal: Goal
    public var route: Route?
    public var traversal: Traversal?
    public var heldItem: ItemID?
    /// `hanging` 状态已累计时长（任务 8.4 实现计时）。
    public var hangElapsed: Double
    public var poke: PokeState?
    public var bubble: Bubble?
    public var wander: WanderState
    /// 下落状态；只在 `state == .falling` 时非空。
    public var fall: FallState?
    /// 水平速度倍数：大于 1 时在 Surface 上水平移动为 `running`（追逐中为 1.6 或 1.5，Requirement 21.1）。
    public var speedFactor: Double
    /// 规划路线时使用的度量：追逐、选 Decor、Visit_Wish 用 `.horizontal`，其余 `.standard`。
    public var routeMetric: RouteMetric
    /// Walk_Distance：`walking` / `running` 帧的水平位移绝对值累计（pt，Requirement 4.14）。
    public var walkDistance: Double
    /// 正在坐的 Chair。
    public var seat: DecorID?
    /// 正在显示的 Thought（Requirement 14.2）；只由 `ThoughtEngine.step` 写入。
    public var thought: ThoughtDisplay?

    public init(
        id: ResidentID,
        state: ResidentState = .idle,
        attachment: Attachment,
        facing: Facing = .right,
        goal: Goal = .none,
        route: Route? = nil,
        traversal: Traversal? = nil,
        heldItem: ItemID? = nil,
        hangElapsed: Double = 0,
        poke: PokeState? = nil,
        bubble: Bubble? = nil,
        wander: WanderState = WanderState(),
        fall: FallState? = nil,
        speedFactor: Double = 1,
        routeMetric: RouteMetric = .standard,
        walkDistance: Double = 0,
        seat: DecorID? = nil,
        thought: ThoughtDisplay? = nil
    ) {
        self.id = id
        self.state = state
        self.attachment = attachment
        self.facing = facing
        self.goal = goal
        self.route = route
        self.traversal = traversal
        self.heldItem = heldItem
        self.hangElapsed = hangElapsed
        self.poke = poke
        self.bubble = bubble
        self.wander = wander
        self.fall = fall
        self.speedFactor = speedFactor
        self.routeMetric = routeMetric
        self.walkDistance = walkDistance
        self.seat = seat
        self.thought = thought
    }
}
