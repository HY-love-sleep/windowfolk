import CoreGraphics
import Foundation
import WindowfolkCore

/// 真实的 Window_Source：用 `CGWindowListCopyWindowInfo` 读取系统窗口（Requirement 2）。
///
/// - 只读取窗口 ID、所属应用名称与 pid、边界、层级、alpha、是否在屏上，
///   从不读取 `kCGWindowName`（Requirement 2.2）。macOS 10.15 起只有读取窗口标题
///   才需要屏幕录制权限，因此这里不触发任何授权对话框（Requirement 2.3）。
/// - `kCGWindowBounds` 本身就是以主显示器左上角为原点、单位 pt 的坐标，与 Core 坐标一致，
///   因此这里不做 y 翻转（Requirement 2.4、2.5）；只做 `CGRect` → `Rect` 的类型转换。
/// - 任一次系统调用返回 nil 时整次轮询返回 `.failure`（Requirement 2.8）。
///
/// ## 全部窗口列表的读取频率（任务 17.2，Requirement 29.1）
///
/// `[.optionAll]` 列表包含系统里的全部窗口（通常数百个），读取和解析它占了每帧绝大部分 CPU。
/// 它只用来区分 Closed_Window 和 Hidden_Window（Requirement 2.7），因此不必每帧读取：
///
/// - 上一次输出的某个 Eligible_Window 本次不在屏上合格列表中（可能关闭、最小化、切到其他桌面空间、
///   移出主显示器或变小）时，**本次立即**读取全部列表，可见窗口的关闭仍在同一次轮询中判定（Requirement 5.1）。
/// - 否则沿用最近一次读到的全部窗口 ID，并入本次屏上列表的 ID。
/// - 距上次读取全部列表满 `fullRefreshInterval` 时也读取一次。这只影响「已经隐藏的窗口被关闭」
///   （Requirement 5.8）的发现时间：最多晚 `fullRefreshInterval` 秒。在此之前该窗口按隐藏处理，
///   附着的对象不绘制、不下落，与关闭后立即下落相比只是延迟，不会误判。
struct CGWindowSource: WindowSource {
    /// 当前主显示器信息（Core 坐标）。屏幕参数变化时由应用层更新。
    var screen: ScreenInfo
    /// Min_Window_Size。
    var minSize: Double
    /// 本进程 pid，用于排除 Overlay 等自身窗口（Requirement 1.6）。
    let ownPID: Int32

    /// 没有合格窗口消失时，重新读取全部窗口列表的最长间隔（秒）。
    static let fullRefreshInterval: TimeInterval = 1.0

    /// 最近一次读取全部窗口列表得到的 ID 集合。
    private var cachedExistingIDs: Set<WindowID> = []
    /// 最近一次读取全部窗口列表的时刻（`ProcessInfo.systemUptime`）；尚未读取时为 nil。
    private var lastFullQuery: TimeInterval?
    /// 上一次成功输出的 Eligible_Window ID。
    private var lastEligibleIDs: Set<WindowID> = []
    /// 最近一次成功读取的屏上窗口列表（未经过滤）。全屏检测（任务 17.6）复用它，不再额外调用
    /// `CGWindowListCopyWindowInfo`。屏上列表读取失败时保留上一次的内容。
    private(set) var lastOnScreen: [RawWindowInfo] = []

    init(screen: ScreenInfo, minSize: Double,
         ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.screen = screen
        self.minSize = minSize
        self.ownPID = ownPID
    }

