import Foundation

// MARK: - 指针事件与手势

/// 应用层翻译好的鼠标左键事件（Core 坐标）。
public enum PointerEvent: Hashable, Sendable {
    case down(Point)
    case moved(Point)
    case up(Point)

    public var point: Point {
        switch self {
        case let .down(p), let .moved(p), let .up(p): return p
        }
    }
}

/// 拖动中的对象。
public enum DragSubject: Hashable, Sendable {
    /// 从 Toolbox Plank 区拖出、尚未放下的新木板。松手时才分配 `PlankID`。
    case newPlank
    /// 从 Toolbox Ladder 区拖出、尚未放下的新梯子。松手时才分配 `LadderID`。
    case newLadder
    /// 已落下、被拖起的木板。拖动期间它在 `PlankStore` 中的状态为 `.dragged`。
    case plank(PlankID)
    /// 已落下、被拖起的梯子。拖动期间它在 `LadderStore` 中的状态为 `.dragged`。
    case ladder(LadderID)
    /// 被拖起的物件。拖动期间它在 `ItemStore` 中的 placement 为 `.dragged`。
    case item(ItemID)
    /// 被拖动的 Decor（从 Decor_Slot 新建或从世界中拖起）。拖动期间它在 `DecorStore` 中的 placement 为
    /// `.dragged`，位置为 `pointer - grabOffset`（v2 Requirement 3.1）。
    case decor(DecorID)
}

/// 鼠标手势状态机。
public enum Gesture: Hashable, Sendable {
    case none
    /// 已按下，指针相对按下点的位移尚未超过 Click_Drag_Threshold。
    case pressed(on: HitTarget, at: Point)
    /// 拖动中。对象的未吸附位置为 `pointer - grabOffset`（Requirement 11.2）。
    case dragging(DragSubject, grabOffset: Point, pointer: Point)
    /// 吞掉本次按下到松开的全部事件，不改变世界（例如在居民身上拖动，Requirement 7.11）。
    case swallowed

    public var isDragging: Bool {
        if case .dragging = self { return true }
        return false
    }

    /// 从按下到松开期间都为 true；应用层据此在拖动中保持 Overlay 接收鼠标事件。
    public var isActive: Bool { self != .none }
}

// MARK: - 预览

/// 拖动预览的几何形状。
public enum PreviewGeometry: Hashable, Sendable {
    /// 木板两端已吸附到两条不同窗口的 Window_Ledge 上。
    case snappedPlank(endA: Point, endB: Point, windowA: WindowID, windowB: WindowID)
    /// 木板未吸附，平放，底边中点在 `bottomCenter`（无吸附时等于指针减去抓取偏移，Requirement 9.2）。
    case loosePlank(bottomCenter: Point)
    /// 梯子上端已吸附到 `topSurface`（Window_Ledge）上的 `top`；`bottom` 为上端正下方第一条
    /// Ground 或 Window_Ledge 上的点，没有时为 nil（Requirement 10.1、10.2）。
    case snappedLadder(top: Point, bottom: Point?, topSurface: SurfaceID)
    /// 梯子未吸附（屏幕上没有 Window_Ledge），平放，底边中点在 `bottomCenter`，跟随指针（Requirement 10.4）。
    case looseLadder(bottomCenter: Point)
}

/// 拖动预览：几何形状与绿色（有效）/ 红色（无效）。
public struct Preview: Hashable, Sendable {
    public var subject: DragSubject
    public var geometry: PreviewGeometry
    /// 绿色为 true，红色为 false。木板由 `PlankRules.validity` 唯一判定（Requirement 9.12）。
    public var isValid: Bool

    public init(subject: DragSubject, geometry: PreviewGeometry, isValid: Bool) {
        self.subject = subject
        self.geometry = geometry
        self.isValid = isValid
    }
}

// MARK: - 输入与输出

