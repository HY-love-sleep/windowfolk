import Foundation

// Item 模型与居民持有（design.md「Core：Items、Planks、Ladders」，任务 11.1）。
//
// 持有关系以居民为准：`Resident.heldItem` 指向被持有的 Item，该 Item 的 `placement` 为 `.held(居民)`。
// 每位居民最多持有 1 个 Item（Requirement 14.3），每个 Item 最多被 1 位居民持有。
// 被持有的 Item 没有自己的位置，每帧取持有者位置加 `ItemHolding.heldOffset`（Requirement 14.4），
// 因此持有者悬挂、下落、落地、爬梯、跳跃时都不会脱手（Requirement 13.3、14.5、14.6）。

/// 物件标识（design.md：UUID）。
public struct ItemID: Hashable, Sendable, Codable, Comparable {
    public var rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public static func < (lhs: ItemID, rhs: ItemID) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

/// 物件种类：花盆（Flower）或果子（Fruit）。
public enum ItemKind: Hashable, Sendable, Codable {
    /// 花盆。`storyRound` 为种下它的剧情轮次（Story_Flower）；调试菜单给的花盆为 nil。
    case flower(storyRound: Int?)
    case fruit

    public var isFlower: Bool {
        if case .flower = self { return true }
        return false
    }

    /// 是剧情花（Story_Flower）。
    public var isStoryFlower: Bool {
        if case let .flower(round) = self { return round != nil }
        return false
    }
}

/// 花的生长阶段（Growth_Stage）。只按 pot → sprout → bloom 前进（Requirement 17.4）。
public enum GrowthStage: Int, Hashable, Sendable, Codable, Comparable, CaseIterable {
    case pot = 0, sprout = 1, bloom = 2

    public static func < (lhs: GrowthStage, rhs: GrowthStage) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 名称，与素材键和 world.json 中的写法一致（`"pot"` / `"sprout"` / `"bloom"`）。
    public var name: String { assetStage.rawValue }

    // world.json 中按名称编码（design.md「world.json」示例 `"reached": "pot"`）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = GrowthStage.allCases.first(where: { $0.name == s }) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown growth stage \(s)")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }

    /// 对应的素材阶段，素材键为 `flower_pot` / `flower_sprout` / `flower_bloom`。
    public var assetStage: FlowerAssetStage {
        switch self {
        case .pot: return .pot
        case .sprout: return .sprout
        case .bloom: return .bloom
        }
    }
}

/// 花的生长数据。生长计算见任务 13.1 的 Growth。
public struct FlowerGrowth: Hashable, Sendable, Codable {
    /// 种下时间；nil 表示还没种下（抱在手上）。
    public var plantedAt: Date?
    /// 已达到的最高阶段。
    public var reached: GrowthStage

    public init(plantedAt: Date? = nil, reached: GrowthStage = .pot) {
        self.plantedAt = plantedAt
        self.reached = reached
    }
}

/// 物件当前的位置方式。
public enum ItemPlacement: Hashable, Sendable {
    /// 放在窗沿、木板或 Ground 上。
    case attached(Attachment)
    /// 被某位居民持有；位置为持有者位置加 `ItemHolding.heldOffset`。
    case held(ResidentID)
    /// 下落中。
    case falling(FallState)
    /// 被玩家拖动中；`grabOffset` 为按下时光标相对物件底边中点的偏移（任务 11.2）。
    case dragged(grabOffset: Point)

    public var holder: ResidentID? {
        if case let .held(r) = self { return r }
        return nil
    }
}

/// 一个物件。
public struct Item: Hashable, Sendable {
    public var id: ItemID
    public var kind: ItemKind
    public var placement: ItemPlacement
    /// 仅 Flower 有；Fruit 为 nil。
    public var growth: FlowerGrowth?

    public init(id: ItemID = ItemID(), kind: ItemKind, placement: ItemPlacement, growth: FlowerGrowth? = nil) {
        self.id = id
        self.kind = kind
        self.placement = placement
        self.growth = kind.isFlower ? (growth ?? FlowerGrowth()) : nil
    }

    /// 一个还没种下、阶段为 `pot` 的花盆。
    public static func flowerPot(
        id: ItemID = ItemID(), storyRound: Int? = nil, placement: ItemPlacement
    ) -> Item {
        Item(id: id, kind: .flower(storyRound: storyRound), placement: placement, growth: FlowerGrowth())
    }

    /// 一颗果子。
    public static func fruit(id: ItemID = ItemID(), placement: ItemPlacement) -> Item {
        Item(id: id, kind: .fruit, placement: placement)
    }

    /// 当前生长阶段；Fruit 为 nil。
    public var stage: GrowthStage? { growth?.reached }

