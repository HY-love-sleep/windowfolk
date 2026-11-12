import Foundation

/// 测试用的一个假窗口：快照数据加隐藏标记。
/// `snapshot.zIndex` 不在这里维护，`poll()` 输出时按 `FakeWindowSource.windows` 的顺序重新编号。
public struct FakeWindow: Hashable, Sendable {
    public var snapshot: WindowSnapshot
    /// true 表示最小化或位于其他桌面空间：不出现在 `eligible` 中，但 ID 仍在 `existingIDs` 中。
    public var isHidden: Bool

    public init(snapshot: WindowSnapshot, isHidden: Bool = false) {
        self.snapshot = snapshot
        self.isHidden = isHidden
    }
}

/// 实现 `WindowSource` 的假窗口源（Requirement 27.3、27.4）。
///
/// - `windows` 按从前到后排列，隐藏窗口保留自己的层级位置，重新显示时回到原位。
/// - 各操作修改内部状态，下一次 `poll()` 输出反映这些操作的快照列表和窗口 ID 集合。
/// - 不做 Eligible_Window 过滤：测试直接构造的就是想要的 Eligible_Window 布局。
public struct FakeWindowSource: WindowSource, Sendable {
    public var windows: [FakeWindow]
    /// 为 true 时下一次 `poll()` 返回 `.failure`，随后自动复位。
    public var failNextPoll: Bool

    public init(windows: [FakeWindow] = [], failNextPoll: Bool = false) {
        self.windows = windows
        self.failNextPoll = failNextPoll
    }

    /// 按 `zIndex` 升序（从前到后）排列给定快照；`zIndex` 相同时保持传入顺序。
    public init(snapshots: [WindowSnapshot]) {
        let ordered = snapshots.enumerated()
            .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
            .map { FakeWindow(snapshot: $0.element) }
        self.init(windows: ordered)
    }

    // MARK: - 查询

    public var count: Int { windows.count }

    public func window(_ id: WindowID) -> FakeWindow? {
        windows.first { $0.snapshot.id == id }
    }

    private func index(of id: WindowID) -> Int? {
        windows.firstIndex { $0.snapshot.id == id }
    }

    // MARK: - 操作

    /// 新增窗口，放在最后方（`zIndex` 参数被忽略）；ID 已存在时原位替换其快照并设为可见。
    public mutating func add(_ w: WindowSnapshot) {
        if let i = index(of: w.id) {
            windows[i] = FakeWindow(snapshot: w)
        } else {
            windows.append(FakeWindow(snapshot: w))
        }
    }

    /// 新增窗口并放在最前方；ID 已存在时先移除旧条目。
    public mutating func addInFront(_ w: WindowSnapshot) {
        if let i = index(of: w.id) { windows.remove(at: i) }
        windows.insert(FakeWindow(snapshot: w), at: 0)
    }

    /// 移动窗口左上角到 `origin`，尺寸不变。
    public mutating func move(_ id: WindowID, to origin: Point) {
        guard let i = index(of: id) else { return }
        windows[i].snapshot.frame.minX = origin.x
        windows[i].snapshot.frame.minY = origin.y
    }

    /// 改变窗口尺寸，左上角不变。
    public mutating func resize(_ id: WindowID, to size: (Double, Double)) {
        guard let i = index(of: id) else { return }
        windows[i].snapshot.frame.width = size.0
        windows[i].snapshot.frame.height = size.1
    }

    /// 把窗口移到最前方。
    public mutating func bringToFront(_ id: WindowID) {
        guard let i = index(of: id) else { return }
        let w = windows.remove(at: i)
        windows.insert(w, at: 0)
    }

    /// 把窗口 `id` 放到窗口 `other` 紧后方。两者相同或任一不存在时不做任何事。
    public mutating func sendBehind(_ id: WindowID, _ other: WindowID) {
        guard id != other, let i = index(of: id), index(of: other) != nil else { return }
        let w = windows.remove(at: i)
        let j = index(of: other)!
        windows.insert(w, at: j + 1)
    }

    /// 关闭窗口：从可见列表和 `existingIDs` 中都消失。
    public mutating func close(_ id: WindowID) {
        guard let i = index(of: id) else { return }
        windows.remove(at: i)
    }

    /// 隐藏窗口（最小化或切到其他桌面空间）：不再可见，但 ID 仍存在。
    public mutating func hide(_ id: WindowID) {
        guard let i = index(of: id) else { return }
        windows[i].isHidden = true
    }

    /// 重新显示隐藏的窗口，回到原来的层级位置。
    public mutating func show(_ id: WindowID) {
        guard let i = index(of: id) else { return }
        windows[i].isHidden = false
    }

    // MARK: - WindowSource

    /// 按从前到后输出可见窗口，`zIndex` 从 0 连续编号；`existingIDs` 包含隐藏窗口。
    /// `failNextPoll` 为 true 时返回 `.failure` 并复位该标记。
    public mutating func poll() -> WindowPollResult {
        if failNextPoll {
            failNextPoll = false
            return .failure
        }
        var eligible: [WindowSnapshot] = []
        eligible.reserveCapacity(windows.count)
        for w in windows where !w.isHidden {
            var s = w.snapshot
            s.zIndex = eligible.count
            eligible.append(s)
        }
        let existing = Set(windows.map(\.snapshot.id))
        return .success(eligible: eligible, existingIDs: existing)
    }
}
