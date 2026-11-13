import Foundation

// world.json 的数据模型与编解码（design.md「Core：SaveFile 与 SaveCodec」「world.json（格式版本 1）」，任务 16.1）。
//
// 这里只有纯数据和 JSON 编解码：
// - 从 WorldState 生成存档、从存档恢复世界（snapshot / restore）属于任务 16.2；
// - 文件读写、原子写入和损坏备份属于任务 16.3。
//
// 存档内容（Requirement 22.3）：格式版本号；全部 Ground_Object 的类型、屏幕 x 和状态（花的轮次、种下时间、
// 已达阶段）；当前 Story_Stage（未开局为 null）；Story_Round 编号；最近一次进入 `Done` 的时间；
// 每位居民的屏幕 x 和持有物（无则为 null）。Home_Window 的窗口 ID 不保存，因为重启后窗口 ID 会变。
//
// 时间精度：存档中的时间写为自 1970 年起的秒数（Double），并取整到毫秒。`Date` 内部以 2001 年为基准存储，
// 换算到 1970 基准再换回时可能差最后几位，取整到毫秒后同一个时间点总能得到同一个 `Date`。
// 生成存档时用 `SaveTime.normalized(_:)` 处理时间，`decode(encode(s)) == s` 就对所有存档成立（Requirement 22.13）。
//
// V2（格式版本 2，V2 design.md「world.json（格式版本 2）」，任务 10.1）：居民新增 Walk_Distance 和上一个 Wish
// 结束时间；Ground_Object 新增 chair、lamp；新增 `wishBook`（Unlocked_Decor、Flower_Wish 次数、上一个
// Flower_Wish 进入 Done 的时间、非 chase 的 active Wish）。版本号不是 2 的存档一律 `.versionMismatch`，不做迁移。

// MARK: - 时间

/// 存档时间的取整规则。
public enum SaveTime {
    /// 把时间取整到 1970 基准下的整毫秒。对已取整的时间是恒等变换。
    public static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: seconds(date))
    }

    /// 写入 JSON 的秒数：自 1970 年起，取整到毫秒。
    public static func seconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded() / 1000
    }
}

// MARK: - 数据模型

/// 存档中的剧情状态。
public struct SavedStory: Hashable, Sendable, Codable {
    /// 当前阶段；nil 表示未开局。
    ///
    /// 生成存档时 `planting` 存为 `travel`、`bloomed` 存为 `returnGift`（见 `persistedStage(_:)`），
    /// 但解码时仍接受全部阶段名称。
    public var stage: StoryStage?
    /// Story_Round 编号，>= 1。
    public var round: Int
    /// 最近一次进入 `Done` 的时间。
    public var doneAt: Date?

    public init(stage: StoryStage?, round: Int, doneAt: Date?) {
        self.stage = stage
        self.round = round
        self.doneAt = doneAt
    }

    /// 写入存档时使用的阶段（design.md「world.json」）：
    /// `planting` 存为 `travel`（花仍在 Giver 手上），`bloomed` 存为 `returnGift`（Receiver 带着 Fruit）。
    /// 这两个阶段持续很短，恢复时不需要动画中间状态。
    public static func persistedStage(_ stage: StoryStage?) -> StoryStage? {
        switch stage {
        case .planting?: return .travel
        case .bloomed?: return .returnGift
        default: return stage
        }
    }

    enum CodingKeys: String, CodingKey { case stage, round, doneAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decodeIfPresent(StoryStage.self, forKey: .stage)
        round = try c.decode(Int.self, forKey: .round)
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
    }

    // 空值显式写 null，让存档的字段集合固定（design.md 示例 `"doneAt": null`）。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let stage { try c.encode(stage, forKey: .stage) } else { try c.encodeNil(forKey: .stage) }
        try c.encode(round, forKey: .round)
        if let doneAt { try c.encode(doneAt, forKey: .doneAt) } else { try c.encodeNil(forKey: .doneAt) }
    }
}

/// 存档中花的状态。
public struct SavedFlower: Hashable, Sendable, Codable {
    /// 种下它的剧情轮次（Story_Flower）；调试菜单给的花盆为 nil。
    public var storyRound: Int?
    /// 种下时间；nil 表示还没种下。
    public var plantedAt: Date?
    /// 已达到的最高 Growth_Stage。
    public var reached: GrowthStage

