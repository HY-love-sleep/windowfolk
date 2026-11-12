import Foundation

/// 木板有效性判定结果。只有 `valid` 表示可以架设或保持架设。
public enum PlankValidity: Hashable, Sendable {
    case valid
    /// 两端水平距离 > Plank_Max_Span。
    case tooFar
    /// 两端高差 > Plank_Max_Rise。
    case tooSteep
    /// 至少一端不在所属窗口的现存 Window_Ledge 上（窗口已关闭、窗沿被遮挡或缩短）。
    case missingLedge
    /// 两端属于同一个窗口。
    case sameWindow

    public var isValid: Bool { self == .valid }
}

/// 拖动木板时的吸附结果：两端吸附点及其所属窗口。
public typealias PlankSnap = (endA: Point, endB: Point, windowA: WindowID, windowB: WindowID)

/// 木板的吸附与有效性规则（Requirement 9）。
public enum PlankRules {
    /// 端点与窗沿比较时允许的浮点误差（pt）。端点坐标由 `frame.minX + offset` 算出，可能差几个 ulp。
    public static let epsilon = 1e-6

    /// 拖动时的吸附（Requirement 9.1、9.2）。
    ///
    /// 第一端取所有 Window_Ledge 中离指针最近的点；第二端在属于其他窗口的 Window_Ledge 中取离指针最近的点。
    /// 距离相等时取 `SurfaceID` 较小的一条。属于不同窗口的窗沿少于两条时返回 nil。
    /// `ledges` 可以是全部 Surface，只考虑 `.ledge`。
    public static func snap(pointer: Point, ledges: [Surface]) -> PlankSnap? {
        let candidates = ledges
            .filter { $0.id.isLedge }
            .sorted { $0.id < $1.id }
        guard let first = nearest(to: pointer, in: candidates),
              let windowA = first.surface.id.windowID else { return nil }
        guard let second = nearest(to: pointer, in: candidates.filter { $0.id.windowID != windowA }),
              let windowB = second.surface.id.windowID else { return nil }
        return (first.point, second.point, windowA, windowB)
    }

    /// 唯一的木板有效性判定，拖动预览颜色与架设后的失效检测共用（Requirement 9.3、9.4、9.9、9.12）。
    ///
    /// 有效当且仅当：两端窗口不同；每端都落在所属窗口某条现存 Window_Ledge 的 x 范围内且 y 等于该窗沿 y；
    /// `|xA - xB| <= Plank_Max_Span`；`|yA - yB| <= Plank_Max_Rise`。
    /// 依次检查同窗口、缺窗沿、过远、过陡，返回第一个不满足的原因。
    public static func validity(
        endA: Point, windowA: WindowID, endB: Point, windowB: WindowID,
        ledges: [Surface], constants: Tunables
    ) -> PlankValidity {
        if windowA == windowB { return .sameWindow }
        guard isOnLedge(endA, window: windowA, ledges: ledges),
              isOnLedge(endB, window: windowB, ledges: ledges) else { return .missingLedge }
        if abs(endA.x - endB.x) > constants.plankMaxSpan { return .tooFar }
        if abs(endA.y - endB.y) > constants.plankMaxRise { return .tooSteep }
        return .valid
    }

    /// 已架设木板的当前有效性（Requirement 9.9）。
    ///
    /// - 任一端窗口为 Hidden_Window 时返回 nil：隐藏期间木板不失效、暂停校验（Requirement 5.2）。
    /// - 任一端窗口已关闭（不在窗口表中）时返回 `.missingLedge`。
    /// - 否则按两端当前屏幕坐标调用 `validity(endA:windowA:endB:windowB:ledges:constants:)`。
    public static func validity(
        of plank: PlacedPlank, windows: WindowTable, ledges: [Surface], constants: Tunables
    ) -> PlankValidity? {
        if windows.isHidden(plank.endA.window) || windows.isHidden(plank.endB.window) { return nil }
        guard let a = plank.endA.screenPoint(windows: windows),
              let b = plank.endB.screenPoint(windows: windows) else { return .missingLedge }
        return validity(
            endA: a, windowA: plank.endA.window, endB: b, windowB: plank.endB.window,
            ledges: ledges, constants: constants)
    }

    // MARK: - 内部

    private static func nearest(to p: Point, in ledges: [Surface]) -> (surface: Surface, point: Point)? {
        var best: (surface: Surface, point: Point)?
        var bestDistance = Double.infinity
        for s in ledges {
            let q = Point(x: min(max(p.x, s.start.x), s.end.x), y: s.start.y)
            let d = hypot(p.x - q.x, p.y - q.y)
            if d < bestDistance {
                bestDistance = d
                best = (s, q)
            }
        }
        return best
    }

    private static func isOnLedge(_ p: Point, window: WindowID, ledges: [Surface]) -> Bool {
        ledges.contains { s in
            s.id.isLedge && s.id.windowID == window
                && abs(p.y - s.start.y) <= epsilon
                && s.start.x - epsilon <= p.x && p.x <= s.end.x + epsilon
        }
    }
}
