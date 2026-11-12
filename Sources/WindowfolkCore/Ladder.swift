import Foundation

// `LadderID` 定义在 Attachment.swift 中。

/// 一架已架设的梯子（Requirement 10.5、10.7）。
///
/// 上端用「窗口 ID 加相对窗口左边缘的偏移量」附着在窗口上沿（复用 `PlankEnd`）；
/// 下端是上端正下方第一条 Ground 或 Window_Ledge 上的点，每次世界更新按当前上端重新计算
/// （见 `LadderRules.refreshed(_:windows:surfaces:)`）。
public struct PlacedLadder: Hashable, Sendable {
    public var id: LadderID
    public var top: PlankEnd
    public var bottomSurface: SurfaceID
    public var bottom: Point

    public init(id: LadderID, top: PlankEnd, bottomSurface: SurfaceID, bottom: Point) {
        self.id = id
        self.top = top
        self.bottomSurface = bottomSurface
        self.bottom = bottom
    }

    /// 上端屏幕坐标；上端窗口隐藏或已关闭时为 nil。
    public func topPoint(windows: WindowTable) -> Point? {
        top.screenPoint(windows: windows)
    }

    /// 上下端的竖直距离（Core 坐标 y 向下，下端 y 较大）；上端窗口不可见时为 nil。
    public func length(windows: WindowTable) -> Double? {
        topPoint(windows: windows).map { bottom.y - $0.y }
    }

    /// 上端附着在 `window` 上。
    public func touches(_ window: WindowID) -> Bool {
        top.window == window
    }

    /// 转换为建图输入（Requirement 12.6）。
    ///
    /// 上端窗口不可见（隐藏或关闭，Requirement 5.5）、上端不在所属窗口的现存 Window_Ledge 上、
    /// 或下端 Surface 不在 `surfaces` 中时返回 nil。`surfaces` 应为当前全部 Surface。
    public func navLadder(windows: WindowTable, surfaces: [Surface]) -> NavLadder? {
        guard let t = topPoint(windows: windows),
              let topLedge = LadderRules.ledge(containing: t, window: top.window, surfaces: surfaces),
              surfaces.contains(where: { $0.id == bottomSurface }) else { return nil }
        return NavLadder(id: id, bottomSurface: bottomSurface, bottom: bottom,
                         topSurface: topLedge.id, top: t)
    }
}

/// 梯子的状态，与 `PlankState` 对应。
public enum LadderState: Hashable, Sendable {
    /// 架设中：形成一条竖直通路，Nav_Graph 中有双向爬梯边。
    case placed(PlacedLadder)
    /// 落下后停在窗沿（`window`）或 Ground（`ground`）上，不在 Nav_Graph 中（Requirement 10.6）。
    case loose(Attachment)
    /// 下落中。
    case falling(FallState)
    /// 被玩家拖动中（位置由 InteractionController 的手势状态给出）。
    case dragged

    public var placed: PlacedLadder? {
        if case let .placed(l) = self { return l }
        return nil
    }
}

/// 全部梯子的存储。
public struct LadderStore: Hashable, Sendable {
    public var ladders: [LadderID: LadderState]
    public var nextID: UInt64

    public init(ladders: [LadderID: LadderState] = [:], nextID: UInt64 = 1) {
        self.ladders = ladders
        self.nextID = nextID
    }

    /// 分配一个新的 LadderID（单调递增，保证确定性）。
    public mutating func makeID() -> LadderID {
        defer { nextID += 1 }
        return LadderID(nextID)
    }

    /// 全部已架设梯子，按 ID 排序。
    public var placedLadders: [PlacedLadder] {
        ladders.keys.sorted().compactMap { ladders[$0]?.placed }
    }

    /// 建图输入：上端窗口可见且两端 Surface 现存的已架设梯子，按 ID 排序（Requirement 5.5、12.6）。
    public func navLadders(windows: WindowTable, surfaces: [Surface]) -> [NavLadder] {
        placedLadders.compactMap { $0.navLadder(windows: windows, surfaces: surfaces) }
    }

    /// 绑定窗口表后得到的位置查询，供 `AttachmentResolver.screenPosition` 使用。
    public func lookup(windows: WindowTable) -> LadderLookup {
        LadderLookup(store: self, windows: windows)
    }
}

/// 已架设梯子上某点的屏幕坐标查询（`LadderPositionLookup` 的实现）。
public struct LadderLookup: LadderPositionLookup, Sendable {
    public var store: LadderStore
    public var windows: WindowTable

    public init(store: LadderStore, windows: WindowTable) {
        self.store = store
        self.windows = windows
    }

    /// `height` 为距下端的竖直距离，夹紧到 [0, 梯子长度]。x 取上端当前 x（梯子竖直）。
    /// 梯子不存在、未架设或上端窗口不可见时返回 nil。
    public func point(onLadder id: LadderID, height: Double) -> Point? {
        guard let l = store.ladders[id]?.placed,
              let t = l.topPoint(windows: windows) else { return nil }
        let length = max(l.bottom.y - t.y, 0)
        let h = min(max(height, 0), length)
        return Point(x: t.x, y: l.bottom.y - h)
    }
}
