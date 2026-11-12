import Foundation

/// Attachment 与屏幕坐标之间的换算（Requirement 4）。
public enum AttachmentResolver {
    /// Attachment 当前的屏幕坐标（对象底边中点，Core 坐标）。
    ///
    /// - `window`：窗口可见时为 `(frame.minX + offset, frame.minY)`（Requirement 4.4）；
    ///   窗口隐藏或未知（已关闭）时返回 nil，调用方不绘制、不移动该对象（Requirement 5.2、5.3）。
    /// - `ground`：`(x, groundY)`，与窗口无关。
    /// - `plank` / `ladder`：交给对应的查询。
    /// - `free`：原样返回。
    public static func screenPosition(
        _ a: Attachment, windows: WindowTable,
        planks: some PlankPositionLookup, ladders: some LadderPositionLookup,
        screen: ScreenInfo
    ) -> Point? {
        switch a {
        case let .window(id, offset):
            guard let snap = windows.visibleSnapshot(id) else { return nil }
            return Point(x: snap.frame.minX + offset, y: snap.frame.minY)
        case let .ground(x):
            return Point(x: x, y: screen.groundY)
        case let .plank(id, t):
            return planks.point(onPlank: id, t: t)
        case let .ladder(id, height):
            return ladders.point(onLadder: id, height: height)
        case let .free(p):
            return p
        }
    }

    /// 没有木板和梯子时的便捷版本。
    public static func screenPosition(
        _ a: Attachment, windows: WindowTable, screen: ScreenInfo
    ) -> Point? {
        screenPosition(a, windows: windows, planks: NoPlanks(), ladders: NoLadders(), screen: screen)
    }

    /// 把偏移量夹紧到窗口 `window` 的剩余 Window_Ledge 上（Requirement 4.6、4.7）。
    ///
    /// - `ledges` 可以是全部 Surface，只考虑 `.ledge(window.id, _)`。
    /// - 偏移量已落在某段窗沿内（含端点）时原样返回。
    /// - 否则返回同一窗口中水平距离最近那段窗沿上的最近点的偏移量；距离相等时取 `SurfaceID` 较小的一段。
    /// - 该窗口没有任何剩余窗沿时返回 nil，调用方应让对象下落。
    public static func clamp(offset: Double, window: WindowSnapshot, ledges: [Surface]) -> Double? {
        let x = window.frame.minX + offset
        let own = ledges
            .filter { $0.id.windowID == window.id }
            .sorted { $0.id < $1.id }
        guard !own.isEmpty else { return nil }

        if own.contains(where: { $0.start.x <= x && x <= $0.end.x }) {
            return offset
        }

        var bestX = own[0].start.x
        var bestDistance = Double.infinity
        for ledge in own {
            let nx = min(max(x, ledge.start.x), ledge.end.x)
            let d = abs(x - nx)
            if d < bestDistance {
                bestDistance = d
                bestX = nx
            }
        }
        return bestX - window.frame.minX
    }

    /// 落在 Surface 上 x 处时应得到的 Attachment（Requirement 4.2、4.3、6.6）。
    ///
    /// - Window_Ledge：所属窗口 ID 加 `x - frame.minX`；窗口不可见时返回 nil。
    /// - Ground：`ground(x:)`。
    /// - Plank：`plank(id, t:)`，`t = (x - start.x) / (end.x - start.x)` 夹紧到 [0, 1]；两端 x 相同时 t = 0。
    public static func attachment(
        landingOn surface: Surface, atX x: Double, windows: WindowTable
    ) -> Attachment? {
        switch surface.id {
        case .ground:
            return .ground(x: x)
        case let .ledge(id, _):
            guard let snap = windows.visibleSnapshot(id) else { return nil }
            return .window(id, offset: x - snap.frame.minX)
        case let .plank(id):
            let dx = surface.end.x - surface.start.x
            let t = dx > 0 ? min(max((x - surface.start.x) / dx, 0), 1) : 0
            return .plank(id, t: t)
        }
    }
}