/// InteractionController 需要的只读世界信息。
public struct InteractionContext: Sendable {
    public var screen: ScreenInfo
    public var windows: WindowTable
    /// 当前全部 Surface（含 Ground、Window_Ledge 和已架设木板）。
    public var surfaces: [Surface]
    /// 当前帧的命中区域。默认取 `HitTesting.regions(for:)`；任务 6.10 起由 WorldView 一并输出木板等区域。
    public var hitRegions: [HitRegion]
    /// Unlocked_Decor，决定 Toolbox 取物区布局（v2 Requirement 2.1、2.2）。须与 `hitRegions` 中 Toolbox 区域的布局一致。
    public var unlockedDecor: Set<DecorType>
    /// 点击时不跳跃、只显示「?」的居民（`InteractionController.poke` 的 `jumpAllowed` 为 false），
    /// 由 WorldEngine 按状态和是否在追逐中给出（v2 Requirement 5.9、20.9、21.8）。
    public var jumpBlocked: Set<ResidentID>

    public init(
        screen: ScreenInfo, windows: WindowTable, surfaces: [Surface], hitRegions: [HitRegion],
        unlockedDecor: Set<DecorType> = [], jumpBlocked: Set<ResidentID> = []
    ) {
        self.unlockedDecor = unlockedDecor
        self.jumpBlocked = jumpBlocked
        self.screen = screen
        self.windows = windows
        self.surfaces = surfaces
        self.hitRegions = hitRegions
    }
}

/// 一次指针事件带来的世界变化，供 WorldEngine 产生事件记录（任务 14.3）和调整轮询频率。
public enum InteractionOutcome: Hashable, Sendable {
    /// 点击了居民（无论是否跳跃）。
    case poked(ResidentID)
    /// 开始拖动某个对象（Requirement 24.5）。
    case dragStarted(DragSubject)
    /// 木板在绿色预览下松手，已架设（对应 `plank_placed`）。
    case plankPlaced(PlankID)
    /// 木板在红色预览下松手，开始下落（对应 `plank_dropped`）。
    case plankDropped(PlankID)
    /// 梯子在绿色预览下松手，已架设（对应 `ladder_placed`）。
    case ladderPlaced(LadderID)
    /// 梯子在红色预览下松手，开始下落（对应 `ladder_dropped`）。
    case ladderDropped(LadderID)
    /// 物件松手时正下方 Drop_Snap_Distance 内有 Window_Ledge，已附着到该窗口（Requirement 11.3、11.4）。
    case itemAttached(ItemID)
    /// 物件松手时正下方没有可接住的 Window_Ledge，开始下落（Requirement 11.5）。
    case itemDropped(ItemID)
    /// Decor_Slot 拖动超过 Click_Drag_Threshold 时场上 Decor 已达 Max_Decor_Count：不新建，
    /// 调用方让该 Decor_Slot 晃动一次（v2 Requirement 2.4）。
    case decorLimitReached(DecorType)
    /// Decor 松手后附着到 Window_Ledge 或已架设 Plank（对应 `decor_placed`，v2 Requirement 3.2、3.10）。
    case decorPlaced(DecorID, DecorType, surface: SurfaceKindTag)
    /// Decor 松手后开始玩家下落，落地时写 `decor_placed`（v2 Requirement 3.3、3.10）。
    case decorDropped(DecorID)
    /// 已放置过的 Decor 收回 Toolbox，已从世界中移除（对应 `decor_removed`，v2 Requirement 3.4）。
    case decorRemoved(DecorID, DecorType)
    /// 刚从 Decor_Slot 新建的 Decor 放回 Toolbox，已丢弃，不写事件（v2 Requirement 3.5）。
    case decorDiscarded(DecorID)

    /// 本结果改变了已架设的通路（木板或梯子架设、松手下落），调用方应重算路面与通路图。
    /// Decor 不影响路面和通路（v2 Requirement 3.11）。
    public var changesTopology: Bool {
        switch self {
        case .plankPlaced, .plankDropped, .ladderPlaced, .ladderDropped: return true
        case .poked, .dragStarted, .itemAttached, .itemDropped,
             .decorLimitReached, .decorPlaced, .decorDropped, .decorRemoved, .decorDiscarded: return false
        }
    }
}

// MARK: - InteractionController

/// 点击与拖动判定、木板与梯子拖放、物件拖放、Decor 拖出与拖放（v2 Requirement 2、3）、戳居民（Requirement 7、8、9、10、11）。
///
/// 纯函数：只修改传入的手势、木板、梯子、物件、Decor 存储和居民。坐标都是 Core 坐标。
public enum InteractionController {
    /// 红色松手时，下落起点比预览中较高一端高出的距离（pt）。
    /// `Physics` 不把起点所在的 Surface 当作落点；抬高一点，使与端点同高的窗沿能接住木板或梯子。
    public static let releaseLift: Double = 1

