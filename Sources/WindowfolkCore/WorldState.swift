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
