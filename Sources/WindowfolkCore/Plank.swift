import Foundation

// `PlankID` 定义在 Attachment.swift 中。

/// 已架设木板的一端：所在窗口加相对窗口左边缘的水平偏移（Requirement 9.5、9.7）。
/// 端点的屏幕 y 总是该窗口的上沿。
public struct PlankEnd: Hashable, Sendable, Codable {
    public var window: WindowID
    public var offset: Double

    public init(window: WindowID, offset: Double) {
        self.window = window
        self.offset = offset
    }

    /// 窗口可见时的屏幕坐标 `(frame.minX + offset, frame.minY)`；窗口隐藏或已关闭时为 nil。
    public func screenPoint(windows: WindowTable) -> Point? {
        windows.visibleSnapshot(window).map { Point(x: $0.frame.minX + offset, y: $0.frame.minY) }
    }

    /// 用窗口最后一次已知（可见或隐藏）的快照计算屏幕坐标；窗口已关闭时为 nil。
    public func lastKnownPoint(windows: WindowTable) -> Point? {
        windows.records[window].map {
            Point(x: $0.snapshot.frame.minX + offset, y: $0.snapshot.frame.minY)
        }
    }
}

/// 一块已架设的木板。两端分别附着在两个不同窗口的上沿上。
public struct PlacedPlank: Hashable, Sendable, Codable {
    public var id: PlankID
    public var endA: PlankEnd
    public var endB: PlankEnd

    public init(id: PlankID, endA: PlankEnd, endB: PlankEnd) {
        self.id = id
        self.endA = endA
        self.endB = endB
    }

    /// 两端的屏幕坐标，按 x 从左到右（x 相等时 A 在前）；任一端窗口不可见时为 nil。
    public func endpoints(windows: WindowTable) -> (left: Point, right: Point)? {
        guard let a = endA.screenPoint(windows: windows),
              let b = endB.screenPoint(windows: windows) else { return nil }
        return b.x < a.x ? (b, a) : (a, b)
    }

    /// 任一端附着在 `window` 上。
    public func touches(_ window: WindowID) -> Bool {
        endA.window == window || endB.window == window
    }
}

/// 木板的状态。
public enum PlankState: Hashable, Sendable {
    /// 架设在两个窗沿之间，形成一条 Surface。
    case placed(PlacedPlank)
    /// 落下后停在窗沿（`window`）或 Ground（`ground`）上，不在 Nav_Graph 中（Requirement 9.8）。
    case loose(Attachment)
    /// 下落中。
    case falling(FallState)
    /// 被玩家拖动中（位置由 InteractionController 的手势状态给出）。
    case dragged

    public var placed: PlacedPlank? {
        if case let .placed(p) = self { return p }
        return nil
    }
}

/// 全部木板的存储。
public struct PlankStore: Hashable, Sendable {
    public var planks: [PlankID: PlankState]
    public var nextID: UInt64

    public init(planks: [PlankID: PlankState] = [:], nextID: UInt64 = 1) {
        self.planks = planks
        self.nextID = nextID
    }

    /// 分配一个新的 PlankID（单调递增，保证确定性）。
    public mutating func makeID() -> PlankID {
        defer { nextID += 1 }
        return PlankID(nextID)
    }

    /// 全部已架设木板，按 ID 排序。
    public var placedPlanks: [PlacedPlank] {
        planks.keys.sorted().compactMap { planks[$0]?.placed }
    }

    /// 绑定窗口表后得到的位置查询，供 `AttachmentResolver.screenPosition` 使用。
    public func lookup(windows: WindowTable) -> PlankLookup {
        PlankLookup(store: self, windows: windows)
    }
}

/// 已架设木板上某点的屏幕坐标查询（`PlankPositionLookup` 的实现）。
public struct PlankLookup: PlankPositionLookup, Sendable {
    public var store: PlankStore
    public var windows: WindowTable

    public init(store: PlankStore, windows: WindowTable) {
        self.store = store
        self.windows = windows
    }

    /// `t` 为沿木板从左端（0）到右端（1）的比例，超出 [0, 1] 时夹紧。
    /// 木板不存在、未架设或任一端窗口不可见时返回 nil。
    public func point(onPlank id: PlankID, t: Double) -> Point? {
        guard let p = store.planks[id]?.placed,
              let (l, r) = p.endpoints(windows: windows) else { return nil }
        let u = min(max(t, 0), 1)
        return Point(x: l.x + (r.x - l.x) * u, y: l.y + (r.y - l.y) * u)
    }
}
