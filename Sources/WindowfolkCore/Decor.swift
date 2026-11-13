import Foundation

// Decor 模型与 DecorStore（design.md「Core：Decor 与 DecorStore」，任务 2.1）。
//
// - 从 Decor_Slot 拖出时立即在 `DecorStore` 中新建一个 `dragged(fresh: true)` 的 Decor，
//   因此 `count` 天然包含拖动中的 Decor，上限判断只看 `count`（Requirement 2.6）。
// - `unlock` 只增不减，`DecorStore` 没有任何移除解锁项的方法；只有 `resetWorld`
//   整体重建 `DecorStore()`（Requirement 1.5）。
// - Decor 不进入 `SurfaceBuilder` 和 `NavGraph.build` 的输入，不阻挡任何边，
//   重叠也不受限（Requirement 3.11）。本类型因此不提供任何碰撞或占位信息。
// - 上限 Max_Decor_Count 由调用方传入（`Tunables.maxDecorCount`）。

/// Decor 种类。声明顺序即 Toolbox 中 Decor_Slot 的顺序：先 chair 后 lamp。
public enum DecorType: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case chair, lamp

    /// 按声明顺序比较（chair < lamp）。
    public static func < (lhs: DecorType, rhs: DecorType) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int {
        switch self {
        case .chair: return 0
        case .lamp: return 1
        }
    }
}

/// Decor 标识。整数，单调递增分配，事件记录中写作 `decor:<n>`。
public struct DecorID: Hashable, Sendable, Codable, Comparable {
    public var rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: DecorID, rhs: DecorID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Decor 当前的位置方式。
public enum DecorPlacement: Hashable, Sendable {
    /// 放在窗沿、木板或 Ground 上（`.window` / `.plank` / `.ground`）。
    case attached(Attachment)
    /// 下落中。`byPlayer` 为 true 表示玩家松手后下落，落地时写 `decor_placed`；被动下落为 false。
    case falling(FallState, byPlayer: Bool)
    /// 被玩家拖动中。`grabOffset` 为按下时光标相对 Decor 底边中点的偏移；
    /// `fresh` 为 true 表示刚从 Decor_Slot 拖出、从未放置过。
    case dragged(grabOffset: Point, fresh: Bool)

    public var isDragged: Bool {
        if case .dragged = self { return true }
        return false
    }
}

/// 一个 Decor。
public struct Decor: Hashable, Sendable {
    public var id: DecorID
    public var type: DecorType
    public var placement: DecorPlacement
    /// 最近一次落到某条 Surface 上的序号，越小越早。从未放置过为 0。
    public var placedSeq: UInt64

    public init(id: DecorID, type: DecorType, placement: DecorPlacement, placedSeq: UInt64 = 0) {
        self.id = id
        self.type = type
        self.placement = placement
        self.placedSeq = placedSeq
    }
}

/// 全部 Decor 与 Unlocked_Decor 的存储。
public struct DecorStore: Hashable, Sendable {
    public var decors: [DecorID: Decor]
    /// Unlocked_Decor：只增不减。按 design.md 保持 `public var`；修改请只通过 `unlock`，
    /// 或在恢复存档时通过 `init(unlocked:)` 整体构造。
    public var unlocked: Set<DecorType>
    public private(set) var nextID: UInt64
    public private(set) var nextSeq: UInt64

    public init(
        decors: [DecorID: Decor] = [:], unlocked: Set<DecorType> = [],
        nextID: UInt64 = 1, nextSeq: UInt64 = 1
    ) {
        self.decors = decors
        self.unlocked = unlocked
        // 保证新分配的 ID 和序号不与已有 Decor 冲突。
        let maxID = decors.keys.map(\.rawValue).max() ?? 0
        let maxSeq = decors.values.map(\.placedSeq).max() ?? 0
        self.nextID = Swift.max(nextID, maxID + 1)
        self.nextSeq = Swift.max(nextSeq, maxSeq + 1)
    }

    /// 场上 Decor 数量，含拖动中的 Decor（Requirement 2.6）。
    public var count: Int { decors.count }

    /// 把 `t` 加入 Unlocked_Decor。新加入时返回 true（调用方据此写 `decor_unlocked`），已在集合中返回 false。
    @discardableResult
    public mutating func unlock(_ t: DecorType) -> Bool {
        unlocked.insert(t).inserted
    }

    /// 从 Decor_Slot 拖出时新建一个 `dragged(grabOffset, fresh: true)` 的 Decor。
    /// `count >= max` 时不新建，返回 nil（Requirement 2.3、2.4、2.6）。
    public mutating func makeDecor(_ t: DecorType, grabOffset: Point, max: Int) -> DecorID? {
        guard count < max else { return nil }
        let id = DecorID(nextID)
        nextID += 1
        decors[id] = Decor(id: id, type: t, placement: .dragged(grabOffset: grabOffset, fresh: true))
        return id
    }

    /// Decor 落到某条 Surface 上时调用：更新 `placedSeq` 为新的、比之前都大的序号。不存在时什么也不做。
    public mutating func markPlaced(_ id: DecorID) {
        guard decors[id] != nil else { return }
        decors[id]?.placedSeq = nextSeq
        nextSeq += 1
    }

    /// 全部 Decor 的 ID，升序。
    public var sortedIDs: [DecorID] { decors.keys.sorted() }
}