    public init(storyRound: Int?, plantedAt: Date?, reached: GrowthStage) {
        self.storyRound = storyRound
        self.plantedAt = plantedAt
        self.reached = reached
    }

    /// 生长数据部分。
    public var growth: FlowerGrowth { FlowerGrowth(plantedAt: plantedAt, reached: reached) }
}

/// 可被持有的物件种类。
public enum SavedItemKind: String, Hashable, Sendable, Codable, CaseIterable {
    case flower, fruit
}

/// 居民持有的物件。
public struct SavedHeldItem: Hashable, Sendable, Codable {
    /// 物件 ID（`ItemID` 的 UUID 字符串）。
    public var id: String
    public var kind: SavedItemKind
    /// 仅 `flower` 有。
    public var flower: SavedFlower?

    public init(id: String, kind: SavedItemKind, flower: SavedFlower? = nil) {
        self.id = id
        self.kind = kind
        self.flower = kind == .flower ? flower : nil
    }
}

/// 存档中的一位居民。
public struct SavedResident: Hashable, Sendable, Codable {
    public var id: ResidentID
    /// 保存时刻的屏幕 x。
    public var x: Double
    /// 持有的物件；没有时为 nil。
    public var heldItem: SavedHeldItem?
    /// Walk_Distance（V2 Requirement 15.1、15.10）。
    public var walkDistance: Double
    /// 上一个 Wish 变为 `fulfilled` 或 `dropped` 的时间；从未结束过 Wish 时为 nil（V2 Requirement 15.1、15.9）。
    public var lastWishEndedAt: Date?

    public init(
        id: ResidentID, x: Double, heldItem: SavedHeldItem? = nil,
        walkDistance: Double = 0, lastWishEndedAt: Date? = nil
    ) {
        self.id = id
        self.x = x
        self.heldItem = heldItem
        self.walkDistance = walkDistance
        self.lastWishEndedAt = lastWishEndedAt
    }

    enum CodingKeys: String, CodingKey { case id, x, heldItem, walkDistance, lastWishEndedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ResidentID.self, forKey: .id)
        x = try c.decode(Double.self, forKey: .x)
        // 未知种类的持有物跳过（design.md「存档中引用未知的 Item 类型」）。
        heldItem = try c.decodeIfPresent(Lossy<SavedHeldItem>.self, forKey: .heldItem)?.value
        walkDistance = try c.decode(Double.self, forKey: .walkDistance)
        lastWishEndedAt = try c.decodeIfPresent(Date.self, forKey: .lastWishEndedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(x, forKey: .x)
        if let heldItem { try c.encode(heldItem, forKey: .heldItem) } else { try c.encodeNil(forKey: .heldItem) }
        try c.encode(walkDistance, forKey: .walkDistance)
        if let lastWishEndedAt {
            try c.encode(lastWishEndedAt, forKey: .lastWishEndedAt)
        } else {
            try c.encodeNil(forKey: .lastWishEndedAt)
        }
    }
}

/// Ground_Object 的种类。V2 新增 chair、lamp（Decor 按 Ground_Object 记录，Requirement 15.1）。
public enum SavedObjectKind: String, Hashable, Sendable, Codable, CaseIterable {
    case flower, fruit, plank, ladder, chair, lamp
}

/// 存档中的一个 active Wish（V2 Requirement 15.1）。
///
/// Chase_Wish 不写入存档（Requirement 15.11）：解码时 `chase` 和未知类型都跳过（见 `SavedWishBook`），
/// `SavedWishBook.init` 也会丢弃 chase。
public struct SavedWish: Hashable, Sendable, Codable {
    public var type: WishType
    public var wisher: ResidentID
    /// Story_Clock 创建时间。
    public var createdAt: Date
    /// Visit_Target 所属应用名称；仅 `visit` 有，其他类型总为 nil。
    public var visitTargetApp: String?

    public init(type: WishType, wisher: ResidentID, createdAt: Date, visitTargetApp: String? = nil) {
        self.type = type
        self.wisher = wisher
        self.createdAt = createdAt
        self.visitTargetApp = type == .visit ? visitTargetApp : nil
    }

