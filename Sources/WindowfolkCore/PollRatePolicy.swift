import Foundation

/// 一个 Game_Loop 周期的活动样本（Requirement 24.2 至 24.6）。
public struct ActivitySample: Hashable, Sendable {
    /// 样本时刻（秒，任意单调起点；`WorldEngine` 使用 Story_Clock 的 `timeIntervalSince1970`）。
    public var time: Double
    /// 本次轮询的 Eligible_Window 集合、任一窗口边界或前后层级与上一次不同。
    public var windowsChanged: Bool
    /// 任一居民的 Resident_State 或屏幕位置与上一次不同，或居民处于必须保持流畅的状态
    /// （`walking`、`carrying`、`falling`、`hanging`、`climbing` 等）；也包括其他可见画面的变化。
    public var residentsChanged: Bool
    /// 玩家拖拽（或按下）进行中，或本周期有鼠标事件。
    public var dragging: Bool

    public init(time: Double, windowsChanged: Bool, residentsChanged: Bool, dragging: Bool) {
        self.time = time
        self.windowsChanged = windowsChanged
        self.residentsChanged = residentsChanged
        self.dragging = dragging
    }

    /// 三项都为假。
    public var isQuiet: Bool { !windowsChanged && !residentsChanged && !dragging }
}

/// 轮询频率策略（Requirement 24）。纯值类型，时间由样本注入。
///
/// - 启动时为 `.active`（Requirement 24.1）。
/// - 任一样本有窗口变化、居民变化或拖拽时，下一周期为 `.active`，并清空安静计时（Requirement 24.3 至 24.6）。
/// - 从第一个安静样本起连续安静满 `quietDuration`（默认 2 秒）后为 `.idle`（Requirement 24.2）。
/// - 时间回拨时从回拨后的时刻重新计时，不会因此提前进入 `.idle`。
public struct PollRatePolicy: Hashable, Sendable {
    /// 进入 Idle_Poll_Rate 所需的连续安静时长（秒）。
    public static let defaultQuietDuration: Double = 2.0

    public var quietDuration: Double
    /// 当前这段连续安静的起点；最近一个样本不安静时为 nil。
    public private(set) var quietSince: Double?
    /// 最近一次给出的频率。
    public private(set) var current: PollRate = .active

    public init(quietDuration: Double = PollRatePolicy.defaultQuietDuration) {
        self.quietDuration = quietDuration
    }

    /// 根据本周期的样本给出下一周期的频率。
    public mutating func next(after sample: ActivitySample) -> PollRate {
        guard sample.isQuiet, sample.time.isFinite else {
            quietSince = nil
            current = .active
            return current
        }
        if let since = quietSince, sample.time >= since {
            current = sample.time - since >= quietDuration ? .idle : .active
        } else {
            quietSince = sample.time
            current = .active
        }
        return current
    }
}
