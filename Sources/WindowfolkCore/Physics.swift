import Foundation

/// 下落中对象的状态（Core 坐标，y 向下）。`position` 是对象底边中点。
public struct FallState: Hashable, Sendable, Codable {
    public var position: Point
    /// 竖直速度，pt/s，向下为正。
    public var velocityY: Double

    public init(position: Point, velocityY: Double = 0) {
        self.position = position
        self.velocityY = velocityY
    }
}

/// 重力下落与落地（Requirement 6.3、6.4、6.5、6.7）。
///
/// - 下落只改变 y；x 在开始下落时由 `startFall` 夹紧后保持不变。
/// - 落地检测用扫掠：本帧底边从 y0 移到 y1，在水平范围包含 x 且 `y0 < surface.y(atX: x) <= y1`
///   的 Surface 中取最高（y 最小）的一条，并列时按 `SurfaceID` 取前者。
///   起点恰好在某条 Surface 上（y 相等）时该 Surface 不算落点。
/// - 到达 Ground y 仍未落地时强制落在 Ground 上（理论上不会发生，Debug 构建中断言）。
public enum Physics {
    /// 下落起点 x 的夹紧范围：主显示器宽度与 Ground 水平范围的交集。
    /// Ground 横跨 `visibleFrame`，Dock 在侧边时 `visibleFrame` 比 `frame` 窄，
    /// 夹紧到交集保证落点总在 Ground 范围内（Requirement 6.7）。
    public static func clampX(_ x: Double, screen: ScreenInfo) -> Double {
        let lo = max(screen.frame.minX, screen.visibleFrame.minX)
        let hi = min(screen.frame.maxX, screen.visibleFrame.maxX)
        guard hi >= lo else { return min(max(x, screen.frame.minX), screen.frame.maxX) }
        guard x.isFinite else { return lo }
        return min(max(x, lo), hi)
    }

    /// 从 `position` 开始一次下落：x 夹紧到屏幕范围，初速度为 0。
    public static func startFall(at position: Point, screen: ScreenInfo) -> FallState {
        FallState(position: Point(x: clampX(position.x, screen: screen), y: position.y), velocityY: 0)
    }

    /// 推进一帧下落。落地时把 `s.position.y` 设为落点 Surface 在 x 处的 y、`velocityY` 设为 0，
    /// 并返回该 Surface；未落地返回 nil。调用方根据返回的 Surface 和 `s.position` 构造 Attachment。
    ///
    /// `surfaces` 应包含当前帧全部 Surface（含 Ground）。
    public static func advance(_ s: inout FallState, dt: Double, surfaces: [Surface], gravity: Double) -> Surface? {
        let dt = max(0, dt.isFinite ? dt : 0)
        let x = s.position.x
        let y0 = s.position.y
        let v1 = s.velocityY + gravity * dt
        let y1 = y0 + v1 * dt

        var best: (surface: Surface, y: Double)?
        for surface in surfaces {
            let range = surface.xRange
            guard x >= range.lo, x <= range.hi else { continue }
            let sy = surface.y(atX: x)
            guard y0 < sy, sy <= y1 else { continue }
            if let b = best {
                if sy < b.y || (sy == b.y && surface.id < b.surface.id) {
                    best = (surface, sy)
                }
            } else {
                best = (surface, sy)
            }
        }

        if let b = best {
            s.position = Point(x: x, y: b.y)
            s.velocityY = 0
            return b.surface
        }

        // 兜底：已到达或越过 Ground 却没有扫到任何 Surface。
        // 正常情况下 x 已由 startFall 夹紧到 Ground 范围内，扫掠一定会扫到 Ground；
        // 走到这里说明 x 未夹紧，或起点已在 Ground 上或下方。
        if let ground = surfaces.first(where: { $0.id == .ground }), y1 >= ground.start.y {
            assert(x >= ground.xRange.lo && x <= ground.xRange.hi,
                   "Physics: fall x=\(x) outside Ground range; use Physics.startFall to clamp")
            s.position = Point(x: x, y: ground.start.y)
            s.velocityY = 0
            return ground
        }

        s.position = Point(x: x, y: y1)
        s.velocityY = v1
        return nil
    }
}