    // MARK: 命中

    /// 在上下文的命中区域中查找点 `p` 命中的对象。Toolbox 两区之间边上的点归右侧区，
    /// 与 `HitTesting.hitTest(_:world:)` 一致。
    public static func hitTest(_ p: Point, context: InteractionContext) -> HitTarget? {
        let target = HitTesting.hitTest(p, regions: context.hitRegions)
        if case .toolbox = target {
            return ToolboxLayout.zone(at: p, screen: context.screen, unlocked: context.unlockedDecor).map(HitTarget.toolbox)
        }
        return target
    }

    // MARK: 事件处理

    /// 处理一个指针事件（不涉及梯子的旧调用方式；梯子操作作用于一个临时存储后丢弃）。
    @discardableResult
    public static func handle(
        _ event: PointerEvent, gesture: inout Gesture, context: InteractionContext,
        planks: inout PlankStore, residents: inout [ResidentID: Resident], constants: Tunables
    ) -> [InteractionOutcome] {
        var ladders = LadderStore()
        return handle(event, gesture: &gesture, context: context, planks: &planks, ladders: &ladders,
                      residents: &residents, constants: constants)
    }

    /// 处理一个指针事件（不涉及物件的调用方式；物件操作作用于一个临时存储后丢弃）。
    @discardableResult
    public static func handle(
        _ event: PointerEvent, gesture: inout Gesture, context: InteractionContext,
        planks: inout PlankStore, ladders: inout LadderStore,
        residents: inout [ResidentID: Resident], constants: Tunables
    ) -> [InteractionOutcome] {
        var items = ItemStore()
        return handle(event, gesture: &gesture, context: context, planks: &planks, ladders: &ladders,
                      items: &items, residents: &residents, constants: constants)
    }

    /// 处理一个指针事件（不涉及 Decor 的调用方式；Decor 操作作用于一个临时存储后丢弃）。
    @discardableResult
    public static func handle(
        _ event: PointerEvent, gesture: inout Gesture, context: InteractionContext,
        planks: inout PlankStore, ladders: inout LadderStore, items: inout ItemStore,
        residents: inout [ResidentID: Resident], constants: Tunables
    ) -> [InteractionOutcome] {
        var decors = DecorStore()
        return handle(event, gesture: &gesture, context: context, planks: &planks, ladders: &ladders,
                      items: &items, decors: &decors, residents: &residents, constants: constants)
    }

    /// 处理一个指针事件。
    @discardableResult
    public static func handle(
        _ event: PointerEvent, gesture: inout Gesture, context: InteractionContext,
        planks: inout PlankStore, ladders: inout LadderStore, items: inout ItemStore,
        decors: inout DecorStore, residents: inout [ResidentID: Resident], constants: Tunables
    ) -> [InteractionOutcome] {
        var outcomes: [InteractionOutcome] = []
        switch event {
        case let .down(p):
            // 上一次手势没收到松开：先在最后位置结束它。
            if gesture != .none {
                outcomes += finish(at: lastPointer(gesture) ?? p, gesture: &gesture, context: context,
                                   planks: &planks, ladders: &ladders, items: &items, decors: &decors,
                                   residents: &residents, constants: constants)
            }
            if let target = hitTest(p, context: context) {
                gesture = .pressed(on: target, at: p)
            } else {
                gesture = .none
            }

        case let .moved(p):
            switch gesture {
            case let .pressed(target, start):
                if distance(p, start) > constants.clickDragThreshold {
                    gesture = beginDrag(on: target, pressedAt: start, pointer: p, context: context,
                                        planks: &planks, ladders: &ladders, items: &items, decors: &decors,
                                        constants: constants, outcomes: &outcomes)
                }
            case let .dragging(subject, grab, _):
                gesture = .dragging(subject, grabOffset: grab, pointer: p)
            case .none, .swallowed:
                break
            }

        case let .up(p):
            // 松开点也可能超过阈值（没有中间的 moved 事件）。
            if case let .pressed(target, start) = gesture, distance(p, start) > constants.clickDragThreshold {
                gesture = beginDrag(on: target, pressedAt: start, pointer: p, context: context,
                                    planks: &planks, ladders: &ladders, items: &items, decors: &decors,
                                    constants: constants, outcomes: &outcomes)
            }
            if case let .dragging(subject, grab, _) = gesture {
                gesture = .dragging(subject, grabOffset: grab, pointer: p)
            }
            outcomes += finish(at: p, gesture: &gesture, context: context,
                               planks: &planks, ladders: &ladders, items: &items, decors: &decors,
                               residents: &residents, constants: constants)
        }
        return outcomes
    }

