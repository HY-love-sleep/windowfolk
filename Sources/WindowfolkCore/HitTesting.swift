import Foundation

/// 鼠标命中的对象。
public enum HitTarget: Hashable, Sendable {
    case resident(ResidentID)
    case item(ItemID)
    case plank(PlankID)
    case ladder(LadderID)
    case toolbox(ToolboxZone)

    /// 命中优先级，数值越小越优先：Resident > Item > Plank / Ladder > Toolbox（design.md）。
    public var priority: Int {
        switch self {
        case .resident: return 0
        case .item: return 1
        case .plank, .ladder: return 2
        case .toolbox: return 3
        }
    }
}

/// 一个对象的命中区域：其当前帧显示图形的外接矩形（Requirement 7.1）。
public struct HitRegion: Hashable, Sendable {
    public var target: HitTarget
    public var rect: Rect

    public init(target: HitTarget, rect: Rect) {
        self.target = target
        self.rect = rect
    }
}

public enum HitTesting {
    /// 在给定命中区域中查找点 `p` 命中的对象。只有落在外接矩形内（含边）才算命中。
    /// 多个区域重叠时按 `HitTarget.priority` 取最优先者；同优先级时取 `regions` 中靠前的一个
    /// （调用方按绘制顺序从上到下排列，即后绘制、在上层的对象排在前面）。
    public static func hitTest(_ p: Point, regions: [HitRegion]) -> HitTarget? {
        var best: HitRegion?
        for region in regions where region.rect.contains(p) {
            if best == nil || region.target.priority < best!.target.priority {
                best = region
            }
        }
        return best?.target
    }

    /// 由世界快照算出命中区域：可见居民和 Toolbox 的两个取物区。
    /// Item、Plank、Ladder 的区域由任务 6.10 / 9 / 11 在 `WorldView` 中加入后一并输出，
    /// 它们使用 `SpriteMetrics` 中对应的外接矩形函数。
    public static func regions(for world: WorldView) -> [HitRegion] {
        var regions: [HitRegion] = []
        for r in world.residents {
            guard !r.isHidden, let p = r.position else { continue }
            regions.append(HitRegion(target: .resident(r.id), rect: SpriteMetrics.residentRect(bottomCenter: p)))
        }
        for zone in ToolboxZone.allCases {
            regions.append(HitRegion(target: .toolbox(zone), rect: ToolboxLayout.zoneFrame(zone, screen: world.screen)))
        }
        return regions
    }

    /// `hitTest(_:regions:)` 作用于 `regions(for:)`。
    /// Toolbox 中线上的点按 `ToolboxLayout.zone(at:)` 归 Ladder 区。
    public static func hitTest(_ p: Point, world: WorldView) -> HitTarget? {
        let target = hitTest(p, regions: regions(for: world))
        if case .toolbox = target {
            return ToolboxLayout.zone(at: p, screen: world.screen).map(HitTarget.toolbox)
        }
        return target
    }
}
