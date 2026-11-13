import Foundation

/// 世界的全部可变状态，由 `WorldEngine` 独占持有和更新。
///
/// 任务 3.5 只包含窗口与路面相关字段。居民、物件、木板、梯子、剧情、手势和保存时间
/// 随后续任务加入（见 design.md「WorldState」）；新字段都应带默认值，以免破坏已有的构造代码。
public struct WorldState: Sendable {
    /// 主显示器信息；每次 step 用 `FrameInput.screen` 更新。
    public var screen: ScreenInfo
    /// 已知窗口的可见、隐藏状态和最后可见快照。
    public var windows: WindowTable
    /// 当前全部 Surface（Ground + Window_Ledge，按 `SurfaceID` 排序）。
    public var surfaces: [Surface]
    /// 「显示路面」开关，启动时默认关闭（Requirement 1.8）。
    public var showSurfaces: Bool
    /// 场上的居民（任务 5.5 加入）。
    public var residents: [ResidentID: Resident]
    /// 全部木板（已架设、落下、下落中、拖动中，任务 6.10 加入）。
    public var planks: PlankStore
    /// 当前鼠标手势（任务 6.10 加入）。
    public var gesture: Gesture
    /// 当前通路图（任务 8.4 加入）。每次 step 在居民移动之前按最终路面重建；
    /// 只含可见窗口的窗沿和两端窗口都可见的已架设木板（Requirement 5.5、12.1）。
    public var nav: NavGraph
    /// 全部梯子（任务 9.2 加入；任务 9.3 起每次 step 校验已架设梯子、推进下落并参与建图）。
    public var ladders: LadderStore
    /// 全部物件（任务 11.1 加入）。被持有的物件以 `Resident.heldItem` 为准，位置每帧取持有者位置加固定偏移。
    public var items: ItemStore
    /// 剧情状态（任务 13.5 加入）。只在 `WorldEngine.storyEnabled` 为 true 时由 `StoryDirector.update` 推进。
    public var story: StoryState
    /// 全部 Decor 与 Unlocked_Decor（v2 任务 3.1 加入）。Decor 不进入 `SurfaceBuilder` 和 `NavGraph.build`
    /// （v2 Requirement 3.11）；跟随、隐藏、下落规则与窗沿 Item 相同（v2 Requirement 3.9）。
    public var decors: DecorStore = DecorStore()
    /// Decor_Slot 达到上限时的晃动（v2 Requirement 2.4）；没有晃动时为 nil。每次 step 按 dt 减少剩余时间，
    /// 减到 0 时清除。由任务 3.2 的 Decor_Slot 拖出设置。
    public var toolboxShake: ToolboxShake?
    /// 各居民的当前 Activity（v2 任务 5.6）。Busy_Resident 和处于 `falling`、`hanging` 的居民不在其中
    /// （v2 Requirement 4.1）。只在 `WorldEngine.activitiesEnabled` 为 true 时由 `ActivityPlanner` 维护。
    public var activities: [ResidentID: Activity] = [:]
    /// Debug_Menu 昼夜覆盖（v2 Requirement 17.4）。不保存，启动时为 `.auto`。
    public var dayNightOverride: DayNightOverride = .auto
    /// 本帧的 Night 判定结果（v2 Requirement 5.1、5.2），每次 step 在居民移动之前更新。
    public var isNight = false
    /// 全部 Wish 的簿记（v2 任务 7.4）。只在 `WorldEngine.storyEnabled` 为 true 时由 `WishDirector` 推进。
    public var wishes = WishBook()
    /// Thought_Engine 状态（v2 任务 12.9）。不保存；每帧在全部事件产生之后推进。
    public var thoughts = ThoughtEngine()
    public init(
        screen: ScreenInfo,
        windows: WindowTable = WindowTable(),
        surfaces: [Surface] = [],
        showSurfaces: Bool = false,
        residents: [ResidentID: Resident] = [:],
        planks: PlankStore = PlankStore(),
        gesture: Gesture = .none,
        nav: NavGraph = .empty,
        ladders: LadderStore = LadderStore(),
        items: ItemStore = ItemStore(),
        story: StoryState = StoryState()
    ) {
        self.story = story
        self.screen = screen
        self.windows = windows
        self.surfaces = surfaces
        self.showSurfaces = showSurfaces
        self.residents = residents
        self.planks = planks
        self.gesture = gesture
        self.nav = nav
        self.ladders = ladders
        self.items = items
    }

    /// 尚未收到任何帧输入时使用的空屏幕。
    public static let emptyScreen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 0, height: 0),
        visibleFrame: Rect(minX: 0, minY: 0, width: 0, height: 0)
    )
}

/// Decor_Slot 达到上限时的晃动（design.md 中写作 `(zone: ToolboxZone, remaining: Double)?`，
/// 为了让 `WorldView` 保持 `Hashable` 改为结构体）。渲染层按剩余时间画水平正弦偏移。
public struct ToolboxShake: Hashable, Sendable {
    /// 晃动的取物区。
    public var zone: ToolboxZone
    /// 剩余时长（秒），大于 0。
    public var remaining: Double

    public init(zone: ToolboxZone, remaining: Double) {
        self.zone = zone
        self.remaining = remaining
    }
}
