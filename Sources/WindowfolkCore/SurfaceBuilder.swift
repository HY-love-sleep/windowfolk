import Foundation

/// Surface 的标识。排序规则（用于确定性输出）：`ground` 最前，其后是 Window_Ledge（按窗口 ID、段序号升序），
/// 最后是 Plank（按 PlankID 升序）。
public enum SurfaceID: Hashable, Sendable, Comparable {
    case ground
    /// 同一窗口的各段按 minX 升序编号，从 0 开始。
    case ledge(WindowID, index: Int)
    /// 已架设木板形成的 Surface。
    case plank(PlankID)

    private var kindRank: Int {
        switch self {
        case .ground: return 0
        case .ledge: return 1
        case .plank: return 2
        }
    }

    public static func < (lhs: SurfaceID, rhs: SurfaceID) -> Bool {
        switch (lhs, rhs) {
        case let (.ledge(wa, ia), .ledge(wb, ib)):
            return wa != wb ? wa < wb : ia < ib
        case let (.plank(pa), .plank(pb)):
            return pa < pb
        default:
            return lhs.kindRank < rhs.kindRank
        }
    }

    /// Window_Ledge 所属窗口 ID；Ground 和 Plank 为 nil。
    public var windowID: WindowID? {
        if case let .ledge(w, _) = self { return w }
        return nil
    }

    public var isLedge: Bool {
        if case .ledge = self { return true }
        return false
    }

    public var plankID: PlankID? {
        if case let .plank(p) = self { return p }
        return nil
    }
}

/// 居民可以站立和行走的线段（Core 坐标，y 向下）。
/// Window_Ledge 和 Ground 是水平的（`start.y == end.y`）；Plank 可能倾斜。
public struct Surface: Hashable, Sendable {
    public var id: SurfaceID
    /// 左端点
    public var start: Point
    /// 右端点
    public var end: Point

    public init(id: SurfaceID, start: Point, end: Point) {
        self.id = id
        self.start = start
        self.end = end
    }

    public var xRange: Interval { Interval(lo: start.x, hi: end.x) }
    public var length: Double { end.x - start.x }

    /// 在 x 处的 y 坐标，按两端点线性插值；x 超出范围时按端点外推。
    public func y(atX x: Double) -> Double {
        let dx = end.x - start.x
        guard dx != 0 else { return start.y }
        return start.y + (end.y - start.y) * (x - start.x) / dx
    }
}

/// 根据 Window_Snapshot 计算全部 Surface（Requirement 3）。
public enum SurfaceBuilder {
    /// 计算每个窗口未被前方窗口遮挡的上沿线段。
    ///
    /// 输入应只包含当前可见的 Eligible_Window；Hidden_Window、Closed_Window 和本应用窗口
    /// 不在输入中，因此不参与遮挡（Requirement 3.3）。
    /// 前方窗口 `f`（`f.zIndex < w.zIndex`）满足 `f.minY <= w.minY <= f.maxY` 时，
    /// 从 `w` 上沿减去 `[f.minX, f.maxX]`（Requirement 3.1、3.2、3.4）。
    /// 输出按 `SurfaceID` 排序，与输入数组顺序无关（Requirement 3.10）。
    public static func ledges(for windows: [WindowSnapshot]) -> [Surface] {
        var result: [Surface] = []
        for w in windows {
            let y = w.frame.minY
            let base = Interval(lo: w.frame.minX, hi: w.frame.maxX)
            let cuts = windows.compactMap { f -> Interval? in
                guard f.zIndex < w.zIndex, f.frame.minY <= y, y <= f.frame.maxY else { return nil }
                return Interval(lo: f.frame.minX, hi: f.frame.maxX)
            }
            let remaining = IntervalMath.subtract(base, cuts)
            for (index, seg) in remaining.enumerated() where seg.length > 0 {
                result.append(Surface(
                    id: .ledge(w.id, index: index),
                    start: Point(x: seg.lo, y: y),
                    end: Point(x: seg.hi, y: y)
                ))
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    /// 唯一的一条 Ground：y 为 `visibleFrame` 底边，x 范围为 `visibleFrame` 左右边界（Requirement 3.7）。
    public static func ground(screen: ScreenInfo) -> Surface {
        let y = screen.groundY
        return Surface(
            id: .ground,
            start: Point(x: screen.visibleFrame.minX, y: y),
            end: Point(x: screen.visibleFrame.maxX, y: y)
        )
    }

    /// 已架设木板形成的 Surface：从左端点到右端点，可能倾斜。
    ///
    /// 端点坐标按 `windows` 中对应窗口的当前位置计算（`frame.minX + offset`，`frame.minY`）。
    /// 任一端窗口不在 `windows` 中（隐藏或已关闭）时不输出该木板，因此 Nav_Graph 自动排除它（Requirement 5.5）。
    /// 本函数只做几何计算，不做有效性判定；失效检测见 `PlankRules.validity(of:...)`。
    public static func plankSurface(_ plank: PlacedPlank, windows: [WindowSnapshot]) -> Surface? {
        func point(_ end: PlankEnd) -> Point? {
            windows.first { $0.id == end.window }
                .map { Point(x: $0.frame.minX + end.offset, y: $0.frame.minY) }
        }
        guard let a = point(plank.endA), let b = point(plank.endB) else { return nil }
        let (l, r) = b.x < a.x ? (b, a) : (a, b)
        return Surface(id: .plank(plank.id), start: l, end: r)
    }

    /// 全部 Surface：一条 Ground、全部 Window_Ledge 和每块已架设 Plank 的 Surface，按 `SurfaceID` 排序。
    public static func build(
        windows: [WindowSnapshot], planks: [PlacedPlank] = [], screen: ScreenInfo
    ) -> [Surface] {
        let plankSurfaces = planks.compactMap { plankSurface($0, windows: windows) }
            .sorted { $0.id < $1.id }
        return [ground(screen: screen)] + ledges(for: windows) + plankSurfaces
    }
}