    /// 素材键：Flower 按生长阶段，Fruit 为 `fruit`。
    public var assetKey: String {
        switch kind {
        case .flower: return AssetCatalog.flowerKey(growth: stage ?? .pot)
        case .fruit: return AssetCatalog.fruitKey
        }
    }
}

/// 持有规则。
public enum ItemHolding {
    /// 被持有 Item 底边中点相对持有者底边中点的固定偏移（Core 坐标，y 向下）：抱在胸前。
    public static let heldOffset = Point(x: 0, y: -12)

    /// 被持有 Item 的屏幕位置（底边中点）。
    public static func heldPosition(residentPosition p: Point) -> Point {
        Point(x: p.x + heldOffset.x, y: p.y + heldOffset.y)
    }
}

/// 全部物件的存储。
public struct ItemStore: Hashable, Sendable {
    public var items: [ItemID: Item]

    public init(items: [ItemID: Item] = [:]) {
        self.items = items
    }

    public subscript(id: ItemID) -> Item? {
        get { items[id] }
        set { items[id] = newValue }
    }

    /// 全部 ID，按顺序排列（保证确定性）。
    public var sortedIDs: [ItemID] { items.keys.sorted() }

    /// 持有某 Item 的居民。
    public func holder(of id: ItemID) -> ResidentID? {
        items[id]?.placement.holder
    }

    /// 让居民拿起一个新物件或场上已有的物件。
    ///
    /// 居民已持有 Item（Requirement 14.3）、物件已被他人持有或正在被玩家拖动（Requirement 11.9）时不改变任何状态，
    /// 返回 false。成功时物件的 placement 变为 `.held(居民)`，`r.heldItem` 指向它。
    @discardableResult
    public mutating func give(_ item: Item, to r: inout Resident) -> Bool {
        guard r.heldItem == nil else { return false }
        if let existing = items[item.id] {
            switch existing.placement {
            case .held, .dragged: return false
            case .attached, .falling: break
            }
        }
        var it = item
        it.placement = .held(r.id)
        items[it.id] = it
        r.heldItem = it.id
        return true
    }

    /// 解除居民的持有，把物件放到 `placement`（附着或下落）。居民没有持有物件时返回 nil。
    @discardableResult
    public mutating func release(from r: inout Resident, to placement: ItemPlacement) -> ItemID? {
        guard let id = r.heldItem else { return nil }
        r.heldItem = nil
        if var it = items[id] {
            it.placement = placement
            items[id] = it
        }
        return id
    }

    /// 让持有关系与居民一致：以 `Resident.heldItem` 为准。
    ///
    /// - 居民指向不在存储中的物件时保持不变（测试可只设置 `heldItem`）；
    /// - 被指向的物件 placement 改为 `.held(居民)`；两位居民指向同一物件时只保留 ID 较小的居民；
    /// - 标记为 `.held` 但持有者不存在或不指向它的物件，从 `fallback` 给出的位置开始下落。
    public mutating func reconcile(
        residents: inout [ResidentID: Resident], fallback: (ItemID) -> FallState?
    ) {
        var claimed: Set<ItemID> = []
        for rid in residents.keys.sorted() {
            guard var r = residents[rid], let iid = r.heldItem else { continue }
            if claimed.contains(iid) {
                r.heldItem = nil
                residents[rid] = r
                continue
            }
            claimed.insert(iid)
            guard items[iid] != nil else { continue }
            if items[iid]?.placement != .held(rid) { items[iid]?.placement = .held(rid) }
        }
        for iid in sortedIDs {
            guard case .held = items[iid]?.placement, !claimed.contains(iid) else { continue }
            if let f = fallback(iid) { items[iid]?.placement = .falling(f) }
        }
    }

    /// 持有关系的违规描述（测试用）：每位居民最多 1 个、每个物件最多 1 位持有者、双方指向一致。
    public func holdingViolations(residents: [ResidentID: Resident]) -> [String] {
        var out: [String] = []
        var seen: [ItemID: ResidentID] = [:]
        for rid in residents.keys.sorted() {
            guard let iid = residents[rid]?.heldItem else { continue }
            if let other = seen[iid] { out.append("\(iid) held by both \(other.rawValue) and \(rid.rawValue)") }
            seen[iid] = rid
            if let it = items[iid], it.placement != .held(rid) {
                out.append("\(rid.rawValue) holds \(iid) but placement differs")
            }
        }
        for iid in sortedIDs {
            if let h = items[iid]?.placement.holder, residents[h]?.heldItem != iid {
                out.append("\(iid) marked held by \(h.rawValue) but resident does not hold it")
            }
        }
        return out
    }
}