    // MARK: 预览

    /// 当前拖动的预览；不在拖动中时为 nil。
    ///
    /// 木板：吸附用指针位置（Requirement 9.1）；不能吸附时平放在 `pointer - grabOffset` 并判为无效
    /// （Requirement 9.2，从 Toolbox 拖出时抓取偏移为 0，即以指针为中心）。
    /// 能吸附时颜色由 `PlankRules.validity` 决定（Requirement 9.3、9.4、9.12）。
    /// 梯子：见 `ladderPreview`。
    public static func preview(gesture: Gesture, context: InteractionContext, constants: Tunables) -> Preview? {
        guard case let .dragging(subject, grab, pointer) = gesture else { return nil }
        switch subject {
        case .newPlank, .plank:
            return plankPreview(subject: subject, pointer: pointer, grabOffset: grab,
                                surfaces: context.surfaces, constants: constants)
        case .newLadder, .ladder:
            return ladderPreview(subject: subject, pointer: pointer, grabOffset: grab,
                                 surfaces: context.surfaces, constants: constants)
        case .item, .decor:
            // 物件和 Decor 没有绿色 / 红色预览；拖动中的位置由 `draggedItemPosition` / `draggedDecorPosition`
            // 给出，渲染为普通物件或 Decor。
            return nil
        }
    }

    /// 拖动中 Decor 的底边中点：指针减去抓取偏移（v2 Requirement 3.1）。不在拖动该 Decor 时为 nil。
    public static func draggedDecorPosition(_ id: DecorID, gesture: Gesture) -> Point? {
        guard case let .dragging(.decor(dragged), grab, pointer) = gesture, dragged == id else { return nil }
        return Point(x: pointer.x - grab.x, y: pointer.y - grab.y)
    }

    /// 从 Decor_Slot 新建 Decor 时的抓取偏移：光标位于 Decor 图形中心（v2 Requirement 2.3）。
    public static func freshDecorGrabOffset(_ type: DecorType) -> Point {
        Point(x: 0, y: -SpriteMetrics.decorSize(type).height / 2)
    }

    /// 拖动中物件的底边中点：指针减去按下时的抓取偏移（Requirement 11.2）。不在拖动该物件时为 nil。
    public static func draggedItemPosition(_ id: ItemID, gesture: Gesture) -> Point? {
        guard case let .dragging(.item(dragged), grab, pointer) = gesture, dragged == id else { return nil }
        return Point(x: pointer.x - grab.x, y: pointer.y - grab.y)
    }

    /// 物件松手的去处（Requirement 11.3 至 11.6）。`release` 为物件松手时的底边中点。
    ///
    /// 先把 x 夹紧到主显示器宽度；再在该 x 处、松开点正下方竖直距离 [0, Drop_Snap_Distance] 内的
    /// Window_Ledge 中取竖直距离最小的一条（并列时按 `SurfaceID` 顺序），附着到其所属窗口，
    /// offset = 夹紧后的 x − 窗口左边缘。被前方窗口遮挡的上沿部分不是 Window_Ledge，不会接住物件。
    /// 没有这样的窗沿时从夹紧后的松开点开始下落。
    ///
    /// 竖直距离为 0（恰好放在窗沿上）也算接住：`Physics` 不把下落起点所在的 Surface 当作落点，
    /// 否则物件会穿过它。
    public static func itemRelease(
        at release: Point, surfaces: [Surface], windows: WindowTable, screen: ScreenInfo, constants: Tunables
    ) -> ItemPlacement {
        let x = Physics.clampX(release.x, screen: screen)
        let eps = 1e-9
        var best: (dy: Double, surface: Surface, snap: WindowSnapshot)?
        for s in surfaces.sorted(by: { $0.id < $1.id }) {
            guard s.id.isLedge, let wid = s.id.windowID, let snap = windows.visibleSnapshot(wid),
                  s.start.x - eps <= x, x <= s.end.x + eps else { continue }
            let dy = s.y(atX: x) - release.y
            guard dy >= -eps, dy <= constants.dropSnapDistance + eps else { continue }
            if best == nil || dy < best!.dy { best = (dy, s, snap) }
        }
        if let b = best {
            return .attached(.window(b.snap.id, offset: x - b.snap.frame.minX))
        }
        return .falling(Physics.startFall(at: Point(x: x, y: release.y), screen: screen))
    }

