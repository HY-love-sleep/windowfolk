import Foundation

/// 梯子有效性判定结果。只有 `valid` 表示可以架设或保持架设。
public enum LadderValidity: Hashable, Sendable {
    case valid
    /// 上端不在任何现存 Window_Ledge 上（没有窗沿可吸附、上端窗口已关闭或窗沿消失）。
    case missingLedge
    /// 上端正下方没有 Ground 或 Window_Ledge，或竖直距离不大于 0。
    case noBottom
    /// 上下端竖直距离 > Ladder_Length。
    case tooLong

    public var isValid: Bool { self == .valid }
}

/// 梯子的吸附与有效性规则（Requirement 10）。
public enum LadderRules {
    /// 浮点比较容差（pt）。
    public static let epsilon = 1e-6

    /// 上端吸附（Requirement 10.1）：取与指针直线距离最近的 Window_Ledge，
    /// 上端 x 为指针 x 夹紧到该窗沿两端之间，y 为窗沿 y。距离相等时取 `SurfaceID` 较小的一条。
    /// 没有任何 Window_Ledge 时返回 nil。`ledges` 可以是全部 Surface，只考虑 `.ledge`。
    public static func snapTop(pointer: Point, ledges: [Surface]) -> (Point, SurfaceID)? {
        var best: (Point, SurfaceID)?
        var bestDistance = Double.infinity
        for s in ledges.filter({ $0.id.isLedge }).sorted(by: { $0.id < $1.id }) {
            let q = Point(x: min(max(pointer.x, s.start.x), s.end.x), y: s.start.y)
            let d = hypot(pointer.x - q.x, pointer.y - q.y)
            if d < bestDistance {
                bestDistance = d
                best = (q, s.id)
            }
        }
        return best
    }

    /// 下端（Requirement 10.2）：上端正下方（y 严格更大）第一条水平范围包含 `top.x` 的 Ground 或 Window_Ledge。
    /// 并列时取 `SurfaceID` 较小者。Plank 不作为梯子下端。没有时返回 nil。
    public static func bottom(below top: Point, surfaces: [Surface]) -> (Point, SurfaceID)? {
        var best: (Point, SurfaceID)?
        for s in surfaces where !isPlank(s.id) {
            guard top.x >= s.start.x - epsilon, top.x <= s.end.x + epsilon else { continue }
            let y = s.y(atX: top.x)
            guard y > top.y + epsilon else { continue }
            if let b = best, !(y < b.0.y || (y == b.0.y && s.id < b.1)) { continue }
            best = (Point(x: top.x, y: y), s.id)
        }
        return best
    }

    /// 唯一的梯子长度判定，拖动预览与架设后的失效检测共用（Requirement 10.3、10.4、10.8）。
    /// `top` 为 nil 表示没有吸附到窗沿；有效当且仅当上端已吸附、下端存在且竖直距离在 (0, Ladder_Length]。
    public static func validity(top: Point?, bottom: Point?, constants: Tunables) -> LadderValidity {
        guard let top else { return .missingLedge }
        guard let bottom else { return .noBottom }
        let d = bottom.y - top.y
        if d <= epsilon { return .noBottom }
        if d > constants.ladderLength + epsilon { return .tooLong }
        return .valid
    }

    /// 拖动预览：吸附上端、计算下端并判定（Requirement 10.1 至 10.4）。
    /// 没有 Window_Ledge 时 `top` 为 nil，调用方让预览跟随指针并显示红色。
    public static func preview(pointer: Point, surfaces: [Surface], constants: Tunables)
        -> (top: (Point, SurfaceID)?, bottom: (Point, SurfaceID)?, validity: LadderValidity)
    {
        guard let top = snapTop(pointer: pointer, ledges: surfaces) else {
            return (nil, nil, .missingLedge)
        }
        let bot = bottom(below: top.0, surfaces: surfaces)
        return (top, bot, validity(top: top.0, bottom: bot?.0, constants: constants))
    }

    /// 已架设梯子的当前有效性（Requirement 10.8）。
    ///
    /// - 上端窗口为 Hidden_Window 时返回 nil：隐藏期间不失效、暂停校验（Requirement 5.2）。
    /// - 上端窗口已关闭，或上端不在该窗口的现存 Window_Ledge 上时返回 `.missingLedge`。
    /// - 否则按当前上端重新计算下端，并用 `validity(top:bottom:constants:)` 判定。
    public static func validity(
        of ladder: PlacedLadder, windows: WindowTable, surfaces: [Surface], constants: Tunables
    ) -> LadderValidity? {
        if windows.isHidden(ladder.top.window) { return nil }
        guard let t = ladder.topPoint(windows: windows),
              ledge(containing: t, window: ladder.top.window, surfaces: surfaces) != nil
        else { return .missingLedge }
        return validity(top: t, bottom: bottom(below: t, surfaces: surfaces)?.0, constants: constants)
    }

    /// 按当前上端重新计算下端（Requirement 10.7）。上端窗口不可见或下方没有 Surface 时返回 nil，
    /// 调用方保持原值（隐藏）或按 `validity(of:...)` 让梯子失效。
    public static func refreshed(
        _ ladder: PlacedLadder, windows: WindowTable, surfaces: [Surface]
    ) -> PlacedLadder? {
        guard let t = ladder.topPoint(windows: windows),
              let (b, sid) = bottom(below: t, surfaces: surfaces) else { return nil }
        var l = ladder
        l.bottom = b
        l.bottomSurface = sid
        return l
    }

    /// `window` 的现存 Window_Ledge 中包含点 `p`（y 相等、x 在范围内）的一条；并列取 `SurfaceID` 较小者。
    public static func ledge(containing p: Point, window: WindowID, surfaces: [Surface]) -> Surface? {
        surfaces
            .filter { s in
                s.id.windowID == window
                    && abs(p.y - s.start.y) <= epsilon
                    && s.start.x - epsilon <= p.x && p.x <= s.end.x + epsilon
            }
            .min { $0.id < $1.id }
    }

    private static func isPlank(_ id: SurfaceID) -> Bool {
        if case .plank = id { return true }
        return false
    }
}
