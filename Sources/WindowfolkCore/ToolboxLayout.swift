import Foundation

/// Toolbox 的两个取物区（Requirement 8.2）。
public enum ToolboxZone: String, Hashable, Sendable, CaseIterable {
    /// 左半：拖出新的 Plank。
    case plank
    /// 右半：拖出新的 Ladder。
    case ladder
}

/// Toolbox 在屏幕上的位置（Requirement 8.1、8.4）。每帧按当前 `visibleFrame` 计算，
/// Dock 变化后下一帧自动移到新位置。
public enum ToolboxLayout {
    /// Toolbox 右边缘与 `visibleFrame` 右边缘的距离（pt），需求上限为 16pt。
    public static let rightMargin: Double = 8

    /// Toolbox 外框：底边与 Ground（`visibleFrame` 底边）对齐，右边距 `rightMargin`。
    public static func frame(screen: ScreenInfo) -> Rect {
        let size = SpriteMetrics.toolbox
        return Rect(
            minX: screen.visibleFrame.maxX - rightMargin - size.width,
            minY: screen.groundY - size.height,
            width: size.width, height: size.height)
    }

    /// 取物区矩形：Plank 区为左半，Ladder 区为右半。两者只共用中线，相交面积为 0。
    public static func zoneFrame(_ zone: ToolboxZone, screen: ScreenInfo) -> Rect {
        let f = frame(screen: screen)
        let half = f.width / 2
        switch zone {
        case .plank: return Rect(minX: f.minX, minY: f.minY, width: half, height: f.height)
        case .ladder: return Rect(minX: f.minX + half, minY: f.minY, width: half, height: f.height)
        }
    }

    /// 点所在的取物区；不在 Toolbox 内时为 nil。中线上的点归 Ladder 区，因此每个点最多属于一个区。
    public static func zone(at p: Point, screen: ScreenInfo) -> ToolboxZone? {
        let f = frame(screen: screen)
        guard f.contains(p) else { return nil }
        return p.x < f.midX ? .plank : .ladder
    }
}