    /// 木板预览（不依赖手势，便于测试 Property 16、17）。
    public static func plankPreview(
        subject: DragSubject = .newPlank, pointer: Point, grabOffset: Point = Point(x: 0, y: 0),
        surfaces: [Surface], constants: Tunables
    ) -> Preview {
        if let s = PlankRules.snap(pointer: pointer, ledges: surfaces) {
            let v = PlankRules.validity(endA: s.endA, windowA: s.windowA, endB: s.endB, windowB: s.windowB,
                                        ledges: surfaces, constants: constants)
            return Preview(subject: subject,
                           geometry: .snappedPlank(endA: s.endA, endB: s.endB, windowA: s.windowA, windowB: s.windowB),
                           isValid: v.isValid)
        }
        let center = Point(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y)
        return Preview(subject: subject, geometry: .loosePlank(bottomCenter: center), isValid: false)
    }

    /// 梯子预览（Requirement 10.1 至 10.4、10.10）。
    ///
    /// 有 Window_Ledge 时上端吸附到离指针最近的窗沿（x 取指针 x 夹紧到窗沿两端），下端为上端正下方第一条
    /// Ground 或 Window_Ledge；颜色由 `LadderRules.validity` 决定（竖直距离在 (0, Ladder_Length] 为绿色）。
    /// 没有 Window_Ledge 时平放在 `pointer - grabOffset`，跟随指针，红色。
    public static func ladderPreview(
        subject: DragSubject = .newLadder, pointer: Point, grabOffset: Point = Point(x: 0, y: 0),
        surfaces: [Surface], constants: Tunables
    ) -> Preview {
        let pv = LadderRules.preview(pointer: pointer, surfaces: surfaces, constants: constants)
        if let (top, sid) = pv.top {
            return Preview(subject: subject,
                           geometry: .snappedLadder(top: top, bottom: pv.bottom?.0, topSurface: sid),
                           isValid: pv.validity.isValid)
        }
        let center = Point(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y)
        return Preview(subject: subject, geometry: .looseLadder(bottomCenter: center), isValid: false)
    }

    // MARK: - 内部：开始拖动

    private static func beginDrag(
        on target: HitTarget, pressedAt start: Point, pointer: Point,
        context: InteractionContext, planks: inout PlankStore, ladders: inout LadderStore,
        items: inout ItemStore, decors: inout DecorStore, constants: Tunables,
        outcomes: inout [InteractionOutcome]
    ) -> Gesture {
        let g = beginDragGesture(on: target, pressedAt: start, pointer: pointer, context: context,
                                 planks: &planks, ladders: &ladders, items: &items, decors: &decors,
                                 constants: constants, outcomes: &outcomes)
        if case let .dragging(subject, _, _) = g { outcomes.append(.dragStarted(subject)) }
        return g
    }

