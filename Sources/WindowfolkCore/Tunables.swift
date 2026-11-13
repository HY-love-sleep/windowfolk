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
    // V2
    public var wishCheckInterval = 10.0, wishCooldown = 180.0, wishTimeout = 1800.0, wishSpawnChance = 0.3
    public var tiredWalkDistance = 2000.0
    /// Night_Start、Night_End：一天中的秒数（默认 19:00:00 与次日 06:00:00）。
    public var nightStart = 19 * 3600, nightEnd = 6 * 3600
    public var lampRange = 80.0, sitDuration = 20.0
    public var activityMinDuration = 15.0, activityMaxDuration = 60.0, activityReachTimeout = 60.0
    public var visitStayDuration = 5.0
    public var maxDecorCount = 20, toolboxReturnDistance = 24.0
    public var thoughtMinInterval = 600.0, thoughtDisplayDuration = 6.0, thoughtMaxLength = 24
    public var llmRequestTimeout = 15.0, diaryMaxLength = 300
    public var chaseReadyDuration = 2.0, chaseDuration = 60.0
    public var chaserSpeedFactor = 1.6, runnerSpeedFactor = 1.5
    public var catchDistance = 16.0, chaseReplanInterval = 0.5, fleeEdgeInset = 8.0
    // V2 设计新增
    public var toolboxShakeDuration = 0.4, recentEventCount = 20

    public init() {}

    /// 搬运速度：walkSpeed × carrySpeedRatio（Requirement 14.2 要求 0 < ratio <= 0.8）。
    public var carrySpeed: Double { walkSpeed * carrySpeedRatio }
}
