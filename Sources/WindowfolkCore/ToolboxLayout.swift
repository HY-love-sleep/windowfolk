import Foundation

/// Toolbox 的取物区（Requirement 8.2，v2 Requirement 1.7、2.1）。
/// 声明顺序即从左到右的顺序：Plank 区、Ladder 区，之后是已解锁的 Decor_Slot。
public enum ToolboxZone: Hashable, Sendable {
    /// 拖出新的 Plank。
    case plank
    /// 拖出新的 Ladder。
    case ladder
    /// Decor_Slot：拖出新的该类型 Decor。
    case decor(DecorType)
}

/// Toolbox 在屏幕上的位置（Requirement 8.1、8.4，v2 Requirement 2.1、2.2、2.8）。每帧按当前
/// `visibleFrame` 和已解锁的 Decor 计算，Dock 变化后下一帧自动移到新位置。
///
/// 外框宽 `zoneWidth × zones.count`，右边距固定，新解锁的 Decor_Slot 追加在右侧、外框向左变宽。
/// `unlocked` 为空时与 v1 的两区布局完全相同。
public enum ToolboxLayout {
    /// Toolbox 右边缘与 `visibleFrame` 右边缘的距离（pt），需求上限为 16pt。
    public static let rightMargin: Double = 8

    /// 每个取物区的宽度（pt）。v1 Toolbox 宽 72 = 2 × 36。
    public static let zoneWidth: Double = SpriteMetrics.toolbox.width / 2

    /// 取物区从左到右的顺序：`[.plank, .ladder]` 后接已解锁的 Decor_Slot（按 chair、lamp 排序）。
    public static func zones(unlocked: Set<DecorType> = []) -> [ToolboxZone] {
        [.plank, .ladder] + DecorType.allCases.filter(unlocked.contains).map(ToolboxZone.decor)
    }

    /// Toolbox 外框：底边与 Ground（`visibleFrame` 底边）对齐，右边距 `rightMargin`。
    public static func frame(screen: ScreenInfo, unlocked: Set<DecorType> = []) -> Rect {
        let width = zoneWidth * Double(zones(unlocked: unlocked).count)
        let height = SpriteMetrics.toolbox.height
        return Rect(
            minX: screen.visibleFrame.maxX - rightMargin - width,
            minY: screen.groundY - height,
            width: width, height: height)
    }

    /// 取物区矩形。取物区从左到右等宽排列，相邻两区只共用一条边，相交面积为 0。
    /// `zone` 是未解锁的 Decor_Slot 时为 nil。
    public static func zoneFrame(_ zone: ToolboxZone, screen: ScreenInfo, unlocked: Set<DecorType>) -> Rect? {
        let all = zones(unlocked: unlocked)
        guard let index = all.firstIndex(of: zone) else { return nil }
        let f = frame(screen: screen, unlocked: unlocked)
        return Rect(minX: f.minX + zoneWidth * Double(index), minY: f.minY, width: zoneWidth, height: f.height)
    }

    /// v1 取物区矩形（`unlocked` 为空）。Plank 区为左半，Ladder 区为右半。
    /// 只用于始终存在的 `.plank` 与 `.ladder`；传入 Decor_Slot 属于调用错误。
    public static func zoneFrame(_ zone: ToolboxZone, screen: ScreenInfo) -> Rect {
        guard let r = zoneFrame(zone, screen: screen, unlocked: []) else {
            preconditionFailure("Decor_Slot \(zone) 需要传入 unlocked")
        }
        return r
    }

    /// 点所在的取物区；不在 Toolbox 内时为 nil。两区之间边上的点归右侧区，因此每个点最多属于一个区。
    public static func zone(at p: Point, screen: ScreenInfo, unlocked: Set<DecorType> = []) -> ToolboxZone? {
        let f = frame(screen: screen, unlocked: unlocked)
        guard f.contains(p) else { return nil }
        // 与 `zoneFrame` 用同一个表达式算各区左边，避免浮点误差让边上的点落到左侧区。
        let all = zones(unlocked: unlocked)
        return all.indices.last { p.x >= f.minX + zoneWidth * Double($0) }.map { all[$0] } ?? all[0]
    }
}
