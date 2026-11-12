import Foundation

// MARK: - 状态与标识

/// 居民状态（Resident_State），共 9 个取值。
public enum ResidentState: String, Hashable, Sendable, Codable, CaseIterable {
    case idle, walking, carrying, waiting, falling, hanging, climbing, planting, celebrating
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
        fall: FallState? = nil
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
    }
}
