import Foundation

// 剧情状态（design.md「Core：StoryDirector」，任务 13.3）。

/// 剧情阶段（Story_Stage）。
public enum StoryStage: String, Hashable, Sendable, Codable, CaseIterable {
    case wish, waiting, travel, planting, growing, bloomed, returnGift, done
}

/// 剧情状态。由 `StoryDirector.update` 推进。
public struct StoryState: Hashable, Sendable {
    /// 当前阶段；nil 表示未开局（合格窗口不足两个时两人在 Ground 上活动，Requirement 15.6）。
    public var stage: StoryStage?
    /// 当前 Story_Round 编号，>= 1。
    public var round: Int
    /// 开局时分配的 Home_Window。只用于开局落位，不保存（design.md「world.json」）。
    public var homes: [ResidentID: WindowID]
    /// 本轮的 Story_Flower。
    public var currentFlower: ItemID?
    /// 本轮的 Fruit。
    public var currentFruit: ItemID?
    /// 种花动画已累计时长（秒）。只在两人所在窗口都可见时累加（Requirement 16.14）。
    public var plantingElapsed: Double
    /// 最近一次进入 `Done` 的时间。
    public var doneAt: Date?
    /// `celebrating` 动画已播放时长（秒），进入 `Done` 时清零。
    public var celebrateElapsed: Double
    /// 心形气泡剩余显示时间（秒）。
    public var heartRemaining: Double
    /// 未开局时已把两人放到 Ground 上（Requirement 15.6，只放一次）。
    public var groundPlaced: Bool

    public init(
        stage: StoryStage? = nil, round: Int = 1, homes: [ResidentID: WindowID] = [:],
        currentFlower: ItemID? = nil, currentFruit: ItemID? = nil, plantingElapsed: Double = 0,
        doneAt: Date? = nil, celebrateElapsed: Double = 0, heartRemaining: Double = 0,
        groundPlaced: Bool = false
    ) {
        self.stage = stage
        self.round = max(round, 1)
        self.homes = homes
        self.currentFlower = currentFlower
        self.currentFruit = currentFruit
        self.plantingElapsed = plantingElapsed
        self.doneAt = doneAt
        self.celebrateElapsed = celebrateElapsed
        self.heartRemaining = heartRemaining
        self.groundPlaced = groundPlaced
    }

    /// 本轮的 Giver（Requirement 19.5）。
    public var giver: ResidentID { StoryDirector.giver(round: round) }
    /// 本轮的 Receiver。
    public var receiver: ResidentID { StoryDirector.receiver(round: round) }
}

/// StoryDirector 产生的剧情事件，供事件记录（任务 14.3）和渲染使用。
public enum StoryEvent: Hashable, Sendable {
    /// 新一轮开始（进入 `Wish`）。
    case roundStarted(round: Int, giver: ResidentID, receiver: ResidentID)
    /// 阶段变化。
    case stageChanged(from: StoryStage?, to: StoryStage)
    /// 种花完成（进入 `Growing`）。
    case planted(flower: ItemID, giver: ResidentID, receiver: ResidentID)
    /// Story_Flower 进入 `sprout`。
    case sprouted(flower: ItemID)
    /// Story_Flower 进入 `bloom`。
    case bloomed(flower: ItemID)
    /// Fruit 送达（进入 `Done`）。
    case giftDelivered(fruit: ItemID, from: ResidentID, to: ResidentID)
    /// 超过 Max_Story_Flowers 时被移除的最早一朵花（Requirement 19.4）。
    case flowerEvicted(flower: ItemID)
}
