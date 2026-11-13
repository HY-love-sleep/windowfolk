import Foundation

// Wish 模型与 WishBook（design.md「Core：Wish 模型与 WishDirector」，任务 7.1）。
//
// - 一位居民同时最多参与 1 个 active Wish（Requirement 6.7）。控制者由 `active` 推出，
//   `busy` 是全部 active Wish 的 `participants` 并集，不单独存储。
// - Wish 变为 active 时记录 Wish_Type、Wisher 和 Story_Clock 创建时间 `createdAt`（Requirement 6.8）。
// - `flowerCount` 是已开始过的 Flower_Wish 次数，只在 Flower_Wish 开始时加 1，
//   加 1 后的值即该次 Flower_Wish 的 Story_Round（Requirement 8.2）。
// - 生成、推进规则在 `WishDirector`；本文件只有数据类型。

/// Wish 种类。`allCases` 的顺序即生成时候选类型的排序（design.md「检查与生成」）。
public enum WishType: String, Hashable, Sendable, Codable, CaseIterable {
    case flower, chair, lamp, visit, chase
}

/// Wish_State。active 表示进行中；fulfilled、dropped 是两种结束方式。
public enum WishState: String, Hashable, Sendable, Codable {
    case active, fulfilled, dropped
}

/// Wish 标识。单调递增分配，用于 `WishBook.active` 的排序。
public struct WishID: Hashable, Sendable, Comparable {
    public var rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: WishID, rhs: WishID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Visit_Wish 的目标窗口。`ownerName` 是窗口所属应用名称，用于事件记录 `app:<名称>` 和恢复存档时匹配。
public struct VisitTarget: Hashable, Sendable {
    public var window: WindowID
    public var ownerName: String
    public init(window: WindowID, ownerName: String) {
        self.window = window
        self.ownerName = ownerName
    }
}

/// Chase_Wish 的阶段：ready（对视、准备）与 running（追逐中）。
public enum ChasePhase: String, Hashable, Sendable {
    case ready, running
}

/// Chase_Wish 的结局。
public enum ChaseOutcome: String, Hashable, Sendable, Codable {
    case caught, escaped
}

/// Runner 的逃跑目标点：某条 Surface 上的一个 x（Flee_Target / Chase_Candidate_Point）。
public struct FleePoint: Hashable, Sendable {
    public var surface: SurfaceID
    public var x: Double
    public init(surface: SurfaceID, x: Double) {
        self.surface = surface
        self.x = x
    }
}

/// Chase_Wish 的运行状态。
public struct ChaseState: Hashable, Sendable {
    public var phase: ChasePhase
    /// 进入 ready 的时间。
    public var readyAt: Date
    /// 进入 running 的时间；ready 阶段为 nil。
    public var runningAt: Date?
    /// 当前 Flee_Target；没有可用候选点时为 nil。
    public var fleeTarget: FleePoint?
    /// 上一次重新选择 Flee_Target 的时间。
    public var lastReplanAt: Date?
    /// 上一次选点时的 navVersion，变化时需要重新选点。
    public var lastNavVersion: Int
    /// 结束后正在庆祝的居民。
    public var celebrating: Set<ResidentID>

    public init(
        phase: ChasePhase = .ready, readyAt: Date, runningAt: Date? = nil,
        fleeTarget: FleePoint? = nil, lastReplanAt: Date? = nil, lastNavVersion: Int = 0,
        celebrating: Set<ResidentID> = []
    ) {
        self.phase = phase
        self.readyAt = readyAt
        self.runningAt = runningAt
        self.fleeTarget = fleeTarget
        self.lastReplanAt = lastReplanAt
        self.lastNavVersion = lastNavVersion
        self.celebrating = celebrating
    }
}

/// 一个 Wish。
public struct Wish: Hashable, Sendable {
    public var id: WishID
    public var type: WishType
    public var wisher: ResidentID
    /// Story_Clock 创建时间，Wish_Timeout 从此起算。
    public var createdAt: Date
    public var state: WishState
    /// 仅 visit。
    public var visitTarget: VisitTarget?
    /// 仅 chair、lamp：已选定的目标 Decor。
    public var decorTarget: DecorID?
    /// 仅 chase。
    public var chase: ChaseState?
    /// 仅 lamp：进行中是否经历过 Night。为 true 后 Night 结束即为「场上前提消失」（Requirement 6.12）；
    /// 白天从 Debug_Menu 触发的 Lamp_Wish 在 Night 开始前不会因「Night 结束」被放弃（任务 7.3 设计补充）。
    public var sawNight: Bool