    private static func beginDragGesture(
        on target: HitTarget, pressedAt start: Point, pointer: Point,
        context: InteractionContext, planks: inout PlankStore, ladders: inout LadderStore,
        items: inout ItemStore, decors: inout DecorStore, constants: Tunables,
        outcomes: inout [InteractionOutcome]
    ) -> Gesture {
        let zero = Point(x: 0, y: 0)
        switch target {
        case .toolbox(.plank):
            // Requirement 8.5、8.9：数量不限，松手时才分配 ID。
            return .dragging(.newPlank, grabOffset: zero, pointer: pointer)
        case .toolbox(.ladder):
            // Requirement 8.6、8.9：数量不限，松手时才分配 ID。
            return .dragging(.newLadder, grabOffset: zero, pointer: pointer)
        case let .toolbox(.decor(type)):
            // v2 Requirement 2.3、2.4、2.6、2.7：先进存储再拖动，数量含拖动中的 Decor；已满时不新建、
            // 不预览，吞掉本次手势，并报告让该 Decor_Slot 晃动。
            let grab = freshDecorGrabOffset(type)
            guard let id = decors.makeDecor(type, grabOffset: grab, max: constants.maxDecorCount) else {
                outcomes.append(.decorLimitReached(type))
                return .swallowed
            }
            return .dragging(.decor(id), grabOffset: grab, pointer: pointer)
        case let .decor(id):
            // v2 Requirement 3.6：放在窗沿、木板或 Ground 上的 Decor 都可以拖起；下落中的 Decor 不可拖。
            guard var d = decors.decors[id], case let .attached(a) = d.placement,
                  let pos = AttachmentResolver.screenPosition(
                    a, windows: context.windows, planks: planks.lookup(windows: context.windows),
                    ladders: ladders.lookup(windows: context.windows), screen: context.screen)
            else { return .swallowed }
            let grab = Point(x: start.x - pos.x, y: start.y - pos.y)
            d.placement = .dragged(grabOffset: grab, fresh: false)
            decors.decors[id] = d
            return .dragging(.decor(id), grabOffset: grab, pointer: pointer)
        case let .plank(id):
            // 只有落下的木板可以拖起（Requirement 9.11、11.1）；已架设、下落中的木板不可拖。
            guard case let .loose(a)? = planks.planks[id],
                  let pos = AttachmentResolver.screenPosition(a, windows: context.windows, screen: context.screen)
            else { return .swallowed }
            planks.planks[id] = .dragged
            let grab = Point(x: start.x - pos.x, y: start.y - pos.y)
            return .dragging(.plank(id), grabOffset: grab, pointer: pointer)
        case let .ladder(id):
            // 只有落下的梯子可以拖起（Requirement 10.10、11.1）；已架设、下落中的梯子不可拖。
            guard case let .loose(a)? = ladders.ladders[id],
                  let pos = AttachmentResolver.screenPosition(a, windows: context.windows, screen: context.screen)
            else { return .swallowed }
            ladders.ladders[id] = .dragged
            let grab = Point(x: start.x - pos.x, y: start.y - pos.y)
            return .dragging(.ladder(id), grabOffset: grab, pointer: pointer)
        case .resident:
            // Requirement 7.11：在居民上拖动不做任何事。
            return .swallowed
        case let .item(id):
            // 只有放着的物件（窗沿、木板或 Ground 上）可以拖起（Requirement 11.1）；
            // 被居民持有的物件忽略按下和拖动（Requirement 11.8），下落中的物件也不可拖。
            guard var item = items[id], case let .attached(a) = item.placement,
                  let pos = AttachmentResolver.screenPosition(
                    a, windows: context.windows, planks: planks.lookup(windows: context.windows),
                    ladders: ladders.lookup(windows: context.windows), screen: context.screen)
            else { return .swallowed }
            let grab = Point(x: start.x - pos.x, y: start.y - pos.y)
            item.placement = .dragged(grabOffset: grab)
            items[id] = item
            return .dragging(.item(id), grabOffset: grab, pointer: pointer)
        }
    }

    // MARK: - 内部：松开

    private static func finish(
        at p: Point, gesture: inout Gesture, context: InteractionContext,
        planks: inout PlankStore, ladders: inout LadderStore, items: inout ItemStore,
        decors: inout DecorStore, residents: inout [ResidentID: Resident], constants: Tunables
    ) -> [InteractionOutcome] {
        defer { gesture = .none }
        switch gesture {
        case let .pressed(target, _):
            // 点击。只有居民响应点击；点击 Toolbox 不新建任何对象（Requirement 8.8）。
            if case let .resident(id) = target, residents[id] != nil {
                poke(&residents[id]!, constants: constants, jumpAllowed: !context.jumpBlocked.contains(id))
                return [.poked(id)]
            }
            return []
        case let .dragging(subject, grab, _):
            switch subject {
            case .newPlank, .plank:
                return [dropPlank(subject: subject, pointer: p, grabOffset: grab,
                                  context: context, planks: &planks, constants: constants)]
            case .newLadder, .ladder:
                return [dropLadder(subject: subject, pointer: p, grabOffset: grab,
                                   context: context, ladders: &ladders, constants: constants)]
            case let .item(id):
                // 拖动期间物件被移除（例如重新开始剧情）时不做任何事。
                guard var item = items[id], case .dragged = item.placement else { return [] }
                let release = Point(x: p.x - grab.x, y: p.y - grab.y)
                item.placement = itemRelease(at: release, surfaces: context.surfaces, windows: context.windows,
                                             screen: context.screen, constants: constants)
                items[id] = item
                if case .attached = item.placement { return [.itemAttached(id)] }
                return [.itemDropped(id)]
            case let .decor(id):
                return dropDecor(id, pointer: p, context: context, decors: &decors, constants: constants)
                    .map { [$0] } ?? []
            }
        case .none, .swallowed:
            return []
        }
    }