    enum CodingKeys: String, CodingKey { case type, wisher, createdAt, visitTargetApp }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(WishType.self, forKey: .type)
        guard type != .chase else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "chase wishes are not persisted")
        }
        let app = try c.decodeIfPresent(String.self, forKey: .visitTargetApp)
        if type == .visit, app == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .visitTargetApp, in: c, debugDescription: "visit wish without visitTargetApp")
        }
        self.init(type: type, wisher: try c.decode(ResidentID.self, forKey: .wisher),
                  createdAt: try c.decode(Date.self, forKey: .createdAt), visitTargetApp: app)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(wisher, forKey: .wisher)
        try c.encode(createdAt, forKey: .createdAt)
        if let visitTargetApp {
            try c.encode(visitTargetApp, forKey: .visitTargetApp)
        } else {
            try c.encodeNil(forKey: .visitTargetApp)
        }
    }

    /// 存档中的排序：按 (createdAt, wisher)。
    static func ordered(_ a: SavedWish, _ b: SavedWish) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.wisher < b.wisher
    }
}

/// 存档中的 WishBook（V2 Requirement 15.1）。
public struct SavedWishBook: Hashable, Sendable, Codable {
    /// Unlocked_Decor，去重并按 `DecorType` 顺序排序。
    public var unlockedDecor: [DecorType]
    /// 已开始过的 Flower_Wish 次数（含当前 active 的那次）。
    public var flowerCount: Int
    /// 上一个 Flower_Wish 进入 `Done` 的时间；从未进入时为 nil。
    public var lastFlowerDoneAt: Date?
    /// 非 chase 的 active Wish，按 (createdAt, wisher) 排序。
    public var activeWishes: [SavedWish]

    /// 创建时去重排序 `unlockedDecor`、丢弃 chase、排序 `activeWishes`，保证同一状态总得到同一份存档。
    public init(
        unlockedDecor: [DecorType] = [], flowerCount: Int = 0,
        lastFlowerDoneAt: Date? = nil, activeWishes: [SavedWish] = []
    ) {
        self.unlockedDecor = Set(unlockedDecor).sorted()
        self.flowerCount = flowerCount
        self.lastFlowerDoneAt = lastFlowerDoneAt
        self.activeWishes = activeWishes.filter { $0.type != .chase }.sorted(by: SavedWish.ordered)
    }

    enum CodingKeys: String, CodingKey { case unlockedDecor, flowerCount, lastFlowerDoneAt, activeWishes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 未知值丢弃、重复值去重（Requirement 1.9）。
        let decor = try c.decode([String].self, forKey: .unlockedDecor).compactMap(DecorType.init(rawValue:))
        // 未知类型和 chase 跳过（Requirement 15.1、15.11；design.md「Error Handling」）。
        let wishes = try c.decode([Lossy<SavedWish>].self, forKey: .activeWishes).compactMap(\.value)
        self.init(
            unlockedDecor: decor,
            flowerCount: try c.decode(Int.self, forKey: .flowerCount),
            lastFlowerDoneAt: try c.decodeIfPresent(Date.self, forKey: .lastFlowerDoneAt),
            activeWishes: wishes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unlockedDecor, forKey: .unlockedDecor)
        try c.encode(flowerCount, forKey: .flowerCount)
        if let lastFlowerDoneAt {
            try c.encode(lastFlowerDoneAt, forKey: .lastFlowerDoneAt)
        } else {
            try c.encodeNil(forKey: .lastFlowerDoneAt)
        }
        try c.encode(activeWishes, forKey: .activeWishes)
    }
}

/// 存档中的一个 Ground_Object。保存时窗沿和 Plank 上的物件、全部 Plank 和 Ladder 都归一为 Ground_Object
/// （Requirement 22.4），恢复时从屏幕上方落到 Ground 上的 x 处。
public struct SavedObject: Hashable, Sendable, Codable {
    /// 对象 ID：Item 为 UUID 字符串，Plank 和 Ladder 为其数字 ID 的字符串。
    public var id: String
    public var kind: SavedObjectKind
    /// 保存时刻的屏幕 x（Plank 取两端中点，Ladder 取下端）。
    public var x: Double
    /// 仅 `flower` 有。
    public var flower: SavedFlower?

    public init(id: String, kind: SavedObjectKind, x: Double, flower: SavedFlower? = nil) {
        self.id = id
        self.kind = kind
        self.x = x
        self.flower = kind == .flower ? flower : nil
    }
}

