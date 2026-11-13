import Foundation

// Decor 的松手判定与 Chair 占用（design.md「Core：DecorRules」，任务 2.2）。
//
// - Toolbox 外接矩形由调用方传入（`ToolboxLayout.frame(...)` 的结果），本文件不依赖 `ToolboxLayout`。
// - 「松开点」的含义与 v1 物件松手（`InteractionController.itemRelease`）一致：
//   Toolbox 收回距离按光标位置 `pointer` 计算；吸附和下落按松手时 Decor 的底边中点
//   `pointer - grabOffset` 计算，因此松手前后 Decor 不会水平跳动。

/// 松手结果。
public enum DecorRelease: Hashable, Sendable {
    /// 新建的 Decor 放回 Toolbox：丢弃，不写事件（Requirement 3.5）。
    case discard
    /// 已放置过的 Decor 收回 Toolbox：移除，写 `decor_removed`（Requirement 3.4）。
    case remove
    /// 附着到 Window_Ledge 或已架设 Plank，写 `decor_placed`（Requirement 3.2、3.10）。
    case attach(Attachment, surface: SurfaceKindTag)
    /// 竖直下落，`byPlayer = true`，落地时写 `decor_placed`（Requirement 3.3、3.10）。
    case fall(FallState)
}

/// `decor_placed` 事件 `detail` 中的 Surface 类型。
public enum SurfaceKindTag: String, Hashable, Sendable {
    case windowLedge = "window_ledge", plank, ground

    /// Surface 对应的类型标签。
    public init(_ id: SurfaceID) {
        switch id {
        case .ground: self = .ground
        case .ledge: self = .windowLedge
        case .plank: self = .plank
        }
    }
}

public enum DecorRules {
    /// 浮点误差容限（pt），与 v1 物件松手一致。
    static let epsilon = 1e-9

    /// 点到矩形的欧氏距离；点在矩形内（含边）时为 0。
    public static func distance(_ p: Point, to r: Rect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// 松手判定。顺序：先 Toolbox 收回，再 Drop_Snap_Distance 内吸附，最后自由下落。
    ///
    /// 1. `distance(pointer, toolbox) <= Toolbox_Return_Distance`：`fresh` 为 true 返回 `.discard`，否则 `.remove`。
    ///    这一条优先于吸附（Requirement 3.4、3.5）。
    /// 2. 底边中点 `pointer - grabOffset` 的 x 先夹紧到主显示器宽度；在该 x 处、正下方竖直距离
    ///    `[0, Drop_Snap_Distance]` 内的 Window_Ledge（所属窗口可见）和已架设 Plank 中取竖直距离最小的一条；
    ///    距离相同时取 y 较小（较高）的一条，仍相同时按 `SurfaceID` 顺序。x 再夹紧到该 Surface 线段范围
    ///    （Requirement 3.2）。Ground 不参与吸附。
    /// 3. 都没有时从底边中点开始下落（Requirement 3.3）。
    ///
    /// `surfaces` 可以是全部 Surface；其中的 `.plank` 只应包含已架设木板（`SurfaceBuilder` 的输出即如此）。
    public static func release(
        at pointer: Point, grabOffset: Point, fresh: Bool,
        toolbox: Rect, surfaces: [Surface], windows: WindowTable,
        screen: ScreenInfo, constants: Tunables
    ) -> DecorRelease {
        if distance(pointer, to: toolbox) <= constants.toolboxReturnDistance {
            return fresh ? .discard : .remove
        }

        let bottom = Point(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y)
        let x = Physics.clampX(bottom.x, screen: screen)
        let eps = epsilon

        var best: (dy: Double, y: Double, surface: Surface)?
        for s in surfaces.sorted(by: { $0.id < $1.id }) {
            switch s.id {
            case .ground:
                continue
            case let .ledge(wid, _):
                guard windows.visibleSnapshot(wid) != nil else { continue }
            case .plank:
                break
            }
            guard s.start.x - eps <= x, x <= s.end.x + eps else { continue }
            let sy = s.y(atX: x)
            let dy = sy - bottom.y
            guard dy >= -eps, dy <= constants.dropSnapDistance + eps else { continue }
            if let b = best, !(dy < b.dy || (dy == b.dy && sy < b.y)) { continue }
            best = (dy, sy, s)
        }

        if let b = best {
            let cx = min(max(x, b.surface.start.x), b.surface.end.x)
            if let a = AttachmentResolver.attachment(landingOn: b.surface, atX: cx, windows: windows) {
                return .attach(a, surface: SurfaceKindTag(b.surface.id))
            }
        }
        return .fall(Physics.startFall(at: Point(x: x, y: bottom.y), screen: screen))
    }

    /// Chair 是否可用：是 Chair、已附着在某条 Surface 上（不在拖动中或下落中），且没有居民坐在上面。
    public static func isFreeChair(_ d: Decor, seats: [ResidentID: DecorID]) -> Bool {
        guard d.type == .chair, case .attached = d.placement else { return false }
        return !seats.values.contains(d.id)
    }
}
