import Foundation

/// 判定前台应用是否在主显示器上全屏（Requirement 23.1、23.4）。纯函数，应用层每次轮询后调用。
///
/// 规则：前台应用（`frontPID`）在屏上列表中有一个 `layer == 0`、`alpha > 0` 的窗口，
/// 其边界与主显示器完整 `frame` 相等（每条边误差不超过 `tolerance`）。
/// macOS 全屏桌面空间中菜单栏自动隐藏，全屏窗口的边界正好等于主显示器 frame，因此这条规则
/// 同时覆盖「位于全屏桌面空间」和「边界等于主显示器 frame」两种情形，且只用 `CGWindowList`
/// 已读取的字段，不需要任何权限。
///
/// design.md 中「屏上只剩前台应用的 layer 0 窗口」这条辅助特征没有采用：桌面上只开着一个普通窗口时
/// 它也成立，会把非全屏误判为全屏并隐藏世界。
public enum FullscreenDetector {
    public static let defaultTolerance = 1.0

    /// - Parameters:
    ///   - frontPID: 前台应用 pid；nil 表示未知，判为非全屏。
    ///   - onScreen: 本次轮询的屏上窗口列表（未经 `WindowFilter` 过滤）。
    ///   - screen: 主显示器信息。
    ///   - ownPID: 本进程 pid；前台是本进程时判为非全屏。
    public static func isFullscreen(frontPID: Int32?, onScreen: [RawWindowInfo], screen: ScreenInfo,
                                    ownPID: Int32, tolerance: Double = defaultTolerance) -> Bool {
        guard let frontPID, frontPID != ownPID else { return false }
        let f = screen.frame
        return onScreen.contains { w in
            w.ownerPID == frontPID && w.layer == 0 && w.alpha > 0 &&
                abs(w.bounds.minX - f.minX) <= tolerance &&
                abs(w.bounds.minY - f.minY) <= tolerance &&
                abs(w.bounds.maxX - f.maxX) <= tolerance &&
                abs(w.bounds.maxY - f.maxY) <= tolerance
        }
    }
}
