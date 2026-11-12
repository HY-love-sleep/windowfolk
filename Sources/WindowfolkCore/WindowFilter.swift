import Foundation

public enum WindowFilter {
    /// 把原始窗口列表过滤为一次轮询结果。纯函数。
    ///
    /// - Parameters:
    ///   - onScreen: 按从前到后排序的屏上窗口列表
    ///   - all: 含最小化和其他桌面空间的全部窗口
    ///   - ownPID: 本进程 pid，其窗口（含 Overlay）被排除（Requirement 1.6）
    ///   - screen: 主显示器信息；中心点不在 `screen.frame` 内的窗口被排除（Requirement 2.6）
    ///   - minSize: Min_Window_Size，宽高都不小于该值才保留
    /// - Returns: `.success`，`eligible` 保持输入顺序、`zIndex` 从 0 连续编号；
    ///   `existingIDs` 为 `all` 的全部 ID（Requirement 2.7）。
    public static func makeResult(
        onScreen: [RawWindowInfo], all: [RawWindowInfo],
        ownPID: Int32, screen: ScreenInfo, minSize: Double
    ) -> WindowPollResult {
        var eligible: [WindowSnapshot] = []
        for raw in onScreen where isEligible(raw, ownPID: ownPID, screen: screen, minSize: minSize) {
            eligible.append(WindowSnapshot(
                id: raw.id,
                ownerName: raw.ownerName,
                ownerPID: raw.ownerPID,
                frame: raw.bounds,
                zIndex: eligible.count
            ))
        }
        return .success(eligible: eligible, existingIDs: Set(all.map(\.id)))
    }

    /// 单个条目是否为 Eligible_Window（Requirement 2.1）。
    public static func isEligible(
        _ raw: RawWindowInfo, ownPID: Int32, screen: ScreenInfo, minSize: Double
    ) -> Bool {
        let b = raw.bounds
        // 丢弃非法几何：NaN、无穷或负尺寸
        guard b.minX.isFinite, b.minY.isFinite, b.width.isFinite, b.height.isFinite,
              b.width >= 0, b.height >= 0 else { return false }
        guard raw.layer == 0 else { return false }
        guard raw.alpha > 0 else { return false }  // NaN 也在此被排除
        guard b.width >= minSize, b.height >= minSize else { return false }
        guard raw.ownerPID != ownPID else { return false }
        return screen.frame.contains(b.center)
    }
}