    public init(
        id: WishID, type: WishType, wisher: ResidentID, createdAt: Date,
        state: WishState = .active, visitTarget: VisitTarget? = nil,
        decorTarget: DecorID? = nil, chase: ChaseState? = nil, sawNight: Bool = false
    ) {
        self.id = id
        self.type = type
        self.wisher = wisher
        self.createdAt = createdAt
        self.state = state
        self.visitTarget = visitTarget
        self.decorTarget = decorTarget
        self.chase = chase
        self.sawNight = sawNight
    }

    /// Busy_Resident：flower 与 chase 两人都参与，其余只有 Wisher。
    public var participants: Set<ResidentID> {
        type == .flower || type == .chase ? [.a, .b] : [wisher]
    }
}

/// 全部 Wish 的簿记。
public struct WishBook: Hashable, Sendable {
    /// 0 至 2 个 active Wish，按 id 升序。
    public var active: [Wish]
    /// 每位居民上一个 Wish 结束（fulfilled 或 dropped）的时间，Wish_Cooldown 起点。
    public var lastEnded: [ResidentID: Date]
    /// 已开始过的 Flower_Wish 次数（Requirement 8.2）。
    public var flowerCount: Int
    /// 上一个 Flower_Wish 进入 Done 的时间。
    public var lastFlowerDoneAt: Date?
    /// 下一次检查时间；Home_Window 未分配时为 nil。
    public var nextCheckAt: Date?
    /// Wish 完成后正在播放 `celebrating` 的居民及其结束时间（任务 7.3）。到时由 `WishDirector.plan` 转回 `idle`。
    /// 不保存；不属于 Busy_Resident。
    public var celebrations: [ResidentID: Date]
    /// `celebrations` 中庆祝期间显示心形气泡的居民（Chase_Wish 结束时，Requirement 22.3）。庆祝结束的同一帧
    /// 清除心形气泡。不保存。
    public var celebrationHearts: Set<ResidentID>
    public private(set) var nextID: UInt64

    public init(
        active: [Wish] = [], lastEnded: [ResidentID: Date] = [:], flowerCount: Int = 0,
        lastFlowerDoneAt: Date? = nil, nextCheckAt: Date? = nil, celebrations: [ResidentID: Date] = [:],
        celebrationHearts: Set<ResidentID> = [], nextID: UInt64 = 1
    ) {
        self.active = active.sorted { $0.id < $1.id }
        self.lastEnded = lastEnded
        self.flowerCount = flowerCount
        self.lastFlowerDoneAt = lastFlowerDoneAt
        self.nextCheckAt = nextCheckAt
        self.celebrations = celebrations
        self.celebrationHearts = celebrationHearts
        // 保证新分配的 ID 不与已有 Wish 冲突。
        let maxID = active.map(\.id.rawValue).max() ?? 0
        self.nextID = Swift.max(nextID, maxID + 1)
    }

    /// active 中全部 participants 的并集。
    public var busy: Set<ResidentID> {
        active.reduce(into: Set<ResidentID>()) { $0.formUnion($1.participants) }
    }

    /// `r` 参与的 active Wish（作为 Wisher 或其他参与者）。不参与时为 nil。
    public func wish(of r: ResidentID) -> Wish? {
        active.first { $0.participants.contains(r) }
    }

    /// 分配一个新的、比之前都大的 WishID。
    public mutating func makeID() -> WishID {
        let id = WishID(nextID)
        nextID += 1
        return id
    }
}

/// WishDirector 产生的事件，由 WorldEngine 转成事件记录和显示效果。
public enum WishEvent: Hashable, Sendable {
    case started(Wish)
    case fulfilled(Wish, ChaseOutcome?)
    case dropped(Wish)
    case decorUnlocked(DecorType)
    case visitedWindow(ResidentID, ownerName: String)
    /// Chair_Wish、Lamp_Wish 完成时的 `sat` / `slept`，排在对应 `fulfilled` 之前（Requirement 18.2）。
    case activity(ActivityEvent)
    /// Flower_Wish 开始时 `StoryDirector.beginFlowerWish` 产生的剧情事件，排在对应 `started` 之后。
    case story(StoryEvent)
}
