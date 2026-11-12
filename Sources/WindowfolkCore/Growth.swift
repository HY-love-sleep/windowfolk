import Foundation

// 花的生长计算（design.md「Core：Growth」，任务 13.1）。
//
// Story_Clock 是墙上时间：每帧由 `FrameInput.now` 传入，测试可传任意手动推进的时间（Requirement 27.5）。
// 生长只看种下时间和当前时间，与花放在窗沿、Ground、Plank 还是隐藏窗口上无关（Requirement 17.3）。
// 快进改 `plantedAt` 而不改时钟（design.md「快进改数据而不改时钟」）。

public enum Growth {
    /// 已生长时长对应的阶段（Requirement 17.1）：
    /// `elapsed < 0.5B` 为 pot，`0.5B <= elapsed < B` 为 sprout，`elapsed >= B` 为 bloom。
    /// 负时长（时钟回拨到种下之前）和 NaN 按 pot 处理。
    public static func stage(elapsed: Double, bloomDuration: Double) -> GrowthStage {
        if elapsed >= bloomDuration { return .bloom }
        if elapsed >= bloomDuration * 0.5 { return .sprout }
        return .pot
    }

    /// 按当前时间推进生长：`reached = max(reached, stage(now - plantedAt))`，时钟回拨时不倒退（Requirement 17.4）。
    ///
    /// 返回本次新进入的阶段（一次跨过多个阶段时返回最终阶段）；阶段没变或还没种下时返回 nil。
    @discardableResult
    public static func advance(_ g: inout FlowerGrowth, now: Date, bloomDuration: Double) -> GrowthStage? {
        guard let planted = g.plantedAt else { return nil }
        let current = stage(elapsed: now.timeIntervalSince(planted), bloomDuration: bloomDuration)
        guard current > g.reached else { return nil }
        g.reached = current
        return current
    }

    /// 让花立即进入恰好下一个阶段（Requirement 17.5）：
    /// 当前为 pot 时把 `plantedAt` 设为 `now - 0.5B`，为 sprout 时设为 `now - B`，然后调用 `advance`。
    /// 已经是 bloom 或还没种下时不变。
    ///
    /// 「当前阶段」取 `reached` 与按当前时间算出的阶段中较大者，保证快进后已生长时长恰好等于新阶段的起点。
    public static func fastForward(_ g: inout FlowerGrowth, now: Date, bloomDuration: Double) {
        guard let planted = g.plantedAt else { return }
        let current = max(g.reached, stage(elapsed: now.timeIntervalSince(planted), bloomDuration: bloomDuration))
        switch current {
        case .pot: g.plantedAt = now.addingTimeInterval(-bloomDuration * 0.5)
        case .sprout: g.plantedAt = now.addingTimeInterval(-bloomDuration)
        case .bloom: return
        }
        advance(&g, now: now, bloomDuration: bloomDuration)
    }
}
