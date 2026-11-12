import Foundation

/// 集中定义的可调数值常量（Tunable_Constant）。默认值需试玩后调整。
/// Idle_CPU_Budget 是验收指标，不放进代码常量。
public struct Tunables: Hashable, Sendable, Codable {
    public var minWindowSize = 120.0
    public var smallJumpMaxRise = 24.0, smallJumpMaxGap = 16.0
    public var dropMaxHeight = 120.0
    public var plankMaxSpan = 160.0, plankMaxRise = 40.0
    public var ladderLength = 200.0
    public var hangDuration = 1.5
    public var bloomDuration = 180.0
    public var activePollRate = 30.0, idlePollRate = 10.0
    public var autosaveInterval = 30.0
    public var giftReachDistance = 32.0
    public var roundInterval = 120.0
    public var maxStoryFlowers = 5
    public var clickDragThreshold = 4.0
    public var dropSnapDistance = 24.0
    public var groundWanderRange = 40.0
    public var plantAnimationDuration = 2.0
    // 设计新增
    public var fallGravity = 2000.0
    public var walkSpeed = 40.0, carrySpeedRatio = 0.7, climbSpeed = 30.0
    public var pokeJumpHeight = 12.0, pokeJumpDuration = 0.4, pokeBubbleDuration = 1.5

    public init() {}

    /// 搬运速度：walkSpeed × carrySpeedRatio（Requirement 14.2 要求 0 < ratio <= 0.8）。
    public var carrySpeed: Double { walkSpeed * carrySpeedRatio }
}