    /// Decor 松手，按 `DecorRules.release` 处理（v2 Requirement 3.2 至 3.5、3.10）。
    /// 拖动期间 Decor 被移除（例如重置世界）时不做任何事，返回 nil。
    private static func dropDecor(
        _ id: DecorID, pointer: Point, context: InteractionContext,
        decors: inout DecorStore, constants: Tunables
    ) -> InteractionOutcome? {
        guard var d = decors.decors[id], case let .dragged(grab, fresh) = d.placement else { return nil }
        let toolbox = ToolboxLayout.frame(screen: context.screen, unlocked: context.unlockedDecor)
        let release = DecorRules.release(
            at: pointer, grabOffset: grab, fresh: fresh, toolbox: toolbox, surfaces: context.surfaces,
            windows: context.windows, screen: context.screen, constants: constants)
        switch release {
        case .discard:
            decors.decors[id] = nil
            return .decorDiscarded(id)
        case .remove:
            decors.decors[id] = nil
            return .decorRemoved(id, d.type)
        case let .attach(a, surface):
            d.placement = .attached(a)
            decors.decors[id] = d
            decors.markPlaced(id)
            return .decorPlaced(id, d.type, surface: surface)
        case let .fall(f):
            d.placement = .falling(f, byPlayer: true)
            decors.decors[id] = d
            return .decorDropped(id)
        }
    }

    /// 梯子松手：绿色预览架设为竖直通路（Requirement 10.5），红色预览从松开位置竖直下落（Requirement 10.6）。
    ///
    /// 架设时上端记录为「上端窗口 ID 加相对窗口左边缘的偏移量」（Requirement 10.7）。
    /// 红色且已吸附时从上端稍高处下落（与木板一致，使上端所在窗沿能接住它）；未吸附时从平放位置下落。
    private static func dropLadder(
        subject: DragSubject, pointer: Point, grabOffset: Point,
        context: InteractionContext, ladders: inout LadderStore, constants: Tunables
    ) -> InteractionOutcome {
        let pv = ladderPreview(subject: subject, pointer: pointer, grabOffset: grabOffset,
                               surfaces: context.surfaces, constants: constants)
        let id: LadderID
        if case let .ladder(existing) = subject { id = existing } else { id = ladders.makeID() }

        if pv.isValid, case let .snappedLadder(top, _, topSurface) = pv.geometry,
           let wid = topSurface.windowID, let snap = context.windows.visibleSnapshot(wid),
           let (b, bottomSurface) = LadderRules.bottom(below: top, surfaces: context.surfaces) {
            ladders.ladders[id] = .placed(PlacedLadder(
                id: id, top: PlankEnd(window: wid, offset: top.x - snap.frame.minX),
                bottomSurface: bottomSurface, bottom: b))
            return .ladderPlaced(id)
        }

        let start: Point
        switch pv.geometry {
        case let .snappedLadder(top, _, _):
            start = Point(x: top.x, y: top.y - releaseLift)
        case let .looseLadder(c):
            start = c
        case let .loosePlank(c):
            start = c
        case let .snappedPlank(a, b, _, _):
            start = Point(x: (a.x + b.x) / 2, y: min(a.y, b.y) - releaseLift)
        }
        ladders.ladders[id] = .falling(Physics.startFall(at: start, screen: context.screen))
        return .ladderDropped(id)
    }

