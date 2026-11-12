import Foundation

// MARK: - Plank / Ladder 标识

// 说明：`PlankID` 和 `LadderID` 在 design.md 中归属 Plank / Ladder 模块（任务 6.1、9.1），
// 但 `Attachment` 的 `plank`、`ladder` 取值需要它们，因此提前定义在这里。
// 任务 6.1 / 9.1 应直接使用这两个类型，不要重复定义。
// 用整数而不是 UUID：需要 Comparable（`SurfaceID.plank` 参与排序），且测试中更易构造、结果确定。

/// 木板标识。
public struct PlankID: Hashable, Sendable, Codable, Comparable {
    public var rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: PlankID, rhs: PlankID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 梯子标识。
public struct LadderID: Hashable, Sendable, Codable, Comparable {
    public var rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: LadderID, rhs: LadderID) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Attachment

/// 居民或物件的位置锚点（Requirement 4.1）。
///
/// 需求中的 Attachment 只有 `window` 和 `ground` 两种；`plank`、`ladder`、`free` 是设计新增的内部取值，
/// 分别表示站在木板上、爬梯子中、下落 / 悬挂 / 被拖动中。需求中关于偏移量的条款只针对 `window`。
public enum Attachment: Hashable, Sendable, Codable {
    /// 相对窗口左边缘的水平偏移；屏幕 y 为窗口上沿。
    case window(WindowID, offset: Double)
    /// 地面上的屏幕 x 坐标；屏幕 y 为 Ground。
    case ground(x: Double)
    /// 沿木板从左端（t = 0）到右端（t = 1）的比例。
    case plank(PlankID, t: Double)
    /// 距梯子下端的竖直距离。
    case ladder(LadderID, height: Double)
    /// 不依附任何 Surface 的屏幕坐标（下落、悬挂、被拖动中）。
    case free(Point)

    /// 附着的窗口 ID；非 `window` 取值时为 nil。
    public var windowID: WindowID? {
        if case let .window(id, _) = self { return id }
        return nil
    }
}

// MARK: - Plank / Ladder 位置查询

/// 已架设木板上某点的屏幕坐标查询。任务 6.1 的木板存储实现该协议。
public protocol PlankPositionLookup {
    /// 木板不存在、未架设或端点所在窗口隐藏时返回 nil。
    func point(onPlank id: PlankID, t: Double) -> Point?
}

/// 已架设梯子上某点的屏幕坐标查询。任务 9.1 的梯子存储实现该协议。
public protocol LadderPositionLookup {
    /// 梯子不存在、未架设或上端所在窗口隐藏时返回 nil。
    func point(onLadder id: LadderID, height: Double) -> Point?
}

/// 没有任何木板（任务 6.1 之前或测试中使用）。
public struct NoPlanks: PlankPositionLookup, Sendable {
    public init() {}
    public func point(onPlank id: PlankID, t: Double) -> Point? { nil }
}

/// 没有任何梯子（任务 9.1 之前或测试中使用）。
public struct NoLadders: LadderPositionLookup, Sendable {
    public init() {}
    public func point(onLadder id: LadderID, height: Double) -> Point? { nil }
}