/// world.json 的完整内容。
public struct SaveFile: Hashable, Sendable, Codable {
    public var version: Int
    public var savedAt: Date
    public var story: SavedStory
    /// 按 `ResidentID` 排序。
    public var residents: [SavedResident]
    /// 按 id 排序。
    public var groundObjects: [SavedObject]
    /// V2：Unlocked_Decor、Flower_Wish 次数与 active Wish（Requirement 15.1）。
    public var wishBook: SavedWishBook

    /// 创建存档；居民和 Ground_Object 按 ID 排序，保证同一世界总得到同一份存档。
    public init(
        version: Int = SaveCodec.currentVersion,
        savedAt: Date,
        story: SavedStory,
        residents: [SavedResident],
        groundObjects: [SavedObject],
        wishBook: SavedWishBook = SavedWishBook()
    ) {
        self.version = version
        self.savedAt = savedAt
        self.story = story
        self.residents = residents.sorted { $0.id < $1.id }
        self.groundObjects = groundObjects.sorted { $0.id < $1.id }
        self.wishBook = wishBook
    }

    enum CodingKeys: String, CodingKey { case version, savedAt, story, residents, groundObjects, wishBook }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        story = try c.decode(SavedStory.self, forKey: .story)
        residents = try c.decode([SavedResident].self, forKey: .residents)
        // 未知种类的 Ground_Object 跳过，其余照常恢复（design.md「Error Handling」）。
        groundObjects = try c.decode([Lossy<SavedObject>].self, forKey: .groundObjects).compactMap(\.value)
        wishBook = try c.decode(SavedWishBook.self, forKey: .wishBook)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(savedAt, forKey: .savedAt)
        try c.encode(story, forKey: .story)
        try c.encode(residents, forKey: .residents)
        try c.encode(groundObjects, forKey: .groundObjects)
        try c.encode(wishBook, forKey: .wishBook)
    }
}

// MARK: - 编解码

/// 存档编解码错误。任务 16.3 遇到任一错误都会备份原文件并按首次启动开局（Requirement 22.12）。
public enum SaveCodecError: Error, Hashable, Sendable {
    /// 格式版本号与当前版本不一致。
    case versionMismatch(found: Int)
    /// 不是合法的存档 JSON。
    case invalidData(String)
}

/// world.json 的编解码。
public enum SaveCodec {
    /// 当前格式版本。V2 为 2；v1 存档解码时抛 `.versionMismatch`（V2 Requirement 15.5）。
    public static let currentVersion = 2

    /// 编码为 JSON（键排序、缩进，便于比对）。
    public static func encode(_ s: SaveFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(SaveTime.seconds(date))
        }
        return try encoder.encode(s)
    }

    /// 解码 JSON。先检查版本号：版本不符抛 `.versionMismatch`，不是合法存档抛 `.invalidData`。
    public static func decode(_ d: Data) throws -> SaveFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            return Date(timeIntervalSince1970: try c.decode(Double.self))
        }
        let header: VersionHeader
        do {
            header = try decoder.decode(VersionHeader.self, from: d)
        } catch {
            throw SaveCodecError.invalidData(String(describing: error))
        }
        guard header.version == currentVersion else {
            throw SaveCodecError.versionMismatch(found: header.version)
        }
        do {
            return try decoder.decode(SaveFile.self, from: d)
        } catch {
            throw SaveCodecError.invalidData(String(describing: error))
        }
    }

    private struct VersionHeader: Decodable { var version: Int }
}

// MARK: - 内部工具

/// 种类未知时解码为 nil，种类已知但内容不合法时照常抛错。
private struct Lossy<T: Decodable>: Decodable {
    var value: T?

    private enum KindKey: String, CodingKey { case kind, type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: KindKey.self)
        let known: Bool
        switch T.self {
        case is SavedObject.Type:
            known = SavedObjectKind(rawValue: try c.decode(String.self, forKey: .kind)) != nil
        case is SavedHeldItem.Type:
            known = SavedItemKind(rawValue: try c.decode(String.self, forKey: .kind)) != nil
        case is SavedWish.Type:
            // Chase_Wish 不恢复，与未知类型一样跳过（Requirement 15.11）。
            let type = WishType(rawValue: try c.decode(String.self, forKey: .type))
            known = type != nil && type != .chase
        default: known = true
        }
        value = known ? try T(from: decoder) : nil
    }
}