    mutating func poll() -> WindowPollResult {
        // 屏上列表：系统按从前到后排序。
        guard let onScreenArray = Self.copyWindowList([.optionOnScreenOnly, .excludeDesktopElements]) else {
            return .failure
        }
        let onScreen = Self.rawInfos(onScreenArray)
        lastOnScreen = onScreen

        // 先只用屏上列表过滤出合格窗口；existingIDs 随后单独确定。
        guard case let .success(eligible, _) = WindowFilter.makeResult(
            onScreen: onScreen, all: [], ownPID: ownPID, screen: screen, minSize: minSize)
        else { return .failure }
        let eligibleIDs = Set(eligible.map(\.id))

        let now = ProcessInfo.processInfo.systemUptime
        let lostEligible = !lastEligibleIDs.isSubset(of: eligibleIDs)
        let stale = lastFullQuery.map { now - $0 >= Self.fullRefreshInterval } ?? true

        var existing: Set<WindowID>
        if lostEligible || stale {
            // 全部窗口：含最小化和其他桌面空间，用于区分关闭和隐藏（Requirement 2.7）。
            guard let allArray = Self.copyWindowList([.optionAll]) else { return .failure }
            existing = Self.windowIDs(allArray)
            cachedExistingIDs = existing
            lastFullQuery = now
        } else {
            existing = cachedExistingIDs
        }
        // 屏上的窗口必然存在；新出现的窗口在下次读取全部列表之前也算现存。
        for info in onScreen { existing.insert(info.id) }

        lastEligibleIDs = eligibleIDs
        return .success(eligible: eligible, existingIDs: existing)
    }

    // MARK: - 系统调用

    private static func copyWindowList(_ options: CGWindowListOption) -> NSArray? {
        guard let array = CGWindowListCopyWindowInfo(options, kCGNullWindowID) else { return nil }
        // 直接按 NSArray / NSDictionary 读取，避免把整个列表桥接成 [[String: Any]] 的开销。
        return array as NSArray
    }

    private static func rawInfos(_ array: NSArray) -> [RawWindowInfo] {
        var result: [RawWindowInfo] = []
        result.reserveCapacity(array.count)
        for case let dict as NSDictionary in array {
            if let info = rawInfo(from: dict) { result.append(info) }
        }
        return result
    }

    /// 只取窗口 ID，用于全部窗口列表。
    private static func windowIDs(_ array: NSArray) -> Set<WindowID> {
        var ids = Set<WindowID>(minimumCapacity: array.count)
        for case let dict as NSDictionary in array {
            if let number = (dict[kCGWindowNumber] as? NSNumber)?.uint32Value {
                ids.insert(number)
            }
        }
        return ids
    }

    // MARK: - 字典 → RawWindowInfo

    /// 只取需要的键；缺少窗口 ID 的条目被丢弃。其他缺失字段取保守默认值，
    /// 使条目在 `WindowFilter` 中被排除，但其 ID 仍计入 `existingIDs`。
    static func rawInfo(from dict: NSDictionary) -> RawWindowInfo? {
        guard let number = (dict[kCGWindowNumber] as? NSNumber)?.uint32Value else {
            return nil
        }
        let ownerName = dict[kCGWindowOwnerName] as? String ?? ""
        let ownerPID = (dict[kCGWindowOwnerPID] as? NSNumber)?.int32Value ?? -1
        let layer = (dict[kCGWindowLayer] as? NSNumber)?.intValue ?? Int.max
        let alpha = (dict[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 0
        let isOnScreen = (dict[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false

        let bounds: Rect
        if let boundsDict = dict[kCGWindowBounds] as? NSDictionary,
           let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
            // 不调用 ScreenGeometry.rect：它会 standardized，负尺寸会被翻正，
            // 而 WindowFilter 需要看到原始的负尺寸并丢弃该条目。
            bounds = Rect(minX: Double(cgRect.origin.x), minY: Double(cgRect.origin.y),
                          width: Double(cgRect.size.width), height: Double(cgRect.size.height))
        } else {
            // 没有边界：给 NaN，WindowFilter 会丢弃。
            bounds = Rect(minX: .nan, minY: .nan, width: .nan, height: .nan)
        }

        return RawWindowInfo(id: number, ownerName: ownerName, ownerPID: ownerPID,
                             bounds: bounds, layer: layer, alpha: alpha, isOnScreen: isOnScreen)
    }
}
