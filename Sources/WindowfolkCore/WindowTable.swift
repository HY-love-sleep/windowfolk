import Foundation

/// 窗口当前是否显示在主显示器上。
public enum WindowVisibility: Hashable, Sendable {
    case visible
    /// ID 仍存在但不在 Eligible_Window 中（最小化、其他桌面空间、移出主显示器）。
    case hidden
}

/// 窗口表中的一条记录。
public struct WindowRecord: Hashable, Sendable {
    /// 最近一次可见时的快照。窗口隐藏期间保持不变（Requirement 5.4、5.8）。
    public var snapshot: WindowSnapshot
    public var visibility: WindowVisibility

    public init(snapshot: WindowSnapshot, visibility: WindowVisibility) {
        self.snapshot = snapshot
        self.visibility = visibility
    }
}

/// 一次 `WindowTable.apply` 报告的变化。各 ID 列表按升序排列，关闭列表按窗口 ID 升序排列。
public struct WindowChanges: Hashable, Sendable {
    /// 本次首次出现的窗口。
    public var appeared: [WindowID]
    /// 已记录且本次可见的窗口中，边界或层级与上次可见快照不同的窗口（含重新显示时位置变化的窗口）。
    public var geometryChanged: [WindowID]
    /// 由可见变为隐藏的窗口。
    public var hidden: [WindowID]
    /// 由隐藏变为可见的窗口。
    public var shown: [WindowID]
    /// 成为 Closed_Window 的窗口，附带最后一次可见时的快照（Requirement 5.1、5.8）。
    public var closed: [WindowSnapshot]

    public init(
        appeared: [WindowID] = [], geometryChanged: [WindowID] = [], hidden: [WindowID] = [],
        shown: [WindowID] = [], closed: [WindowSnapshot] = []
    ) {
        self.appeared = appeared
        self.geometryChanged = geometryChanged
        self.hidden = hidden
        self.shown = shown
        self.closed = closed
    }

    public static let none = WindowChanges()

    public var isEmpty: Bool {
        appeared.isEmpty && geometryChanged.isEmpty && hidden.isEmpty && shown.isEmpty
            && closed.isEmpty
    }
}

/// 记录每个已知窗口的最后可见快照，并区分可见、隐藏、关闭。
public struct WindowTable: Hashable, Sendable {
    public var records: [WindowID: WindowRecord]

    public init(records: [WindowID: WindowRecord] = [:]) {
        self.records = records
    }

    /// 当前可见窗口的快照，按 zIndex 从前到后排序。
    public var visibleSnapshots: [WindowSnapshot] {
        records.values
            .filter { $0.visibility == .visible }
            .map(\.snapshot)
            .sorted { ($0.zIndex, $0.id) < ($1.zIndex, $1.id) }
    }

    /// 窗口当前可见时返回其快照；隐藏或未知时返回 nil。
    public func visibleSnapshot(_ id: WindowID) -> WindowSnapshot? {
        guard let r = records[id], r.visibility == .visible else { return nil }
        return r.snapshot
    }

    public func isHidden(_ id: WindowID) -> Bool {
        records[id]?.visibility == .hidden
    }

    /// 用一次轮询结果更新窗口表。
    /// - `.failure`：不改动任何记录，返回空变化（Requirement 2.8）。
    /// - 出现在 `eligible` 中：标记为可见并更新快照。
    /// - 不在 `eligible` 但在 `existingIDs` 中：标记为隐藏，保留最后可见快照。
    /// - 不在 `existingIDs` 中：判为关闭，删除记录并附带最后可见快照报告。
    @discardableResult
    public mutating func apply(_ result: WindowPollResult) -> WindowChanges {
        guard case let .success(eligible, existingIDs) = result else { return .none }

        var changes = WindowChanges()
        var eligibleIDs = Set<WindowID>()

        for snap in eligible {
            // 同一 ID 重复出现时只取第一条（最靠前）。
            guard eligibleIDs.insert(snap.id).inserted else { continue }
            if let old = records[snap.id] {
                if old.visibility == .hidden { changes.shown.append(snap.id) }
                if old.snapshot.frame != snap.frame || old.snapshot.zIndex != snap.zIndex {
                    changes.geometryChanged.append(snap.id)
                }
            } else {
                changes.appeared.append(snap.id)
            }
            records[snap.id] = WindowRecord(snapshot: snap, visibility: .visible)
        }

        for (id, record) in records where !eligibleIDs.contains(id) {
            if existingIDs.contains(id) {
                if record.visibility == .visible {
                    records[id]?.visibility = .hidden
                    changes.hidden.append(id)
                }
            } else {
                records[id] = nil
                changes.closed.append(record.snapshot)
            }
        }

        changes.appeared.sort()
        changes.geometryChanged.sort()
        changes.hidden.sort()
        changes.shown.sort()
        changes.closed.sort { $0.id < $1.id }
        return changes
    }
}
