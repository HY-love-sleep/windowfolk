import AppKit
import WindowfolkCore

/// 应用中唯一做 y 翻转的地方（Requirement 2.5）。
///
/// Core 坐标：原点在主显示器左上角，y 向下（与 `kCGWindowBounds` 一致）。
/// AppKit / SpriteKit 坐标：原点在主显示器左下角，y 向上。
/// `flipY` 计算 `y' = mainScreenHeight - y`，是自身的逆，两个方向共用。
struct ScreenGeometry: Sendable, Equatable {
    /// 主显示器（`NSScreen.screens.first`）完整 frame 的高度。
    var mainScreenHeight: Double

    init(mainScreenHeight: Double) {
        self.mainScreenHeight = mainScreenHeight
    }

    /// 以当前主显示器构造；没有屏幕时返回 nil。
    /// 注意用 `screens.first` 而不是 `NSScreen.main`，后者是 key window 所在的屏幕。
    @MainActor
    static func current() -> ScreenGeometry? {
        guard let main = NSScreen.screens.first else { return nil }
        return ScreenGeometry(mainScreenHeight: Double(main.frame.height))
    }

    // MARK: - 翻转（唯一实现）

    /// 在 Core 与 AppKit 坐标之间翻转一个点，两个方向都用这一个函数。
    func flipY(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: CGFloat(mainScreenHeight) - point.y)
    }

    /// 在 Core 与 AppKit 坐标之间翻转一个矩形，内部只调用 `flipY`。
    /// 输入矩形在 y 方向上的「远端角」(minX, maxY) 翻转后成为输出矩形的原点。
    func flipRect(_ rect: CGRect) -> CGRect {
        let origin = flipY(CGPoint(x: rect.minX, y: rect.maxY))
        return CGRect(origin: origin, size: rect.size)
    }

    // MARK: - AppKit → Core

    func corePoint(fromAppKit p: CGPoint) -> Point {
        Self.point(flipY(p))
    }

    func coreRect(fromAppKit r: CGRect) -> Rect {
        Self.rect(flipRect(r))
    }

    /// 由主显示器的 `frame` 和 `visibleFrame`（AppKit 全局坐标）构造 Core 的 `ScreenInfo`。
    func screenInfo(frame: CGRect, visibleFrame: CGRect) -> ScreenInfo {
        ScreenInfo(frame: coreRect(fromAppKit: frame),
                   visibleFrame: coreRect(fromAppKit: visibleFrame))
    }

    // MARK: - Core → AppKit / SpriteKit

    func appKitPoint(fromCore p: Point) -> CGPoint {
        flipY(Self.cgPoint(p))
    }

    func appKitRect(fromCore r: Rect) -> CGRect {
        flipRect(Self.cgRect(r))
    }

    // MARK: - 纯类型互转（不翻转）

    static func point(_ p: CGPoint) -> Point {
        Point(x: Double(p.x), y: Double(p.y))
    }

    static func cgPoint(_ p: Point) -> CGPoint {
        CGPoint(x: p.x, y: p.y)
    }

    static func rect(_ r: CGRect) -> Rect {
        let s = r.standardized
        return Rect(minX: Double(s.minX), minY: Double(s.minY),
                    width: Double(s.width), height: Double(s.height))
    }

    static func cgRect(_ r: Rect) -> CGRect {
        CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }
}
