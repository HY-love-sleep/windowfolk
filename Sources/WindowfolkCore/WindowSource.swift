import Foundation

/// 系统窗口 ID（对应 `kCGWindowNumber`）。
public typealias WindowID = UInt32

/// 某一时刻一个 Eligible_Window 的数据。
/// 只含窗口 ID、所属应用、边界和层级，没有标题字段（Requirement 2.2、21.8）。
public struct WindowSnapshot: Hashable, Sendable {
    public var id: WindowID
    public var ownerName: String
    public var ownerPID: Int32
    /// Core 坐标（左上角原点，y 向下，单位 pt）
    public var frame: Rect
    /// 0 为最前，数值越大越靠后
    public var zIndex: Int

    public init(id: WindowID, ownerName: String, ownerPID: Int32, frame: Rect, zIndex: Int) {
        self.id = id
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.frame = frame
        self.zIndex = zIndex
    }
}

/// CGWindowList 条目的纯数据版本，供 `WindowFilter` 过滤。
public struct RawWindowInfo: Hashable, Sendable {
    public var id: WindowID
    public var ownerName: String
    public var ownerPID: Int32
    /// Core 坐标（`kCGWindowBounds` 本身即左上角原点）
    public var bounds: Rect
    public var layer: Int
    public var alpha: Double
    public var isOnScreen: Bool

    public init(
        id: WindowID, ownerName: String, ownerPID: Int32, bounds: Rect,
        layer: Int, alpha: Double, isOnScreen: Bool
    ) {
        self.id = id
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }
}

/// 一次轮询的结果。
public enum WindowPollResult: Hashable, Sendable {
    /// `eligible`：按从前到后排序的 Eligible_Window；
    /// `existingIDs`：含最小化和其他桌面空间窗口在内的全部现存窗口 ID（Requirement 2.7）。
    case success(eligible: [WindowSnapshot], existingIDs: Set<WindowID>)
    /// 系统窗口列表读取失败（Requirement 2.8）。
    case failure
}

/// Window_Source 接口。应用层由 `CGWindowSource` 实现，测试由 `FakeWindowSource` 实现。
public protocol WindowSource {
    mutating func poll() -> WindowPollResult
}