    /// 木板松手：绿色预览架设（Requirement 9.5），红色预览从松开位置下落（Requirement 9.8）。
    private static func dropPlank(
        subject: DragSubject, pointer: Point, grabOffset: Point,
        context: InteractionContext, planks: inout PlankStore, constants: Tunables
    ) -> InteractionOutcome {
        let pv = plankPreview(subject: subject, pointer: pointer, grabOffset: grabOffset,
                              surfaces: context.surfaces, constants: constants)
        let id: PlankID
        if case let .plank(existing) = subject { id = existing } else { id = planks.makeID() }

        if pv.isValid, case let .snappedPlank(a, b, wa, wb) = pv.geometry,
           let sa = context.windows.visibleSnapshot(wa), let sb = context.windows.visibleSnapshot(wb) {
            planks.planks[id] = .placed(PlacedPlank(
                id: id,
                endA: PlankEnd(window: wa, offset: a.x - sa.frame.minX),
                endB: PlankEnd(window: wb, offset: b.x - sb.frame.minX)))
            return .plankPlaced(id)
        }

        let start: Point
        switch pv.geometry {
        case let .snappedPlank(a, b, _, _):
            start = Point(x: (a.x + b.x) / 2, y: min(a.y, b.y) - releaseLift)
        case let .loosePlank(c):
            start = c
        case let .snappedLadder(top, _, _):
            start = Point(x: top.x, y: top.y - releaseLift)
        case let .looseLadder(c):
            start = c
        }
        planks.planks[id] = .falling(Physics.startFall(at: start, screen: context.screen))
        return .plankDropped(id)
    }

    // MARK: - 戳居民

    /// 点击时会原地跳一下的状态（Requirement 7.6）；其他状态只显示气泡（Requirement 7.8）。
    public static let jumpingStates: Set<ResidentState> = [.idle, .walking, .carrying, .waiting]

    /// 点击一位居民（Requirement 7.6 至 7.9）。
    ///
    /// - 跳跃或「?」气泡尚未结束：不开始新跳跃，只把气泡剩余时间重置（Requirement 7.9）。
    /// - 否则 `jumpAllowed` 为 true 且处于 `jumpingStates` 中的状态时开始一次跳跃并显示气泡；其他情况只显示气泡。
    ///   `sleeping` 不在 `jumpingStates` 中，只显示「?」（v2 Requirement 5.9）；追逐中的居民由调用方传
    ///   `jumpAllowed: false`（v2 Requirement 20.9、21.8）。
    /// 不改变 Resident_State、Attachment、目标、持有物、`hangElapsed` 和 Walk_Distance。
    public static func poke(_ r: inout Resident, constants: Tunables, jumpAllowed: Bool = true) {
        if var p = r.poke, p.jumpRemaining > 0 || p.bubbleRemaining > 0 {
            p.bubbleRemaining = constants.pokeBubbleDuration
            r.poke = p
            return
        }
        let jump = jumpAllowed && jumpingStates.contains(r.state) ? constants.pokeJumpDuration : 0
        r.poke = PokeState(jumpRemaining: jump, bubbleRemaining: constants.pokeBubbleDuration)
    }

    /// 推进戳居民的计时；两者都结束后清除 `poke`。返回推进前是否在跳跃中
    /// （WorldEngine 在跳跃期间应跳过该居民的移动更新，Requirement 7.7）。
    @discardableResult
    public static func advancePoke(_ r: inout Resident, dt: Double) -> Bool {
        guard var p = r.poke else { return false }
        let dt = dt.isFinite ? max(0, dt) : 0
        let wasJumping = p.jumpRemaining > 0
        p.jumpRemaining = max(0, p.jumpRemaining - dt)
        p.bubbleRemaining = max(0, p.bubbleRemaining - dt)
        r.poke = (p.jumpRemaining > 0 || p.bubbleRemaining > 0) ? p : nil
        return wasJumping
    }

    /// 跳跃的向上显示偏移（pt）：抛物线，中点达到 `pokeJumpHeight`，开始和结束时为 0。
    /// 只用于渲染和命中矩形，不改变 Attachment。
    public static func jumpLift(_ poke: PokeState?, constants: Tunables) -> Double {
        guard let p = poke, p.jumpRemaining > 0, constants.pokeJumpDuration > 0 else { return 0 }
        let u = 1 - min(p.jumpRemaining / constants.pokeJumpDuration, 1)   // 0...1 进度
        return 4 * constants.pokeJumpHeight * u * (1 - u)
    }

    // MARK: - 工具

    private static func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private static func lastPointer(_ g: Gesture) -> Point? {
        switch g {
        case let .pressed(_, p): return p
        case let .dragging(_, _, p): return p
        case .none, .swallowed: return nil
        }
    }
}
