import Foundation

/// 菜单命令。
public enum Command: Hashable, Sendable {
    /// 切换「显示路面」开关（Requirement 1.8、3.11、3.13）。
    case toggleSurfaces
    /// 调试：让都都以嘟嘟当前位置为目标移动；不可达时等待，路线出现后出发（Requirement 26.2、26.3）。
    /// 剧情启用时这是一次临时覆盖，见 `WorldEngine` 的「调试寻找覆盖」说明。
    case debugSeek
    /// 调试：都都未持有 Item 时给它一个 Growth_Stage 为 `pot` 的花盆（非剧情花）；已持有时不变（Requirement 26.4、26.5）。
    case debugGiveFlower
    /// 调试：快进（v2 Requirement 8.8 至 8.10，由 `WishDirector.fastForward` 处理）。剧情未启用时忽略。
    case fastForward
    /// 调试：重置世界（v2 Requirement 17.6，取代 v1「重新开始剧情」）：执行 v1 R20.6 的处理，清除全部 Decor、
    /// Wish、Unlocked_Decor 和相关计数，同一帧重新分配 Home_Window。剧情未启用时忽略。
    case resetWorld
    /// 调试：触发心愿（v2 Requirement 17.2、17.3）。`ResidentID` 为 Wisher；送花时忽略，取下一次的 Giver。
    /// 剧情未启用时忽略。
    case triggerWish(WishType, ResidentID?)
    /// 调试：昼夜覆盖（v2 Requirement 17.4）。同一帧内生效。
    case setDayNight(DayNightOverride)
    /// 调试：解锁全部物件（v2 Requirement 17.5）。新加入的 Decor_Type 各写一条 `decor_unlocked`。
    case unlockAllDecor
}

/// 剧情的渲染信息（任务 13.6 绘制气泡和动画使用）。
public struct StoryView: Hashable, Sendable {
    /// 当前阶段；nil 表示未开局。
    public var stage: StoryStage?
    public var round: Int
    /// 本轮 Giver。
    public var giver: ResidentID
    /// 本轮 Receiver（许愿气泡里画的头像）。
    public var receiver: ResidentID
    /// 本轮 Story_Flower。
    public var currentFlower: ItemID?
    /// 本轮 Fruit。
    public var currentFruit: ItemID?
    /// 种花动画进度（0...1）；不在 `Planting` 时为 0。
    public var plantingProgress: Double

    public init(
        stage: StoryStage?, round: Int, giver: ResidentID, receiver: ResidentID,
        currentFlower: ItemID? = nil, currentFruit: ItemID? = nil, plantingProgress: Double = 0
    ) {
        self.stage = stage
        self.round = round
        self.giver = giver
        self.receiver = receiver
        self.currentFlower = currentFlower
        self.currentFruit = currentFruit
        self.plantingProgress = plantingProgress
    }
}

/// 一个 Game_Loop 周期交给 `WorldEngine.step` 的全部输入。
public struct FrameInput: Sendable {
    public var poll: WindowPollResult
    public var screen: ScreenInfo
    /// 自上一帧以来的玩家鼠标事件（Core 坐标），按发生顺序排列。
    public var pointer: [PointerEvent]
    public var commands: [Command]
    /// Story_Clock 读数（墙上时间）。物理和动画的 dt 由相邻两次读数相减得到。
    public var now: Date
    /// Local_Clock 的时区，用于 Night 判定（v2 Requirement 5.1）。`now` 同时作为 Local_Clock 的时刻。
    public var timeZone: TimeZone
    /// 世界因全屏应用隐藏（v1 R23）。为 true 时两位居民都不显示 Thought（v2 Requirement 14.3）。
    public var worldHidden: Bool
    /// 「小心思」是否生效（已按 `LLMSettingsValidation.effective` 处理，v2 Requirement 14.1、14.10）。
    public var thoughtsEnabled: Bool
    /// 自上一帧以来回到主线程的 Thought 结果 `(请求 id, 结果)`，按返回顺序（v2 Requirement 12.5）。
    public var thoughtResults: [(UInt64, ThoughtResult)]

    public init(
        poll: WindowPollResult, screen: ScreenInfo, pointer: [PointerEvent] = [],
        commands: [Command] = [], now: Date, timeZone: TimeZone = .current,
        worldHidden: Bool = false, thoughtsEnabled: Bool = false, thoughtResults: [(UInt64, ThoughtResult)] = []
    ) {
        self.timeZone = timeZone
        self.worldHidden = worldHidden
        self.thoughtsEnabled = thoughtsEnabled
        self.thoughtResults = thoughtResults
        self.poll = poll
        self.screen = screen
        self.pointer = pointer
        self.commands = commands
        self.now = now
    }
}

/// Game_Loop 的轮询频率档位（Requirement 24）。切换规则见 `PollRatePolicy`。
public enum PollRate: Hashable, Sendable {
    case active
    case idle

    /// 对应的轮询频率（Hz）。
    public func hertz(_ constants: Tunables) -> Double {
        switch self {
        case .active: return constants.activePollRate
        case .idle: return constants.idlePollRate
        }
    }
}

/// 一位居民的渲染信息。
public struct ResidentView: Hashable, Sendable {
    public var id: ResidentID
    public var state: ResidentState
    /// 底边中点的屏幕坐标（Core 坐标），不含戳居民的跳跃偏移。`isHidden` 为 true 时为 nil。
    public var position: Point?
    public var facing: Facing
    /// 附着的窗口（或所站木板的端点窗口）当前是 Hidden_Window：不绘制（Requirement 5.2）。
    public var isHidden: Bool
    public var heldItem: ItemID?
    public var bubble: Bubble?
    public var poke: PokeState?
    /// 戳居民跳跃的向上显示偏移（pt，向上为正）。只影响绘制和命中矩形。
    public var jumpLift: Double
    /// 正在显示的 Thought 文本（已规整，v2 Requirement 14.2）；没有时为 nil。渲染层按 `ThoughtLayout` 布局。
    public var thought: String?
    /// 坐在 Chair 上的显示上移量（pt，向上为正，`SpriteMetrics.residentSeatLift`）；不坐时为 0。
    public var seatLift: Double

    public init(
        id: ResidentID, state: ResidentState, position: Point?, facing: Facing, isHidden: Bool,
        heldItem: ItemID? = nil, bubble: Bubble? = nil, poke: PokeState? = nil, jumpLift: Double = 0,
        thought: String? = nil, seatLift: Double = 0
    ) {
        self.thought = thought
        self.seatLift = seatLift
        self.id = id
        self.state = state
        self.position = position
        self.facing = facing
        self.isHidden = isHidden
        self.heldItem = heldItem
        self.bubble = bubble
        self.poke = poke
        self.jumpLift = jumpLift
    }
}

/// 一块木板的渲染信息。拖动中的木板不在此列，由 `WorldView.preview` 给出。
public struct PlankView: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        /// 已架设：从左端点到右端点的线段（即 Plank Surface），木板厚度向下延伸。
        case placed(left: Point, right: Point)
        /// 落下或下落中：平放，底边中点在 `bottomCenter`。
        case loose(bottomCenter: Point)
    }

    public var id: PlankID
    public var shape: Shape
    /// 正在下落。
    public var isFalling: Bool

    public init(id: PlankID, shape: Shape, isFalling: Bool = false) {
        self.id = id
        self.shape = shape
        self.isFalling = isFalling
    }
}

/// 一架梯子的渲染信息。拖动中的梯子不在此列，由 `WorldView.preview` 给出。
public struct LadderView: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        /// 已架设：竖直，从上端（Window_Ledge 上的点）到下端（Ground 或 Window_Ledge 上的点）。
        case placed(top: Point, bottom: Point)
        /// 落下或下落中：平放，底边中点在 `bottomCenter`。
        case loose(bottomCenter: Point)
    }

    public var id: LadderID
    public var shape: Shape
    /// 正在下落。
    public var isFalling: Bool

    public init(id: LadderID, shape: Shape, isFalling: Bool = false) {
        self.id = id
        self.shape = shape
        self.isFalling = isFalling
    }
}

/// 一个物件的渲染信息。拖动中的物件 `isDragged` 为 true，位置跟随指针。
public struct ItemView: Hashable, Sendable {
    public var id: ItemID
    public var kind: ItemKind
    /// Flower 的生长阶段；Fruit 为 nil。
    public var stage: GrowthStage?
    /// 底边中点的屏幕坐标（Core 坐标）。被持有时为持有者位置加 `ItemHolding.heldOffset`，不含戳跳跃偏移。
    public var position: Point
    /// 持有者；未被持有时为 nil。
    public var holder: ResidentID?
    /// 正在下落。
    public var isFalling: Bool
    /// 持有者戳跳跃的向上显示偏移（pt），与持有者一致；未被持有时为 0。
    public var jumpLift: Double
    /// 正在被玩家拖动。
    public var isDragged: Bool

    public init(
        id: ItemID, kind: ItemKind, stage: GrowthStage?, position: Point, holder: ResidentID? = nil,
        isFalling: Bool = false, jumpLift: Double = 0, isDragged: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.stage = stage
        self.position = position
        self.holder = holder
        self.isFalling = isFalling
        self.jumpLift = jumpLift
        self.isDragged = isDragged
    }

    /// 素材键。
    public var assetKey: String {
        switch kind {
        case .flower: return AssetCatalog.flowerKey(growth: stage ?? .pot)
        case .fruit: return AssetCatalog.fruitKey
        }
    }
}

/// 一个 Decor 的渲染信息（v2 任务 3.1）。附着在 Hidden_Window 上的 Decor 不在 `WorldView.decors` 中。
public struct DecorView: Hashable, Sendable {
    public var id: DecorID
    public var type: DecorType
    /// 底边中点的屏幕坐标（Core 坐标）。
    public var position: Point
    /// 正在下落。
    public var isFalling: Bool
    /// 正在被玩家拖动。
    public var isDragged: Bool

    public init(id: DecorID, type: DecorType, position: Point, isFalling: Bool = false, isDragged: Bool = false) {
        self.id = id
        self.type = type
        self.position = position
        self.isFalling = isFalling
        self.isDragged = isDragged
    }
}

/// 给渲染和命中检测用的只读快照。
public struct WorldView: Hashable, Sendable {
    public var screen: ScreenInfo
    public var surfaces: [Surface]
    public var showSurfaces: Bool
    /// 全部居民，按 `ResidentID` 排序。
    public var residents: [ResidentView]
    /// 可见的木板（已架设、落下、下落中），按 `PlankID` 排序。端点窗口隐藏的木板不在此列。
    public var planks: [PlankView]
    /// 可见的梯子（已架设、落下、下落中），按 `LadderID` 排序。上端窗口隐藏的已架设梯子、
    /// 隐藏窗口上的落下梯子和拖动中的梯子不在此列。
    public var ladders: [LadderView]
    /// 可见的物件（放置、下落中、被可见居民持有），按 `ItemID` 排序。隐藏窗口上的物件和隐藏居民持有的物件不在此列。
    public var items: [ItemView]
    /// 拖动预览（绿色或红色）；不在拖动中时为 nil。
    public var preview: Preview?
    /// 当前帧全部可交互对象的命中区域（外接矩形，Requirement 7.1）。
    /// 应用层的命中检测计时器据此切换 Overlay 的鼠标穿透（Requirement 7.2 至 7.4）。
    public var hitRegions: [HitRegion]
    /// 鼠标手势进行中（从按下到松开）。应用层在此期间保持 Overlay 接收鼠标事件。
    public var isInteracting: Bool
    /// 剧情信息；剧情未启用时为 nil。
    public var story: StoryView?
    /// 可见的 Decor（放置、下落中、拖动中），按 `DecorID` 排序。附着在 Hidden_Window 上的 Decor 不在此列。
    public var decors: [DecorView]
    /// Unlocked_Decor，决定 Toolbox 中 Decor_Slot 的布局（v2 Requirement 2.1、2.2）。
    public var unlockedDecor: Set<DecorType>
    /// Decor_Slot 达到上限时的晃动；没有晃动时为 nil（v2 Requirement 2.4）。
    public var toolboxShake: ToolboxShake?
    /// 各 active Visit_Wish 的 Visit_Flag 位置：Visit_Target 当前最长一段 Window_Ledge 的中点，渲染层画在其上方
    /// （v2 Requirement 9.2）。Visit_Target 隐藏或没有窗沿时不在此列（v2 Requirement 9.7）。按 Wish 顺序。
    public var visitFlags: [Point]
    /// 当前是否为 Night（v2 Requirement 5.10：Lamp 发光）。
    ///
    /// `WorldView` 不含任何倒计时、计数、进度或结局字段，渲染层没有数据可以显示这些内容（v2 Requirement 10.4）。
    public var isNight: Bool

    public init(
        screen: ScreenInfo, surfaces: [Surface], showSurfaces: Bool, residents: [ResidentView] = [],
        planks: [PlankView] = [], ladders: [LadderView] = [], preview: Preview? = nil,
        hitRegions: [HitRegion] = [], isInteracting: Bool = false, items: [ItemView] = [],
        story: StoryView? = nil, decors: [DecorView] = [], unlockedDecor: Set<DecorType> = [],
        toolboxShake: ToolboxShake? = nil, visitFlags: [Point] = [], isNight: Bool = false
    ) {
        self.visitFlags = visitFlags
        self.isNight = isNight
        self.story = story
        self.decors = decors
        self.unlockedDecor = unlockedDecor
        self.toolboxShake = toolboxShake
        self.screen = screen
        self.surfaces = surfaces
        self.showSurfaces = showSurfaces
        self.residents = residents
        self.planks = planks
        self.ladders = ladders
        self.items = items
        self.preview = preview
        self.hitRegions = hitRegions
        self.isInteracting = isInteracting
    }

    /// Toolbox 外框（Requirement 8.1、8.4），按 Unlocked_Decor 布局（v2 Requirement 2.1、2.2）。
    public var toolbox: Rect { ToolboxLayout.frame(screen: screen, unlocked: unlockedDecor) }
}

/// 一次 `step` 的输出。事件列表由任务 14 加入。
public struct StepOutput: Sendable {
    public var view: WorldView
    /// 本次窗口表的变化（新出现、几何或层级变化、隐藏、重新显示、关闭）。
    public var windowChanges: WindowChanges
    /// 本次处理玩家输入带来的变化（戳居民、开始拖动、木板架设或松手下落）。
    public var interactions: [InteractionOutcome]
    /// 本次因校验失效而下落的已架设木板（对应 `plank_dropped`，任务 14.3）。
    public var failedPlanks: [PlankID]
    /// 本次因校验失效而下落的已架设梯子（对应 `ladder_dropped`，任务 14.3）。
    public var failedLadders: [LadderID]
    /// 下一个周期应使用的轮询频率。
    public var nextRate: PollRate
    /// 本次的剧情事件（按发生顺序，含快进和重新开始剧情产生的事件），供事件记录（任务 14.3）使用。
    public var storyEvents: [StoryEvent]
    /// 本次要写入 Event_Log 的事件记录（Requirement 21.1），按发生顺序排列，`time` 为本帧的 `now`（截断到秒）。
    /// 只含 Requirement 21.1 列出的 14 种事件；应用层编码后追加到 `events.jsonl`（任务 14.2）。
    public var events: [EventRecord]
    /// 本帧发出的 Thought 请求（至多一个）。由应用层在 Game_Loop 之外异步执行，结果随之后的
    /// `FrameInput.thoughtResults` 送回（v2 Requirement 12.5）。
    public var thoughtRequests: [ThoughtRequest]

    public init(
        view: WorldView, windowChanges: WindowChanges, interactions: [InteractionOutcome] = [],
        failedPlanks: [PlankID] = [], failedLadders: [LadderID] = [], nextRate: PollRate,
        storyEvents: [StoryEvent] = [], events: [EventRecord] = [], thoughtRequests: [ThoughtRequest] = []
    ) {
        self.thoughtRequests = thoughtRequests
        self.storyEvents = storyEvents
        self.events = events
        self.view = view
        self.windowChanges = windowChanges
        self.interactions = interactions
        self.failedPlanks = failedPlanks
        self.failedLadders = failedLadders
        self.nextRate = nextRate
    }
}

/// 世界更新的唯一入口。同步、无 I/O、无定时器：同样的输入序列（含随机种子）总得到同样的状态。
///
/// 不跨线程使用，由应用层 `@MainActor` 的 GameLoop 独占持有。
public final class WorldEngine {
    /// 单帧 dt 上限（秒），避免睡眠唤醒或调试暂停后一帧跳太远。
    public static let maxDeltaTime: Double = 0.25
    /// 无悬空不变量的竖直容差（pt，Requirement 29.5）。
    public static let supportTolerance: Double = 1.0

    public let constants: Tunables
    public internal(set) var state: WorldState
    /// 上一次 step 的时钟读数；首次 step 之前为构造时传入的 `clockStart`。
    public private(set) var lastNow: Date
    /// 最近一次 step 使用的 dt（秒），已限制在 [0, maxDeltaTime]。
    public private(set) var lastDeltaTime: Double = 0
    /// 居民闲逛等行为使用的随机源。
    public internal(set) var rng: RandomSource
    /// 临时演示用：尚未放置演示居民时为 true。剧情启用时不使用（居民由剧情开局放置）。
    private var demoResidentPending: Bool
    /// 剧情是否启用：启用时每帧调用 `StoryDirector.update`，首次 step 起按窗口开局（Requirement 15）。
    public let storyEnabled: Bool
    /// 调试寻找覆盖（`debugSeek`，Requirement 26.2、26.3）：剧情启用时 `StoryDirector.assignGoals` 每帧按阶段
    /// 重写 Goal，因此「让都都去找嘟嘟」记录下发出命令时的阶段和轮次，在此期间每帧剧情更新之后把都都的 Goal
    /// 设回 `reach(嘟嘟)`。都都走到嘟嘟身边（同一 Surface、x 差 ≤ Gift_Reach_Distance）、Story_Stage 或轮次变化、
    /// 或剧情重新开始时覆盖结束，Goal 回到剧情分配的值。覆盖不改变 Story_Stage。
    var seekOverride: (stage: StoryStage?, round: Int)?
    /// 剧情未启用时的调试寻找（`debugSeek`）进行中：自主活动启用时都都在此期间不由 Activity_Planner 控制，
    /// 走到嘟嘟身边后结束（见 `WorldEngine+V2.swift`）。
    var debugSeekActive = false
    /// 自主活动（Activity_Planner）是否启用（v2 任务 5.6）。见 `init` 的 `activities` 参数。
    public let activitiesEnabled: Bool
    /// Nav_Graph 真正重建的次数（v2 design.md「NavGraph 水平度量」），供追逐判断「Nav_Graph 发生变化」。
    public private(set) var navVersion = 0
    /// Visit_Wish 刚完成、下一次选择 Activity 时应把 `go_home` 放进候选的居民（v2 Requirement 9.8）。
    /// 为其选出下一个 Activity 后移除。不保存。
    var preferHome: Set<ResidentID> = []
    /// Home_Window 分配成功时是否把居民放到家里：首次开局和「重置世界」为 true；恢复存档后为 false，
    /// 只分配家、不移动居民（v2 design.md「已确认决策 2」）。
    private var homesPlaceResidents = true
    /// 本次 step 重算路面之前的木板 Surface，用于确定桥塌那一刻居民的屏幕坐标。
    private var previousPlankSurfaces: [PlankID: Surface] = [:]
    /// 本次 step 中刚进入 `hanging` 的居民：Hang_Duration 从下一帧开始累计，计时起点就是失效那一帧。
    private var justHung: Set<ResidentID> = []
    /// 上次建图时的输入（路面、参与建图的木板与梯子）；不变时不重建 Nav_Graph。
    private var navInputs: (surfaces: [Surface], planks: [PlacedPlank], ladders: [NavLadder])?
    /// 本次 step 正在收集的事件记录（任务 14.3）。
    var eventLog = EventLogBuilder(now: Date(timeIntervalSince1970: 0))
    /// 居民状态的比较基准：每个可能改变居民的阶段之后与之比较，产生 `fell`、`landed`、`waiting_started`、
    /// `crossed_bridge`、`climbed_ladder`，再更新基准。
    private var residentBaseline: [ResidentID: Resident] = [:]
    /// 居民走上木板时离开的窗口；走下木板到另一个窗口时记为过桥。
    private var plankEntry: [ResidentID: (plank: PlankID, window: WindowID?)] = [:]
    /// 居民开始爬梯时离开的 Surface；离开梯子到另一条 Surface 时记为爬梯。
    private var ladderEntry: [ResidentID: (ladder: LadderID, from: String?)] = [:]
    /// 待恢复的存档（任务 16.2）：在第一次成功轮询的那一帧、已知当前窗口和路面之后放回世界。
    /// 恢复之前不推进剧情。
    public private(set) var pendingRestore: SaveFile?
    /// 恢复后仍在下落的对象的落点限制（Requirement 22.6、22.7）。对象落地或不再下落后移除。
    public private(set) var restoreLanding = RestoreLanding()
    /// 轮询频率策略（任务 17.1）。启动为 `.active`。
    public private(set) var pollPolicy = PollRatePolicy()
    /// 上一次 step 输出的画面快照，用于判断本帧有没有可见变化；首次 step 之前为 nil。
    private var previousView: WorldView?

    /// - Parameters:
    ///   - rng: 随机源；默认用系统随机种子，测试应传入固定种子。
    ///   - demoResident: 旧参数，保留以兼容已有调用。`story` 为 nil 时决定剧情是否启用：true（默认）启用剧情，
    ///     由剧情开局放置两位居民；false 时既不启用剧情也不放置任何居民（测试通过 `place(_:)` 自行放置）。
    ///   - story: 显式指定是否启用剧情。为 false 且 `demoResident` 为 true 时，回到旧的临时演示放置：
    ///     第一次 step 在首个可见窗沿中点放 Resident_A、离它最远的另一窗口窗沿放 Resident_B（没有窗沿时放在 Ground 上）。
    ///   - activities: 是否启用自主活动（v2 Activity_Planner）。默认（nil）与剧情相同：剧情启用的完整 V2 世界里
    ///     居民自主活动，Busy_Resident（参与 active Wish 的居民、Wish 完成后庆祝中的居民、调试寻找中的都都）之外的
    ///     居民由 Activity_Planner 选择并推进 Activity。剧情关闭的测试世界默认不启用，居民按 v1 的 Goal 行动
    ///     （`Goal.none` 在当前 Surface 闲逛，v1 Property 24 的调整）；测试可显式传 true 或 false。
    public init(
        constants: Tunables = Tunables(), clockStart: Date, screen: ScreenInfo = WorldState.emptyScreen,
        rng: RandomSource = .systemSeeded(), demoResident: Bool = true, story: Bool? = nil,
        restored: SaveFile? = nil, activities: Bool? = nil
    ) {
        let storyOn = story ?? demoResident
        self.activitiesEnabled = activities ?? storyOn
        self.constants = constants
        self.lastNow = clockStart
        self.rng = rng
        self.storyEnabled = storyOn
        self.demoResidentPending = demoResident && !storyOn && restored == nil
        self.pendingRestore = restored
        self.state = WorldState(screen: screen)
        self.state.surfaces = SurfaceBuilder.build(windows: [], screen: screen)
    }

    /// 由相邻两次时钟读数算出 dt，限制在 [0, maxDeltaTime]；时钟回拨时为 0。
    public static func deltaTime(from previous: Date, to now: Date) -> Double {
        let raw = now.timeIntervalSince(previous)
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), maxDeltaTime)
    }

    /// 放入或替换一位居民（测试和后续剧情开局使用）。同时取消临时演示居民的放置。
    public func place(_ resident: Resident) {
        demoResidentPending = false
        state.residents[resident.id] = resident
    }

    /// 移除一位居民。
    public func remove(_ id: ResidentID) {
        state.residents[id] = nil
    }

    /// 放入或替换一个物件（测试、调试命令和存档恢复使用）。`placement` 为 `.held` 时请改用 `give(_:to:)`。
    public func insertItem(_ item: Item) {
        state.items[item.id] = item
    }

    /// 让居民持有一个物件（新物件或场上已有的物件）。居民不存在、已持有 Item、物件已被持有或正被拖动时
    /// 不改变任何状态，返回 false（Requirement 14.3、11.9）。
    @discardableResult
    public func give(_ item: Item, to id: ResidentID) -> Bool {
        guard var r = state.residents[id] else { return false }
        guard state.items.give(item, to: &r) else { return false }
        state.residents[id] = r
        return true
    }

    /// 放入或替换一个 Decor（测试和存档恢复使用），下一次 step 起生效。不检查 Max_Decor_Count。
    /// 通过 `DecorStore.init` 重建，保证之后新分配的 ID 不与它冲突。
    public func insertDecor(_ decor: Decor) {
        var all = state.decors.decors
        all[decor.id] = decor
        state.decors = DecorStore(
            decors: all, unlocked: state.decors.unlocked,
            nextID: state.decors.nextID, nextSeq: state.decors.nextSeq)
    }

    /// 把 `t` 加入 Unlocked_Decor（测试和存档恢复使用），不写事件记录。
    public func unlockDecor(_ t: DecorType) {
        state.decors.unlock(t)
    }

    /// 放入一块木板（测试和存档恢复使用），返回新分配的 ID。下一次 step 起生效。
    @discardableResult
    public func insertPlank(_ plank: PlankState) -> PlankID {
        let id = state.planks.makeID()
        if case var .placed(p) = plank {
            p.id = id
            state.planks.planks[id] = .placed(p)
        } else {
            state.planks.planks[id] = plank
        }
        return id
    }

    /// 放入一架梯子（测试和存档恢复使用），返回新分配的 ID。下一次 step 起生效；
    /// 已架设梯子的下端在下一次 step 中按上端重新计算。
    @discardableResult
    public func insertLadder(_ ladder: LadderState) -> LadderID {
        let id = state.ladders.makeID()
        if case var .placed(l) = ladder {
            l.id = id
            state.ladders.ladders[id] = .placed(l)
        } else {
            state.ladders.ladders[id] = ladder
        }
        return id
    }

    /// 推进一帧。按 design.md「每帧更新顺序」与「失效处理顺序」执行：
    /// 1. 菜单命令；
    /// 2. `WindowTable.apply` 得到可见、隐藏、关闭变化；
    /// 3. 关闭窗口上的居民和落下的木板按最后可见快照换算屏幕坐标后开始下落（Requirement 5.1、5.8）；
    /// 4. `SurfaceBuilder` 重算路面（含已架设木板）；
    /// 5. 每块已架设木板用 `PlankRules.validity` 校验，失效者下落，站在上面的居民同一帧进入 `hanging`，
    ///    Hang_Duration 后从悬挂处下落；端点窗口隐藏的木板暂停校验（Requirement 5.2、9.9、9.10、13.1 至 13.7）；
    /// 5b. 每架已架设梯子按上端重新计算下端并用 `LadderRules.validity` 校验；失效者下落，梯子上爬梯的居民
    ///    同一帧直接下落、不经过 `hanging`；上端窗口隐藏的梯子暂停校验（Requirement 5.2、10.7、10.8、13.5）；
    /// 6. 可见窗口上的居民、物件和落下的木板、梯子夹紧到剩余窗沿，没有剩余窗沿时下落（Requirement 4.6、4.7）；
    ///    隐藏窗口上的对象保持不变（Requirement 5.3、5.4）；关闭窗口和失效木板上的物件在第 3、5 步开始下落；
    ///    隐藏窗口上的对象保持不变（Requirement 5.3、5.4）；
    /// 7. 玩家输入（点击、拖动、木板与梯子松手）；架设或下落后立即重算路面（Requirement 9.6、10.5）；
    /// 8. 路面、木板或梯子变化时重建 Nav_Graph（Requirement 12.1）；
    /// 8b. 剧情与心愿（剧情启用时，v2 任务 7.4）：Home_Window 未分配时分配并开始 Wish 调度；处理「快进」「重置世界」
    ///    「触发心愿」；`WishDirector.plan`；`StoryDirector.update`（Story_Stage 只在 Flower_Wish 进行中推进）；
    ///    调试寻找覆盖；随后 `ActivityPlanner.plan`。居民移动之后 `WishDirector.resolve`、`ActivityPlanner.resolve`，
    ///    再应用剧情气泡、Wish_Bubble 和 Zzz 覆盖；
    /// 9. 居民行为与下落推进（隐藏窗口上和戳跳跃中的居民跳过移动，Requirement 7.7）；
    /// 10. 下落中的木板和梯子推进并落位（Requirement 9.8、10.6）；
    /// 11. 无悬空不变量检查，违规者转为下落（Requirement 29.5、29.6）。
    /// 11b. v2 第 16 步：`ThoughtEngine.step`（收结果、显示、移除、按本帧事件发请求），写 `thought_shown`；
    /// 12. 轮询频率策略给出下一周期频率（Requirement 24）。
    @discardableResult
    public func step(_ input: FrameInput) -> StepOutput {
        let dt = Self.deltaTime(from: lastNow, to: input.now)
        lastDeltaTime = dt
        lastNow = input.now
        eventLog = EventLogBuilder(now: input.now)
        residentBaseline = state.residents
        for command in input.commands {
            apply(command)
        }
        advanceToolboxShake(dt: dt)

        if input.screen != state.screen {
            state.screen = input.screen
            clampToScreen()
        }
        let changes = state.windows.apply(input.poll)
        let closedByID = Dictionary(changes.closed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        dropOnClosed(closedByID)
        eventLog.closed = closedByID
        noteResidentTransitions()
        previousPlankSurfaces = Dictionary(
            state.surfaces.compactMap { s in s.id.plankID.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        justHung = []
        rebuildSurfaces()
        let placedPlanksBefore = Dictionary(
            state.planks.placedPlanks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let placedLaddersBefore = Dictionary(
            state.ladders.placedLadders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let failed = validatePlanks(closedByID)
        let failedLadders = validateLadders(closedByID)
        for pid in failed {
            recordPlankDropped(pid, placed: placedPlanksBefore[pid], actor: nil, cause: "collapsed")
        }
        for lid in failedLadders {
            recordLadderDropped(lid, placed: placedLaddersBefore[lid], actor: nil, cause: "collapsed")
        }
        noteResidentTransitions()

        placeDemoResidentIfNeeded()
        applyPendingRestore(poll: input.poll, now: input.now)
        rebaselineResidents()
        resolveResidentAttachments()
        resolveLoosePlanks()
        resolveLooseLadders()
        resolveItemAttachments()
        resolveDecorAttachments()
        noteResidentTransitions()

        let interactions = handlePointer(input.pointer)
        recordInteractions(interactions)
        unseatFromDraggedChairs(interactions)
        noteResidentTransitions()

        rebuildNavIfNeeded()
        updateDayNight(now: input.now, timeZone: input.timeZone)
        // 剧情和 Wish 事件在 `updateStory` 内按发生顺序写入事件记录。
        let storyEvents = updateStory(commands: input.commands, now: input.now, dt: dt)
        planActivities(now: input.now)
        // 剧情直接设置的状态（开局落位、种花、庆祝）不属于 Requirement 21.1 的事件，只更新比较基准。
        rebaselineResidents()
        updateResidents(dt: dt)
        noteResidentTransitions()
        resolveWishes(now: input.now)
        resolveActivities(now: input.now)
        applyStoryBubbles()
        applyWishBubbles()
        applyActivityBubbles()
        advanceFallingPlanks(dt: dt)
        advanceFallingLadders(dt: dt)
        reconcileItems()
        advanceFallingItems(dt: dt)
        advanceFallingDecors(dt: dt)
        enforceSupport()
        endAirborneActivities()
        reconcileSeats()
        noteResidentTransitions()
        // v2 第 16 步：全部事件产生之后推进 Thought_Engine（v2 Requirement 14.1），`thought_shown` 追加到本帧记录末尾。
        let thoughtRequests = updateThoughts(input)

        let events = eventLog.records
        eventLog = EventLogBuilder(now: input.now)
        let view = makeView()
        let nextRate = updatePollRate(input: input, changes: changes, view: view)
        return StepOutput(
            view: view, windowChanges: changes, interactions: interactions,
            failedPlanks: failed, failedLadders: failedLadders, nextRate: nextRate, storyEvents: storyEvents,
            events: events, thoughtRequests: thoughtRequests)
    }

    // MARK: - 轮询频率（任务 17.1）

    /// 居民处于这些状态时画面一定在动（或有计时中的动画），保持 Active_Poll_Rate（Requirement 24.4）。
    /// `planting`、`celebrating` 是限时动画，`hanging` 的 Hang_Duration 计时需要 100ms 精度（Requirement 13.4）。
    /// 隐藏窗口上的居民暂停行动，不计入。
    public static let activeResidentStates: Set<ResidentState> = [
        .walking, .carrying, .running, .falling, .hanging, .climbing, .planting, .celebrating,
    ]

    /// 比较本帧与上一帧，生成活动样本并交给 `PollRatePolicy`（Requirement 24.2 至 24.6、29.2）。
    ///
    /// - 窗口变化：`WindowChanges` 非空（新出现、边界或层级变化、隐藏、显示、关闭），或主显示器信息变化。
    /// - 居民变化：上一帧与本帧的 `WorldView` 不同（居民状态、位置、气泡、戳跳跃，以及物件、木板、梯子的
    ///   下落和种花进度等任何可见变化），或有可见居民处于 `activeResidentStates`。
    ///   因此 Requirement 29.1 的静止桌面（居民 `idle` 或 `waiting` 且不动、生长阶段不变）才会进入 Idle。
    /// - 拖拽：手势进行中（从按下到松开），或本帧收到鼠标事件。
    private func updatePollRate(input: FrameInput, changes: WindowChanges, view: WorldView) -> PollRate {
        let windowsChanged = !changes.isEmpty || previousView?.screen != view.screen
        let busyResident = view.residents.contains { !$0.isHidden && Self.activeResidentStates.contains($0.state) }
        let sample = ActivitySample(
            time: input.now.timeIntervalSince1970,
            windowsChanged: windowsChanged,
            residentsChanged: busyResident || previousView != view,
            dragging: state.gesture.isActive || !input.pointer.isEmpty)
        previousView = view
        return pollPolicy.next(after: sample)
    }

    // MARK: - 保存与恢复（任务 16.2）

    /// 当前世界的存档（Requirement 22.3、22.4、22.8）。`now` 默认取最近一次 step 的时钟读数。
    /// 存档尚未恢复（还没有成功轮询过）时返回待恢复的存档本身，避免覆盖。
    public func makeSave(now: Date? = nil) -> SaveFile {
        if let pending = pendingRestore { return pending }
        return SaveSnapshot.snapshot(world: state, now: now ?? lastNow)
    }

    /// 在第一次成功轮询的那一帧把待恢复的存档放回世界（Requirement 22.6 至 22.10、19.6、19.7）。
    ///
    /// V2（任务 10.4）：先按存档放回物件、Decor、居民、剧情和 WishBook（Unlocked_Decor、冷却起点、Flower_Wish
    /// 次数），再按 v1 选家规则重新分配 Home_Window（不移动居民，design.md「已确认决策」），然后恢复 active Wish
    /// （Visit_Target 匹配排除 Home_Window）。恢复时放弃的 Wish 写 `wish_dropped`（v2 Requirement 15.8、18.2）。
    private func applyPendingRestore(poll: WindowPollResult, now: Date) {
        guard let save = pendingRestore, case .success = poll else { return }
        pendingRestore = nil
        demoResidentPending = false
        homesPlaceResidents = false
        restoreLanding = SaveSnapshot.restore(save, into: &state, now: now, constants: constants)
        guard storyEnabled else { return }
        assignHomesIfNeeded(now: now)
        let dropped = SaveSnapshot.restoreWishes(save, into: &state, now: now, constants: constants)
        for s in dropped {
            recordWish(.wishDropped, type: s.type, wisher: s.wisher, visitApp: s.visitTargetApp,
                       state: .dropped, outcome: nil)
        }
        StoryDirector.assignGoals(state.story, world: &state, wishDriven: true)
    }

    // MARK: - 剧情与心愿（v2 任务 7.4）

    /// design.md「每帧更新顺序（V2）」第 9、10 步，在 Nav_Graph 重建之后、Activity_Planner 和居民移动之前调用：
    /// 1. Home_Window 未分配时尝试分配（首次开局放置居民；恢复存档后不移动居民），成功那一帧开始 Wish 调度
    ///    （Requirement 6.1）；
    /// 2. 本帧的「快进」「重置世界」「触发心愿」（需要本帧的路面和通路图）；
    /// 3. `WishDirector.plan`；
    /// 4. `StoryDirector.update(wishDriven: true)`：Story_Stage 只在 Flower_Wish 进行中推进；没有 Flower_Wish 时
    ///    只推进已种下花的生长和心形气泡计时；
    /// 5. 调试寻找覆盖。
    /// 返回本帧的剧情事件（含 Flower_Wish 开始时的 `round_started`），Wish 事件直接写入事件记录。
    private func updateStory(commands: [Command], now: Date, dt: Double) -> [StoryEvent] {
        guard storyEnabled, pendingRestore == nil else { return [] }
        var storyEvents: [StoryEvent] = []
        assignHomesIfNeeded(now: now)
        for command in commands {
            switch command {
            case .fastForward:
                var book = state.wishes
                let events = WishDirector.fastForward(&book, world: &state, constants: constants, now: now)
                state.wishes = book
                storyEvents += events
                recordStoryEvents(events)
            case .resetWorld:
                resetWorld(now: now)
            case let .triggerWish(type, wisher):
                var book = state.wishes
                var world = state
                let events = WishDirector.trigger(
                    type, wisher: wisher, book: &book, world: &world, ctx: wishContext(now: now), rng: &rng)
                world.wishes = book
                state = world
                storyEvents += recordWishEvents(events)
            default:
                break
            }
        }

        var book = state.wishes
        var world = state
        let events = WishDirector.plan(&book, world: &world, ctx: wishContext(now: now), rng: &rng)
        world.wishes = book
        state = world
        storyEvents += recordWishEvents(events)

        var story = state.story
        world = state
        let flowerEvents = StoryDirector.update(
            &story, world: &world, constants: constants, now: now, dt: dt, wishDriven: true)
        world.story = story
        state = world
        storyEvents += flowerEvents
        recordStoryEvents(flowerEvents)
        applySeekOverride()
        return storyEvents
    }

    /// Home_Window 未分配时按 v1 规则分配（v1 R15.1 至 15.4、15.7）。首次开局时放置居民（没有两个合格窗口时
    /// 放在 Ground 上，只放一次）；恢复存档后不移动居民。成功那一帧设置 `nextCheckAt`（Requirement 6.1）。
    private func assignHomesIfNeeded(now: Date) {
        guard state.story.homes.isEmpty else { return }
        var story = state.story
        var world = state
        let ok = StoryDirector.assignHomes(
            &story, world: &world, constants: constants, placeResidents: homesPlaceResidents)
        world.story = story
        state = world
        if ok { WishDirector.startScheduling(&state.wishes, now: now, constants: constants) }
    }

    /// 「重置世界」（v2 Requirement 17.6、1.6、22.7）：v1「重新开始剧情」的清理（删除全部 Flower 和 Fruit，
    /// 保留 Plank 和 Ladder），加上清除全部 Decor、Wish（含 Busy_Resident 身份、冷却起点、Flower_Wish 次数、
    /// 上次 Done 时间）、Unlocked_Decor 和 Activity；居民 Walk_Distance 归零、恢复正常速度和度量，`sitting`、
    /// `sleeping`、`running`、`waiting` 转 `idle`。不写任何 Wish 记录；昼夜覆盖、`events.jsonl` 不变。
    /// 随后同一帧重新分配 Home_Window 并放置居民。结果与当前 Wish_State 和 Story_Stage 无关。
    private func resetWorld(now: Date) {
        var story = state.story
        var world = state
        StoryDirector.clear(&story, world: &world)
        world.story = story
        state = world
        state.decors = DecorStore()
        state.wishes = WishBook()
        state.activities = [:]
        state.toolboxShake = nil
        preferHome = []
        seekOverride = nil
        debugSeekActive = false
        switch state.gesture {
        case .dragging(.decor, _, _), .pressed(.decor, _), .pressed(.toolbox(.decor), _):
            state.gesture = .swallowed
        default:
            break
        }
        for id in sortedResidentIDs {
            guard var r = state.residents[id] else { continue }
            r.walkDistance = 0
            r.speedFactor = 1
            r.routeMetric = .standard
            r.seat = nil
            switch r.state {
            case .waiting:
                ResidentController.leaveWaiting(&r)
                r.state = .idle
            case .sitting, .sleeping, .running:
                r.state = .idle
            default:
                break
            }
            r.route = nil
            r.goal = .none
            state.residents[id] = r
        }
        homesPlaceResidents = true
        assignHomesIfNeeded(now: now)
    }

    /// 第 13 步：`WishDirector.resolve`（居民移动之后，按移动后的位置重建上下文）。Visit_Wish 完成后把 Wisher
    /// 放进 `preferHome`（Requirement 9.8）。
    private func resolveWishes(now: Date) {
        guard storyEnabled, pendingRestore == nil else { return }
        var book = state.wishes
        var world = state
        let events = WishDirector.resolve(&book, world: &world, ctx: wishContext(now: now))
        world.wishes = book
        state = world
        for case let .fulfilled(w, _) in events where w.type == .visit {
            preferHome.insert(w.wisher)
        }
        _ = recordWishEvents(events)
    }

    /// 当前世界的 WishDirector 输入。
    private func wishContext(now: Date) -> WishContext {
        WishContext(world: state, now: now, navVersion: navVersion, constants: constants)
    }

    /// 调试寻找覆盖（见 `seekOverride`）。都都参与非送花 Wish 时结束覆盖，Goal 交给 WishDirector。
    private func applySeekOverride() {
        guard let o = seekOverride else { return }
        let story = state.story
        let inOtherWish = state.wishes.wish(of: .a).map { $0.type != .flower } ?? false
        guard o.stage == story.stage, o.round == story.round, !inOtherWish,
              state.residents[.a] != nil, state.residents[.b] != nil else {
            seekOverride = nil
            return
        }
        let ctx = StoryDirector.context(state, constants)
        if let la = StoryDirector.location(.a, world: state, ctx: ctx),
           let lb = StoryDirector.location(.b, world: state, ctx: ctx),
           la.surface == lb.surface, abs(la.x - lb.x) <= constants.giftReachDistance {
            seekOverride = nil
            if story.stage != nil {
                StoryDirector.assignGoals(story, world: &state, wishDriven: true)
            } else if state.residents[.a]?.goal == .reach(.b) {
                state.residents[.a]?.goal = .hold(face: nil)
            }
            return
        }
        if state.residents[.a]?.goal != .reach(.b) { state.residents[.a]?.goal = .reach(.b) }
    }

    /// 剧情气泡覆盖（项目所有者决定）：Requirement 16.3、16.4 让 `Wish` 在同一帧转为 `Travel` 或 `Waiting`，
    /// 许愿气泡实际看不到，因此 Story_Stage 为 `Waiting` 时 Giver 显示「花盆 + Receiver 头像」许愿气泡，
    /// 代替 `waiting` 的「...」气泡（窗沿上和 Ground 上都如此）。离开 `Wish` 和 `Waiting` 后清除许愿气泡。
    /// 剧情之外的 `waiting`（如调试寻找）仍显示「...」。在居民更新之后调用，因为窗沿等待每帧会写入「...」。
    private func applyStoryBubbles() {
        guard storyEnabled else { return }
        let story = state.story
        let wishing = story.stage == .waiting || story.stage == .wish
        for id in sortedResidentIDs {
            guard var r = state.residents[id] else { continue }
            let wish = Bubble.wish(receiver: story.receiver)
            if wishing && id == story.giver {
                if r.bubble == nil || r.bubble == .dots { r.bubble = wish }
            } else if case .wish = r.bubble {
                r.bubble = nil
            } else {
                continue
            }
            state.residents[id] = r
        }
    }

    private func storyView() -> StoryView? {
        guard storyEnabled else { return nil }
        let s = state.story
        let progress = s.stage == .planting && constants.plantAnimationDuration > 0
            ? min(max(s.plantingElapsed / constants.plantAnimationDuration, 0), 1) : 0
        return StoryView(
            stage: s.stage, round: s.round, giver: s.giver, receiver: s.receiver,
            currentFlower: s.currentFlower, currentFruit: s.currentFruit, plantingProgress: progress)
    }

    // MARK: - 路面

    private func rebuildSurfaces() {
        state.surfaces = SurfaceBuilder.build(
            windows: state.windows.visibleSnapshots, planks: state.planks.placedPlanks, screen: state.screen)
    }

    // MARK: - 显示变化（任务 17.4）

    /// Ground 上宽为 `width` 的对象的合法 x 范围：图形完整位于 Ground 水平范围
    /// （主显示器宽度与 `visibleFrame` 的交集，同 `Physics.clampX`）内。范围比图形窄时取中点。
    public static func groundRange(width: Double, screen: ScreenInfo) -> ClosedRange<Double> {
        let lo = Physics.clampX(-.greatestFiniteMagnitude, screen: screen)
        let hi = Physics.clampX(.greatestFiniteMagnitude, screen: screen)
        let half = max(width, 0) / 2
        if hi - lo < 2 * half {
            let mid = (lo + hi) / 2
            return mid...mid
        }
        return (lo + half)...(hi - half)
    }

    /// 把 Ground 上宽为 `width` 的对象的 x 移到离原 x 最近、图形完整位于新 Ground 内的位置（Requirement 23.8）。
    public static func clampGroundX(_ x: Double, width: Double, screen: ScreenInfo) -> Double {
        let r = groundRange(width: width, screen: screen)
        guard x.isFinite else { return r.lowerBound }
        return min(max(x, r.lowerBound), r.upperBound)
    }

    /// 主显示器信息（分辨率、`visibleFrame`）变化后调用（Requirement 23.5 至 23.8）。
    ///
    /// - 附着在 Ground 上的居民、物件和落下的木板、梯子：x 移到离原 x 最近、图形完整位于新 Ground 内的位置；
    ///   y 由 `groundY` 决定，自动跟随新的 Ground。
    /// - 下落中和悬挂中的对象：x 按 `Physics.clampX` 夹紧，保证仍落在新 Ground 范围内（Requirement 6.7）。
    /// - 附着在窗口上的对象保持原 offset；窗沿随后按新窗口快照重算，落在剩余窗沿外时由
    ///   `resolve*Attachments` 夹紧或下落（Requirement 23.7、4.6、4.7）。
    private func clampToScreen() {
        let screen = state.screen
        func groundAttachment(_ a: Attachment, width: Double) -> Attachment {
            guard case let .ground(x) = a else { return a }
            return .ground(x: Self.clampGroundX(x, width: width, screen: screen))
        }
        func clampFall(_ f: FallState) -> FallState {
            var f = f
            f.position.x = Physics.clampX(f.position.x, screen: screen)
            return f
        }

        for id in sortedResidentIDs {
            guard var r = state.residents[id] else { continue }
            switch r.attachment {
            case .ground:
                r.attachment = groundAttachment(r.attachment, width: SpriteMetrics.resident.width)
                // 原路线的目标 x 可能已在新 Ground 之外；有目标的居民下一帧从当前位置重新规划。
                if r.traversal == nil { r.route = nil }
            case let .free(p):
                r.attachment = .free(Point(x: Physics.clampX(p.x, screen: screen), y: p.y))
            default:
                break
            }
            if let f = r.fall { r.fall = clampFall(f) }
            if let c = r.wander.groundCenter {
                r.wander.groundCenter = Self.clampGroundX(c, width: SpriteMetrics.resident.width, screen: screen)
            }
            state.residents[id] = r
        }
        for iid in state.items.sortedIDs {
            guard var item = state.items[iid] else { continue }
            switch item.placement {
            case let .attached(a):
                item.placement = .attached(groundAttachment(a, width: SpriteMetrics.itemSize(item.kind).width))
            case let .falling(f):
                item.placement = .falling(clampFall(f))
            default:
                continue
            }
            state.items[iid] = item
        }
        // Decor（v2 Requirement 3.9）：与物件相同，按 Decor 图形宽度夹紧。
        for did in state.decors.sortedIDs {
            guard var d = state.decors.decors[did] else { continue }
            switch d.placement {
            case let .attached(a):
                d.placement = .attached(groundAttachment(a, width: SpriteMetrics.decorSize(d.type).width))
            case let .falling(f, byPlayer):
                d.placement = .falling(clampFall(f), byPlayer: byPlayer)
            case .dragged:
                continue
            }
            state.decors.decors[did] = d
        }
        for pid in state.planks.planks.keys.sorted() {
            switch state.planks.planks[pid] {
            case let .loose(a)?:
                state.planks.planks[pid] = .loose(groundAttachment(a, width: SpriteMetrics.loosePlankLength))
            case let .falling(f)?:
                state.planks.planks[pid] = .falling(clampFall(f))
            default:
                break
            }
        }
        for lid in state.ladders.ladders.keys.sorted() {
            switch state.ladders.ladders[lid] {
            case let .loose(a)?:
                state.ladders.ladders[lid] = .loose(groundAttachment(a, width: SpriteMetrics.looseLadderLength))
            case let .falling(f)?:
                state.ladders.ladders[lid] = .falling(clampFall(f))
            default:
                break
            }
        }
    }

    // MARK: - 失效处理

    /// 关闭窗口上的居民和落下的木板：用该窗口最后可见快照和原 offset 算出屏幕位置，从那里开始下落。
    /// 窗口在隐藏状态下被关闭时同样适用（Requirement 5.8）。端点在关闭窗口上的已架设木板由
    /// `validatePlanks` 处理。
    private func dropOnClosed(_ closed: [WindowID: WindowSnapshot]) {
        guard !closed.isEmpty else { return }
        for id in sortedResidentIDs {
            guard var r = state.residents[id],
                  case let .window(wid, offset) = r.attachment,
                  let snap = closed[wid] else { continue }
            let p = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
            ResidentController.startFalling(&r, from: p, screen: state.screen)
            state.residents[id] = r
        }
        for pid in state.planks.planks.keys.sorted() {
            guard case let .loose(.window(wid, offset))? = state.planks.planks[pid],
                  let snap = closed[wid] else { continue }
            let p = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
            state.planks.planks[pid] = .falling(Physics.startFall(at: p, screen: state.screen))
        }
        for lid in state.ladders.ladders.keys.sorted() {
            guard case let .loose(.window(wid, offset))? = state.ladders.ladders[lid],
                  let snap = closed[wid] else { continue }
            let p = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
            state.ladders.ladders[lid] = .falling(Physics.startFall(at: p, screen: state.screen))
        }
        // 窗沿上未被持有的物件（Requirement 5.1、5.8、14.9）。被持有的物件跟随持有者（Requirement 14.10）。
        for iid in state.items.sortedIDs {
            guard var item = state.items[iid], case let .attached(.window(wid, offset)) = item.placement,
                  let snap = closed[wid] else { continue }
            let p = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
            item.placement = .falling(Physics.startFall(at: p, screen: state.screen))
            state.items[iid] = item
        }
        // 窗沿上的 Decor：与物件相同，被动下落（v2 Requirement 3.9）。
        for did in state.decors.sortedIDs {
            guard var d = state.decors.decors[did], case let .attached(.window(wid, offset)) = d.placement,
                  let snap = closed[wid] else { continue }
            let p = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
            d.placement = .falling(Physics.startFall(at: p, screen: state.screen), byPlayer: false)
            state.decors.decors[did] = d
        }
    }

    /// 校验每块已架设木板（Requirement 9.9、9.12）。端点窗口隐藏时 `validity(of:)` 返回 nil，木板保持不变。
    /// 失效的木板从路面中移除，从两端中点竖直下落（Requirement 9.10）；站在它上面的居民从当前位置下落。
    /// 返回失效的木板 ID（按 ID 排序）。
    private func validatePlanks(_ closed: [WindowID: WindowSnapshot]) -> [PlankID] {
        var failed: [PlankID] = []
        for placed in state.planks.placedPlanks {
            guard let v = PlankRules.validity(
                of: placed, windows: state.windows, ledges: state.surfaces, constants: constants),
                !v.isValid else { continue }
            failPlank(placed, closed: closed)
            failed.append(placed.id)
        }
        if !failed.isEmpty { rebuildSurfaces() }
        return failed
    }

    private func failPlank(_ placed: PlacedPlank, closed: [WindowID: WindowSnapshot]) {
        func end(_ e: PlankEnd) -> Point? {
            if let p = e.lastKnownPoint(windows: state.windows) { return p }
            return closed[e.window].map { Point(x: $0.frame.minX + e.offset, y: $0.frame.minY) }
        }
        let a = end(placed.endA), b = end(placed.endB)
        let fallback = Point(x: state.screen.frame.midX, y: state.screen.frame.minY)
        let pa = a ?? b ?? fallback, pb = b ?? a ?? fallback
        let (l, r) = pb.x < pa.x ? (pb, pa) : (pa, pb)

        // 站在木板上的居民：同一帧进入 `hanging`，停在失效那一刻自己所在的屏幕坐标，不跟随木板下落
        // （Requirement 13.1、13.2）；每位居民都从这一帧开始计时（Requirement 13.6）。
        // 窗沿和 Ground 上的居民（含木板端点所在窗沿）不受影响（Requirement 13.7）。
        for id in sortedResidentIDs {
            guard var res = state.residents[id], case let .plank(pid, t) = res.attachment,
                  pid == placed.id, res.state != .falling, res.state != .hanging else { continue }
            let u = min(max(t, 0), 1)
            // 优先用上一帧的木板几何：那是玩家最后看到的位置，窗口一帧内被拖远时居民不会瞬移。
            let (sl, sr) = previousPlankSurfaces[placed.id].map { ($0.start, $0.end) } ?? (l, r)
            let p = Point(x: sl.x + (sr.x - sl.x) * u, y: sl.y + (sr.y - sl.y) * u)
            ResidentController.startHanging(&res, at: p)
            justHung.insert(id)
            state.residents[id] = res
        }

        // 木板上未被持有的物件：从失效那一刻所在的屏幕坐标竖直下落（Requirement 6.2）。
        for iid in state.items.sortedIDs {
            guard var item = state.items[iid], case let .attached(.plank(pid, t)) = item.placement,
                  pid == placed.id else { continue }
            let u = min(max(t, 0), 1)
            let (sl, sr) = previousPlankSurfaces[placed.id].map { ($0.start, $0.end) } ?? (l, r)
            let p = Point(x: sl.x + (sr.x - sl.x) * u, y: sl.y + (sr.y - sl.y) * u)
            item.placement = .falling(Physics.startFall(at: p, screen: state.screen))
            state.items[iid] = item
        }
        // 木板上的 Decor：与物件相同，从失效那一刻所在的屏幕坐标被动下落（v2 Requirement 3.9）。
        for did in state.decors.sortedIDs {
            guard var d = state.decors.decors[did], case let .attached(.plank(pid, t)) = d.placement,
                  pid == placed.id else { continue }
            let u = min(max(t, 0), 1)
            let (sl, sr) = previousPlankSurfaces[placed.id].map { ($0.start, $0.end) } ?? (l, r)
            let p = Point(x: sl.x + (sr.x - sl.x) * u, y: sl.y + (sr.y - sl.y) * u)
            d.placement = .falling(Physics.startFall(at: p, screen: state.screen), byPlayer: false)
            state.decors.decors[did] = d
        }

        // 木板从两端中点下落，按中心 x 落到正下方第一条 Surface（与松手时的红色预览一致）。
        let start = Point(x: (l.x + r.x) / 2, y: min(l.y, r.y) - InteractionController.releaseLift)
        state.planks.planks[placed.id] = .falling(Physics.startFall(at: start, screen: state.screen))
    }

    /// 校验每架已架设梯子（Requirement 10.7、10.8）。上端窗口隐藏时 `validity(of:)` 返回 nil，梯子保持不变
    /// （Requirement 5.2）。有效的梯子按当前上端重新计算下端；失效的梯子下落，梯子上的居民同一帧直接下落
    /// （Requirement 13.5）。返回失效的梯子 ID（按 ID 排序）。
    private func validateLadders(_ closed: [WindowID: WindowSnapshot]) -> [LadderID] {
        var failed: [LadderID] = []
        for placed in state.ladders.placedLadders {
            guard let v = LadderRules.validity(
                of: placed, windows: state.windows, surfaces: state.surfaces, constants: constants)
            else { continue }
            if v.isValid, let refreshed = LadderRules.refreshed(placed, windows: state.windows, surfaces: state.surfaces) {
                if refreshed != placed { state.ladders.ladders[placed.id] = .placed(refreshed) }
                continue
            }
            failLadder(placed, closed: closed)
            failed.append(placed.id)
        }
        return failed
    }

    private func failLadder(_ placed: PlacedLadder, closed: [WindowID: WindowSnapshot]) {
        let top = placed.top.lastKnownPoint(windows: state.windows)
            ?? closed[placed.top.window].map { Point(x: $0.frame.minX + placed.top.offset, y: $0.frame.minY) }
            ?? Point(x: placed.bottom.x, y: placed.bottom.y)
        let length = max(placed.bottom.y - top.y, 0)

        // 梯子上的居民（爬梯中）：同一帧从当前屏幕坐标竖直下落，不经过 `hanging`（Requirement 13.5）。
        // 窗沿和 Ground 上的居民（含梯子两端所在的 Surface）不受影响（Requirement 13.7）。
        for id in sortedResidentIDs {
            guard var res = state.residents[id], case let .ladder(lid, height) = res.attachment,
                  lid == placed.id, res.state != .falling, res.state != .hanging else { continue }
            let p = Point(x: top.x, y: placed.bottom.y - min(max(height, 0), length))
            ResidentController.startFalling(&res, from: p, screen: state.screen)
            state.residents[id] = res
        }

        // 梯子从上下端中点竖直下落，停在正下方第一条 Surface 上（Requirement 10.8）。
        let start = Point(x: top.x, y: (top.y + placed.bottom.y) / 2)
        state.ladders.ladders[placed.id] = .falling(Physics.startFall(at: start, screen: state.screen))
    }

    /// 可见窗口上的居民夹紧到同一窗口的剩余窗沿；没有剩余窗沿时下落。隐藏窗口上的居民不动。
    private func resolveResidentAttachments() {
        for id in sortedResidentIDs {
            guard var r = state.residents[id], case let .window(wid, offset) = r.attachment else { continue }
            if state.windows.isHidden(wid) { continue }
            guard let snap = state.windows.visibleSnapshot(wid) else {
                // 未知窗口（不应发生）：交给不变量检查处理。
                continue
            }
            if let clamped = AttachmentResolver.clamp(offset: offset, window: snap, ledges: state.surfaces) {
                if clamped != offset {
                    r.attachment = .window(wid, offset: clamped)
                    state.residents[id] = r
                }
            } else {
                let p = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
                ResidentController.startFalling(&r, from: p, screen: state.screen)
                state.residents[id] = r
            }
        }
    }

    /// 落在可见窗沿上的木板与物件一样跟随、夹紧，窗口没有剩余窗沿时下落。隐藏窗口上的木板不动。
    private func resolveLoosePlanks() {
        for pid in state.planks.planks.keys.sorted() {
            guard case let .loose(.window(wid, offset))? = state.planks.planks[pid] else { continue }
            if state.windows.isHidden(wid) { continue }
            guard let snap = state.windows.visibleSnapshot(wid) else {
                // 窗口已不在窗口表中（关闭已在 dropOnClosed 中处理）：从屏幕顶部落下兜底。
                let p = Point(x: state.screen.frame.midX, y: state.screen.frame.minY)
                state.planks.planks[pid] = .falling(Physics.startFall(at: p, screen: state.screen))
                continue
            }
            if let clamped = AttachmentResolver.clamp(offset: offset, window: snap, ledges: state.surfaces) {
                if clamped != offset { state.planks.planks[pid] = .loose(.window(wid, offset: clamped)) }
            } else {
                let p = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
                state.planks.planks[pid] = .falling(Physics.startFall(at: p, screen: state.screen))
            }
        }
    }

    /// 落在可见窗沿上的梯子与木板相同：跟随、夹紧，窗口没有剩余窗沿时下落。隐藏窗口上的梯子不动。
    private func resolveLooseLadders() {
        for lid in state.ladders.ladders.keys.sorted() {
            guard case let .loose(.window(wid, offset))? = state.ladders.ladders[lid] else { continue }
            if state.windows.isHidden(wid) { continue }
            guard let snap = state.windows.visibleSnapshot(wid) else {
                let p = Point(x: state.screen.frame.midX, y: state.screen.frame.minY)
                state.ladders.ladders[lid] = .falling(Physics.startFall(at: p, screen: state.screen))
                continue
            }
            if let clamped = AttachmentResolver.clamp(offset: offset, window: snap, ledges: state.surfaces) {
                if clamped != offset { state.ladders.ladders[lid] = .loose(.window(wid, offset: clamped)) }
            } else {
                let p = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
                state.ladders.ladders[lid] = .falling(Physics.startFall(at: p, screen: state.screen))
            }
        }
    }

    // MARK: - 物件附着

    /// 放着的物件（未被持有）的跟随、夹紧与下落（Requirement 4.4、4.6、4.7、5.2 至 5.4、6.2）：
    /// - 可见窗口上：offset 不变即跟随窗口；落在剩余窗沿外时夹紧到最近点；窗口没有剩余窗沿时从当前位置下落；
    /// - 隐藏窗口上、或所在木板任一端窗口隐藏：保持不变；
    /// - 所在木板已不再架设、所在窗口已不在窗口表中（关闭已在 `dropOnClosed` 处理）：下落兜底。
    private func resolveItemAttachments() {
        for iid in state.items.sortedIDs {
            guard var item = state.items[iid], case let .attached(a) = item.placement else { continue }
            switch resolveLoose(a) {
            case .keep:
                continue
            case let .attach(clamped):
                item.placement = .attached(clamped)
            case let .fall(f):
                item.placement = .falling(f)
            }
            state.items[iid] = item
        }
    }

    /// 放着的 Decor 的跟随、夹紧与下落，规则与物件相同（v2 Requirement 3.9）；下落为被动下落。
    private func resolveDecorAttachments() {
        for did in state.decors.sortedIDs {
            guard var d = state.decors.decors[did], case let .attached(a) = d.placement else { continue }
            switch resolveLoose(a) {
            case .keep:
                continue
            case let .attach(clamped):
                d.placement = .attached(clamped)
            case let .fall(f):
                d.placement = .falling(f, byPlayer: false)
            }
            state.decors.decors[did] = d
        }
    }

    /// 放着的物件或 Decor 的附着解析结果。
    private enum LooseResolution {
        /// 保持不变（跟随窗口或木板、位于 Ground、所在窗口或木板端点窗口隐藏）。
        case keep
        /// 夹紧到同一窗口的剩余窗沿。
        case attach(Attachment)
        /// 从给定状态开始下落。
        case fall(FallState)
    }

    /// 物件与 Decor 共用的附着解析（见 `resolveItemAttachments`）。
    private func resolveLoose(_ a: Attachment) -> LooseResolution {
        if isAttachmentHidden(a) { return .keep }
        switch a {
        case let .window(wid, offset):
            guard let snap = state.windows.visibleSnapshot(wid) else { return .fall(fallbackFall()) }
            if let clamped = AttachmentResolver.clamp(offset: offset, window: snap, ledges: state.surfaces) {
                return clamped == offset ? .keep : .attach(.window(wid, offset: clamped))
            }
            let p = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
            return .fall(Physics.startFall(at: p, screen: state.screen))
        case .ground:
            return .keep
        case .plank:
            // 所在木板仍架设且两端可见时有位置，跟随木板；否则木板已失效或移走，从顶部兜底下落。
            return position(of: a) == nil ? .fall(fallbackFall()) : .keep
        case .ladder, .free:
            // 不应附着在梯子上或自由悬空：从当前位置下落。
            return .fall(position(of: a).map { Physics.startFall(at: $0, screen: state.screen) } ?? fallbackFall())
        }
    }

    /// 找不到原位置时的兜底下落起点：屏幕顶边中点。
    private func fallbackFall() -> FallState {
        Physics.startFall(at: Point(x: state.screen.frame.midX, y: state.screen.frame.minY), screen: state.screen)
    }

    /// 点 `p` 位于 Surface `s` 上（竖直容差 `supportTolerance`）。
    private func isOn(_ p: Point, _ s: Surface) -> Bool {
        let eps = 1e-6
        return s.start.x - eps <= p.x && p.x <= s.end.x + eps
            && abs(s.y(atX: p.x) - p.y) <= Self.supportTolerance
    }

    // MARK: - 玩家输入

    /// 当前状态下的交互上下文。
    private func interactionContext() -> InteractionContext {
        InteractionContext(
            screen: state.screen, windows: state.windows, surfaces: state.surfaces, hitRegions: hitRegions(),
            unlockedDecor: state.decors.unlocked, jumpBlocked: jumpBlockedResidents())
    }

    /// 依次处理本帧的鼠标事件。木板架设或下落后立即重算路面，使新 Surface 在本次 step 结束前生效。
    private func handlePointer(_ events: [PointerEvent]) -> [InteractionOutcome] {
        var outcomes: [InteractionOutcome] = []
        for event in events {
            let context = interactionContext()
            var gesture = state.gesture
            var planks = state.planks
            var ladders = state.ladders
            var items = state.items
            var decors = state.decors
            var residents = state.residents
            let result = InteractionController.handle(
                event, gesture: &gesture, context: context,
                planks: &planks, ladders: &ladders, items: &items, decors: &decors,
                residents: &residents, constants: constants)
            state.gesture = gesture
            state.planks = planks
            state.ladders = ladders
            state.items = items
            state.decors = decors
            state.residents = residents
            for case let .decorLimitReached(type) in result {
                // v2 Requirement 2.4：该 Decor_Slot 左右晃动一次。
                state.toolboxShake = ToolboxShake(zone: .decor(type), remaining: constants.toolboxShakeDuration)
            }
            if result.contains(where: \.changesTopology) {
                rebuildSurfaces()
            }
            outcomes += result
        }
        return outcomes
    }

    // MARK: - 通路图

    /// 路面或已架设木板变化时，在居民移动之前重建 Nav_Graph（Requirement 12.1）。
    ///
    /// 路面只含可见窗口的窗沿和两端窗口都可见的木板，因此隐藏窗口的窗沿和端点附着在隐藏窗口上的木板
    /// 都不进入图中（Requirement 5.5）。居民路线的有效性由 ResidentController 每帧对照新图校验
    /// （Requirement 12.9）。
    private func rebuildNavIfNeeded() {
        let present = Set(state.surfaces.compactMap(\.id.plankID))
        let planks = state.planks.placedPlanks.filter { present.contains($0.id) }
        let ladders = state.ladders.navLadders(windows: state.windows, surfaces: state.surfaces)
        if let last = navInputs, last.surfaces == state.surfaces, last.planks == planks, last.ladders == ladders {
            return
        }
        navInputs = (state.surfaces, planks, ladders)
        navVersion += 1
        state.nav = NavGraph.build(surfaces: state.surfaces, planks: planks, ladders: ladders, constants: constants)
    }

    // MARK: - 居民与木板推进

    /// 居民行为与下落推进。附着在 Hidden_Window 上的居民暂停（Requirement 5.3）；
    /// 戳居民的跳跃期间暂停移动，跳跃结束后继续（Requirement 7.6、7.7）。
    /// `falling` 和 `hanging` 不受戳跳跃影响，Hang_Duration 计时照常（Requirement 7.8、13.4）。
    ///
    /// 各居民的位置在本帧开始时统一取样，作为 `Goal.reach` 的追踪目标（Requirement 16.6、20.4）。
    private func updateResidents(dt: Double) {
        var context = WorldContext(
            windows: state.windows, surfaces: state.surfaces, screen: state.screen, constants: constants,
            nav: state.nav, ladders: state.ladders.lookup(windows: state.windows))
        var locations: [ResidentID: ResidentLocation] = [:]
        for id in sortedResidentIDs {
            guard let r = state.residents[id], !isOnHiddenWindow(r) else { continue }
            locations[id] = ResidentController.location(of: r, world: context)
        }
        context.residentLocations = locations
        for id in sortedResidentIDs {
            guard var r = state.residents[id] else { continue }
            if isOnHiddenWindow(r) { continue }
            let jumping = InteractionController.advancePoke(&r, dt: dt)
            let before = r.state
            let beforeX = ResidentController.currentSurface(of: r, world: context)?.position.x
            if justHung.contains(id) {
                // 失效那一帧不累计悬挂时长。
            } else if r.state == .falling, let allowed = restoreLanding.landingSurfaces(for: id, in: state.surfaces) {
                // 存档恢复的下落：只落在目标窗口的窗沿或 Ground 上（Requirement 22.7）。
                var limited = context
                limited.surfaces = allowed
                ResidentController.advanceFall(&r, world: limited, dt: dt)
            } else if !jumping || r.state == .falling || r.state == .hanging {
                ResidentController.update(&r, world: context, dt: dt, rng: &rng)
            }
            // Walk_Distance：`walking` / `running` 帧的水平位移绝对值；下落、悬挂、爬梯的位移不计入（Requirement 4.14）。
            if r.state == .walking || r.state == .running,
               before != .falling, before != .hanging, before != .climbing,
               let x0 = beforeX, let x1 = ResidentController.currentSurface(of: r, world: context)?.position.x {
                r.walkDistance += abs(x1 - x0)
            }
            state.residents[id] = r
            if r.state != .falling { restoreLanding.residents[id] = nil }
        }
    }

    /// 下落中的木板推进一帧。只落在 Window_Ledge 或 Ground 上：落在窗沿上附着该窗口，
    /// 落在 Ground 上成为 Ground_Object（Requirement 9.8）。落下的木板不进入路面计算。
    private func advanceFallingPlanks(dt: Double) {
        let landing = state.surfaces.filter { $0.id.plankID == nil }
        for pid in state.planks.planks.keys.sorted() {
            guard case var .falling(fall)? = state.planks.planks[pid] else {
                restoreLanding.planks.remove(pid)
                continue
            }
            let allowed = restoreLanding.planks.contains(pid) ? landing.filter { $0.id == .ground } : landing
            if let surface = Physics.advance(&fall, dt: dt, surfaces: allowed, gravity: constants.fallGravity),
               let a = AttachmentResolver.attachment(landingOn: surface, atX: fall.position.x, windows: state.windows) {
                state.planks.planks[pid] = .loose(a)
                restoreLanding.planks.remove(pid)
            } else {
                state.planks.planks[pid] = .falling(fall)
            }
        }
    }

    /// 下落中的梯子推进一帧，与木板相同：落在窗沿上附着该窗口，落在 Ground 上成为 Ground_Object
    /// （Requirement 10.6、10.8）。落下的梯子不进入 Nav_Graph。
    private func advanceFallingLadders(dt: Double) {
        let landing = state.surfaces.filter { $0.id.plankID == nil }
        for lid in state.ladders.ladders.keys.sorted() {
            guard case var .falling(fall)? = state.ladders.ladders[lid] else {
                restoreLanding.ladders.remove(lid)
                continue
            }
            let allowed = restoreLanding.ladders.contains(lid) ? landing.filter { $0.id == .ground } : landing
            if let surface = Physics.advance(&fall, dt: dt, surfaces: allowed, gravity: constants.fallGravity),
               let a = AttachmentResolver.attachment(landingOn: surface, atX: fall.position.x, windows: state.windows) {
                state.ladders.ladders[lid] = .loose(a)
                restoreLanding.ladders.remove(lid)
            } else {
                state.ladders.ladders[lid] = .falling(fall)
            }
        }
    }

    // MARK: - 物件

    /// 让持有关系与居民一致（`Resident.heldItem` 为准）。标记为被持有、但持有者已不存在或不指向它的物件
    /// 取不到持有者位置，从屏幕顶部中点开始下落兜底（不应发生）。
    private func reconcileItems() {
        var residents = state.residents
        let screen = state.screen
        state.items.reconcile(residents: &residents) { _ in
            Physics.startFall(at: Point(x: screen.frame.midX, y: screen.frame.minY), screen: screen)
        }
        state.residents = residents
    }

    /// 下落中的物件推进一帧：落点是起点下方水平范围包含其 x 的最高一条 Surface（含已架设木板，Requirement 6.5）；
    /// 落在 Window_Ledge 上附着该窗口，落在 Ground 上成为 Ground_Object，落在木板上附着该木板
    /// （Requirement 4.2、4.3、6.6）。被持有的物件不单独下落（Requirement 14.5）。
    private func advanceFallingItems(dt: Double) {
        let landing = state.surfaces
        for iid in state.items.sortedIDs {
            guard var item = state.items[iid], case var .falling(fall) = item.placement else {
                restoreLanding.items.remove(iid)
                continue
            }
            let allowed = restoreLanding.items.contains(iid) ? landing.filter { $0.id == .ground } : landing
            if let surface = Physics.advance(&fall, dt: dt, surfaces: allowed, gravity: constants.fallGravity),
               let a = AttachmentResolver.attachment(landingOn: surface, atX: fall.position.x, windows: state.windows) {
                item.placement = .attached(a)
                restoreLanding.items.remove(iid)
            } else {
                item.placement = .falling(fall)
            }
            state.items[iid] = item
        }
    }

    /// 下落中的 Decor 推进一帧，落点规则与物件相同（含已架设木板）。落地时更新 `placedSeq`。
    /// 玩家松手下落（`byPlayer`）落地时写 `decor_placed`；被动下落落地不写记录（v2 Requirement 3.10、18.4）。
    /// 存档恢复的 Decor 只落在 Ground 上（v2 Requirement 15.2）。
    private func advanceFallingDecors(dt: Double) {
        let landing = state.surfaces
        // 已被移除（收回 Toolbox、重置世界）的 Decor 不再受恢复落点限制，避免 ID 复用后误用。
        restoreLanding.decors.formIntersection(state.decors.decors.keys)
        for did in state.decors.sortedIDs {
            guard var d = state.decors.decors[did], case .falling(var fall, let byPlayer) = d.placement else {
                restoreLanding.decors.remove(did)
                continue
            }
            let allowed = restoreLanding.decors.contains(did) ? landing.filter { $0.id == .ground } : landing
            if let surface = Physics.advance(&fall, dt: dt, surfaces: allowed, gravity: constants.fallGravity),
               let a = AttachmentResolver.attachment(landingOn: surface, atX: fall.position.x, windows: state.windows) {
                d.placement = .attached(a)
                state.decors.decors[did] = d
                state.decors.markPlaced(did)
                restoreLanding.decors.remove(did)
                if byPlayer { recordDecorPlaced(did, type: d.type, surface: SurfaceKindTag(surface.id)) }
            } else {
                d.placement = .falling(fall, byPlayer: byPlayer)
                state.decors.decors[did] = d
            }
        }
    }

    /// Toolbox 晃动的剩余时间按 dt 减少，减到 0 时清除（v2 Requirement 2.4）。
    private func advanceToolboxShake(dt: Double) {
        guard var shake = state.toolboxShake else { return }
        shake.remaining -= dt
        state.toolboxShake = shake.remaining > 0 ? shake : nil
    }

    /// Decor 的渲染信息，按 `DecorID` 排序。附着在 Hidden_Window（或端点窗口隐藏的木板）上的 Decor 不绘制。
    private func decorViews() -> [DecorView] {
        state.decors.sortedIDs.compactMap { did -> DecorView? in
            guard let d = state.decors.decors[did] else { return nil }
            switch d.placement {
            case let .attached(a):
                if isAttachmentHidden(a) { return nil }
                guard let p = position(of: a) else { return nil }
                return DecorView(id: did, type: d.type, position: p)
            case let .falling(f, _):
                return DecorView(id: did, type: d.type, position: f.position, isFalling: true)
            case .dragged:
                // 拖动中：位于指针减去抓取偏移处（v2 Requirement 3.1）。
                guard let p = InteractionController.draggedDecorPosition(did, gesture: state.gesture) else { return nil }
                return DecorView(id: did, type: d.type, position: p, isDragged: true)
            }
        }
    }

    /// 物件的渲染信息，按 `ItemID` 排序。被持有的物件位于持有者绘制位置加固定偏移，覆盖行走、小跳、往下跳、
    /// 爬梯、悬挂和下落全过程（Requirement 14.4）；持有者隐藏时不绘制。
    private func itemViews(residents: [ResidentView]) -> [ItemView] {
        let byID = Dictionary(residents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return state.items.sortedIDs.compactMap { iid -> ItemView? in
            guard let item = state.items[iid] else { return nil }
            switch item.placement {
            case let .held(rid):
                guard let rv = byID[rid], !rv.isHidden, let p = rv.position else { return nil }
                return ItemView(id: iid, kind: item.kind, stage: item.stage,
                                position: ItemHolding.heldPosition(residentPosition: p), holder: rid,
                                jumpLift: rv.jumpLift)
            case let .attached(a):
                if case let .window(wid, _) = a, state.windows.isHidden(wid) { return nil }
                guard let p = position(of: a) else { return nil }
                return ItemView(id: iid, kind: item.kind, stage: item.stage, position: p)
            case let .falling(f):
                return ItemView(id: iid, kind: item.kind, stage: item.stage, position: f.position, isFalling: true)
            case .dragged:
                // 拖动中：位于指针减去抓取偏移处（Requirement 11.2）。
                guard let p = InteractionController.draggedItemPosition(iid, gesture: state.gesture) else { return nil }
                return ItemView(id: iid, kind: item.kind, stage: item.stage, position: p, isDragged: true)
            }
        }
    }

    /// 把违反无悬空不变量的居民设为下落（Requirement 29.6）。
    private func enforceSupport() {
        for id in sortedResidentIDs {
            guard var r = state.residents[id], !isSupported(r) else { continue }
            let p = position(of: r.attachment)
                ?? Point(x: state.screen.frame.midX, y: state.screen.frame.minY)
            ResidentController.startFalling(&r, from: p, screen: state.screen)
            state.residents[id] = r
        }
        for iid in state.items.sortedIDs {
            guard var item = state.items[iid], !isSupported(item) else { continue }
            let p: Point? = if case let .attached(a) = item.placement { position(of: a) } else { nil }
            item.placement = .falling(p.map { Physics.startFall(at: $0, screen: state.screen) } ?? fallbackFall())
            state.items[iid] = item
        }
        for did in state.decors.sortedIDs {
            guard var d = state.decors.decors[did], !isSupported(d) else { continue }
            let p: Point? = if case let .attached(a) = d.placement { position(of: a) } else { nil }
            d.placement = .falling(
                p.map { Physics.startFall(at: $0, screen: state.screen) } ?? fallbackFall(), byPlayer: false)
            state.decors.decors[did] = d
        }
    }

    // MARK: - 无悬空不变量

    /// 检查无悬空不变量（Requirement 29.5），返回违规描述；为空表示满足。测试用。
    /// 覆盖居民和物件。
    public func invariantViolations() -> [String] {
        let residents = sortedResidentIDs.compactMap { id -> String? in
            guard let r = state.residents[id], !isSupported(r) else { return nil }
            return "\(id.rawValue): unsupported in state \(r.state.rawValue) with attachment \(r.attachment)"
        }
        let items = state.items.sortedIDs.compactMap { iid -> String? in
            guard let item = state.items[iid], !isSupported(item) else { return nil }
            return "item \(iid.rawValue.uuidString): unsupported with placement \(item.placement)"
        }
        let decors = state.decors.sortedIDs.compactMap { did -> String? in
            guard let d = state.decors.decors[did], !isSupported(d) else { return nil }
            return "decor \(did.rawValue): unsupported with placement \(d.placement)"
        }
        return residents + items + decors + state.items.holdingViolations(residents: state.residents)
    }

    /// Decor 是否满足无悬空不变量（v2 Requirement 3.12）：拖动中、下落中豁免；附着在 Hidden_Window
    /// （或端点窗口隐藏的木板）上豁免；否则底边与某条 Surface 的竖直距离不超过 1pt 且 x 落在该 Surface 范围内。
    private func isSupported(_ d: Decor) -> Bool {
        switch d.placement {
        case .falling, .dragged:
            return true
        case let .attached(a):
            if isAttachmentHidden(a) { return true }
            guard let p = position(of: a) else { return false }
            return state.surfaces.contains { isOn(p, $0) }
        }
    }

    /// 物件是否满足无悬空不变量：下落中、被持有（Requirement 29.5 (c)）或被玩家拖动中豁免；
    /// 附着在 Hidden_Window（或端点窗口隐藏的木板）上豁免（(d)）；否则底边与某条 Surface 的竖直距离
    /// 不超过 1pt 且 x 落在该 Surface 范围内（(a)）。
    private func isSupported(_ item: Item) -> Bool {
        switch item.placement {
        case .falling, .held, .dragged:
            return true
        case let .attached(a):
            if isAttachmentHidden(a) { return true }
            guard let p = position(of: a) else { return false }
            return state.surfaces.contains { isOn(p, $0) }
        }
    }

    /// 居民是否满足无悬空不变量：`falling` / `hanging` 豁免；附着在 Hidden_Window 上（含端点窗口隐藏的木板、
    /// 上端窗口隐藏的梯子）豁免；`climbing` 且位于已架设 Ladder 上豁免（Requirement 29.5 (b)）；
    /// 否则底边与某条 Surface（含已架设木板）的竖直距离不超过 1pt 且 x 落在该 Surface 范围内。
    private func isSupported(_ r: Resident) -> Bool {
        if r.state == .falling || r.state == .hanging { return true }
        if isOnHiddenWindow(r) { return true }
        if r.state == .climbing, case let .ladder(lid, _) = r.attachment,
           state.ladders.ladders[lid]?.placed != nil { return true }
        guard let p = position(of: r.attachment) else { return false }
        let eps = 1e-6
        return state.surfaces.contains { s in
            s.start.x - eps <= p.x && p.x <= s.end.x + eps
                && abs(s.y(atX: p.x) - p.y) <= Self.supportTolerance
        }
    }

    /// 附着的窗口是 Hidden_Window；站在木板上时，木板任一端窗口是 Hidden_Window。
    func isOnHiddenWindow(_ r: Resident) -> Bool {
        isAttachmentHidden(r.attachment)
    }

    /// Attachment 指向 Hidden_Window：窗口隐藏；木板任一端窗口隐藏；梯子上端窗口隐藏。
    func isAttachmentHidden(_ a: Attachment) -> Bool {
        switch a {
        case let .window(wid, _):
            return state.windows.isHidden(wid)
        case let .plank(pid, _):
            guard let p = state.planks.planks[pid]?.placed else { return false }
            return state.windows.isHidden(p.endA.window) || state.windows.isHidden(p.endB.window)
        case let .ladder(lid, _):
            guard let l = state.ladders.ladders[lid]?.placed else { return false }
            return state.windows.isHidden(l.top.window)
        default:
            return false
        }
    }

    /// Attachment 的当前屏幕坐标（含木板和梯子）。
    func position(of a: Attachment) -> Point? {
        AttachmentResolver.screenPosition(
            a, windows: state.windows, planks: state.planks.lookup(windows: state.windows),
            ladders: state.ladders.lookup(windows: state.windows), screen: state.screen)
    }

    var sortedResidentIDs: [ResidentID] {
        state.residents.keys.sorted()
    }

    // MARK: - 临时演示居民

    /// 临时演示居民：Resident_A 放在首个可见窗沿中点；Resident_B 放在另一个窗口上、水平中点离 A 最远的窗沿中点。
    /// 没有窗沿时 A 放在 Ground 中点；没有其他窗口的窗沿时 B 放在 Ground 上离 A 较远的四分之一处。只放一次。
    private func placeDemoResidentIfNeeded() {
        guard demoResidentPending else { return }
        demoResidentPending = false
        guard let ground = state.surfaces.first(where: { $0.id == .ground }) else { return }
        let ledges = state.surfaces.filter { s in
            s.id.isLedge && s.id.windowID.map { state.windows.visibleSnapshot($0) != nil } == true
        }
        func onLedge(_ ledge: Surface) -> Attachment? {
            guard let wid = ledge.id.windowID, let snap = state.windows.visibleSnapshot(wid) else { return nil }
            return .window(wid, offset: (ledge.start.x + ledge.end.x) / 2 - snap.frame.minX)
        }
        let groundMid = (ground.start.x + ground.end.x) / 2

        var aX = groundMid
        var aWindow: WindowID?
        if state.residents[.a] == nil {
            if let ledge = ledges.first, let att = onLedge(ledge) {
                state.residents[.a] = Resident(id: .a, attachment: att)
                aX = (ledge.start.x + ledge.end.x) / 2
                aWindow = ledge.id.windowID
            } else {
                state.residents[.a] = Resident(id: .a, attachment: .ground(x: groundMid))
            }
        } else if let a = state.residents[.a], let p = position(of: a.attachment) {
            aX = p.x
            if case let .window(wid, _) = a.attachment { aWindow = wid }
        }

        guard state.residents[.b] == nil else { return }
        let far = ledges
            .filter { $0.id.windowID != aWindow }
            .max { abs(($0.start.x + $0.end.x) / 2 - aX) < abs(($1.start.x + $1.end.x) / 2 - aX) }
        if let ledge = far, let att = onLedge(ledge) {
            state.residents[.b] = Resident(id: .b, attachment: att, facing: .left)
        } else {
            let quarter = (ground.end.x - ground.start.x) / 4
            let x = aX < groundMid ? ground.end.x - quarter : ground.start.x + quarter
            state.residents[.b] = Resident(id: .b, attachment: .ground(x: x), facing: .left)
        }
    }

    // MARK: - 视图

    /// 可见居民的渲染信息，按 `ResidentID` 排序。
    private func residentViews() -> [ResidentView] {
        sortedResidentIDs.compactMap { id -> ResidentView? in
            guard let r = state.residents[id] else { return nil }
            let hidden = isOnHiddenWindow(r)
            let pos: Point?
            if hidden {
                pos = nil
            } else if case .ladder = r.attachment {
                // 爬梯：位置跟随梯子当前几何。
                pos = position(of: r.attachment) ?? r.traversal.map(ResidentController.traversalPoint)
            } else {
                pos = r.traversal.map(ResidentController.traversalPoint) ?? position(of: r.attachment)
            }
            return ResidentView(
                id: r.id, state: r.state, position: pos,
                facing: r.facing, isHidden: hidden, heldItem: r.heldItem, bubble: r.bubble, poke: r.poke,
                jumpLift: InteractionController.jumpLift(r.poke, constants: constants),
                thought: hidden ? nil : r.thought?.text, seatLift: SpriteMetrics.residentSeatLift(r.state))
        }
    }

    /// 可见木板的渲染信息，按 `PlankID` 排序。端点窗口隐藏的已架设木板、隐藏窗口上的落下木板和拖动中的木板不在此列。
    private func plankViews() -> [PlankView] {
        state.planks.planks.keys.sorted().compactMap { pid -> PlankView? in
            switch state.planks.planks[pid] {
            case let .placed(p)?:
                guard let (l, r) = p.endpoints(windows: state.windows) else { return nil }
                return PlankView(id: pid, shape: .placed(left: l, right: r))
            case let .loose(a)?:
                guard let p = position(of: a) else { return nil }
                return PlankView(id: pid, shape: .loose(bottomCenter: p))
            case let .falling(f)?:
                return PlankView(id: pid, shape: .loose(bottomCenter: f.position), isFalling: true)
            case .dragged?, nil:
                return nil
            }
        }
    }

    /// 可见梯子的渲染信息，按 `LadderID` 排序。上端窗口隐藏的已架设梯子、隐藏窗口上的落下梯子和拖动中的梯子不在此列。
    private func ladderViews() -> [LadderView] {
        state.ladders.ladders.keys.sorted().compactMap { lid -> LadderView? in
            switch state.ladders.ladders[lid] {
            case let .placed(l)?:
                guard let t = l.topPoint(windows: state.windows) else { return nil }
                return LadderView(id: lid, shape: .placed(top: t, bottom: Point(x: t.x, y: l.bottom.y)))
            case let .loose(a)?:
                guard let p = position(of: a) else { return nil }
                return LadderView(id: lid, shape: .loose(bottomCenter: p))
            case let .falling(f)?:
                return LadderView(id: lid, shape: .loose(bottomCenter: f.position), isFalling: true)
            case .dragged?, nil:
                return nil
            }
        }
    }

    /// 当前帧的命中区域：可见居民（含跳跃偏移）、放着的与下落中的物件、可见的 Decor、可见木板与梯子、
    /// Toolbox 各取物区（Requirement 7.1，v2 Requirement 3.7）。
    private func hitRegions() -> [HitRegion] {
        let residents = residentViews()
        return hitRegions(residents: residents, planks: plankViews(), ladders: ladderViews(),
                          items: itemViews(residents: residents), decors: decorViews())
    }

    private func hitRegions(
        residents: [ResidentView], planks: [PlankView], ladders: [LadderView], items: [ItemView],
        decors: [DecorView]
    ) -> [HitRegion] {
        var regions: [HitRegion] = []
        for r in residents {
            guard !r.isHidden, let p = r.position else { continue }
            regions.append(HitRegion(
                target: .resident(r.id),
                rect: SpriteMetrics.residentRect(
                    bottomCenter: p, lift: r.jumpLift + SpriteMetrics.residentSeatLift(r.state))))
        }
        // 被持有的物件不单独可点（Requirement 11.8），拖动中的物件由手势持有。
        for iv in items where iv.holder == nil && !iv.isDragged {
            regions.append(HitRegion(
                target: .item(iv.id), rect: SpriteMetrics.itemRect(kind: iv.kind, bottomCenter: iv.position)))
        }
        // 拖动中的 Decor 由手势持有；隐藏窗口上的 Decor 不在 `decors` 中。
        for dv in decors where !dv.isDragged {
            regions.append(HitRegion(
                target: .decor(dv.id), rect: SpriteMetrics.decorRect(type: dv.type, bottomCenter: dv.position)))
        }
        for pv in planks {
            let rect: Rect
            switch pv.shape {
            case let .placed(l, r): rect = SpriteMetrics.placedPlankRect(from: l, to: r)
            case let .loose(c): rect = SpriteMetrics.loosePlankRect(bottomCenter: c)
            }
            regions.append(HitRegion(target: .plank(pv.id), rect: rect))
        }
        for lv in ladders {
            let rect: Rect
            switch lv.shape {
            case let .placed(t, b): rect = SpriteMetrics.placedLadderRect(top: t, bottom: b)
            case let .loose(c): rect = SpriteMetrics.looseLadderRect(bottomCenter: c)
            }
            regions.append(HitRegion(target: .ladder(lv.id), rect: rect))
        }
        let unlocked = state.decors.unlocked
        for zone in ToolboxLayout.zones(unlocked: unlocked) {
            guard let rect = ToolboxLayout.zoneFrame(zone, screen: state.screen, unlocked: unlocked) else { continue }
            regions.append(HitRegion(target: .toolbox(zone), rect: rect))
        }
        return regions
    }

    /// 当前状态的只读快照。
    public func makeView() -> WorldView {
        let residents = residentViews()
        let planks = plankViews()
        let ladders = ladderViews()
        let items = itemViews(residents: residents)
        let decors = decorViews()
        let regions = hitRegions(residents: residents, planks: planks, ladders: ladders, items: items,
                                 decors: decors)
        let context = InteractionContext(
            screen: state.screen, windows: state.windows, surfaces: state.surfaces, hitRegions: regions,
            unlockedDecor: state.decors.unlocked)
        return WorldView(
            screen: state.screen, surfaces: state.surfaces, showSurfaces: state.showSurfaces,
            residents: residents, planks: planks, ladders: ladders,
            preview: InteractionController.preview(gesture: state.gesture, context: context, constants: constants),
            hitRegions: regions, isInteracting: state.gesture.isActive, items: items, story: storyView(),
            decors: decors, unlockedDecor: state.decors.unlocked, toolboxShake: state.toolboxShake,
            visitFlags: visitFlags(), isNight: state.isNight)
    }

    private func apply(_ command: Command) {
        switch command {
        case .toggleSurfaces:
            state.showSurfaces.toggle()
        case .debugSeek:
            guard var a = state.residents[.a], state.residents[.b] != nil else { return }
            a.goal = .reach(.b)
            state.residents[.a] = a
            if storyEnabled {
                seekOverride = (state.story.stage, state.story.round)
            } else {
                debugSeekActive = true
            }
        case let .setDayNight(o):
            state.dayNightOverride = o
        case .unlockAllDecor:
            // 按 chair、lamp 顺序解锁；已解锁的不重复写记录（v2 Requirement 17.5、1.4）。
            for t in DecorType.allCases {
                if state.decors.unlock(t) { recordDecorUnlocked(t) }
            }
        case .fastForward, .resetWorld, .triggerWish:
            // 在 `updateStory` 中处理（需要本帧的路面和通路图）。
            break
        case .debugGiveFlower:
            // `give` 在都都不存在或已持有 Item 时不改变任何状态，也不新建 Flower。
            guard let a = state.residents[.a], a.heldItem == nil else { return }
            give(Item.flowerPot(placement: .held(.a)), to: .a)
        }
    }
}

// MARK: - 事件记录（任务 14.3，Requirement 21.1 至 21.8）

/// 一次 step 中收集事件记录的缓冲。时间统一取本帧的 `now`（EventRecord 截断到秒）。
struct EventLogBuilder {
    let now: Date
    /// 本帧关闭的窗口（最后可见快照），用于取所属应用名称。
    var closed: [WindowID: WindowSnapshot] = [:]
    private(set) var records: [EventRecord] = []

    init(now: Date) {
        self.now = now
    }

    mutating func add(_ type: EventType, actor: String? = nil, target: String? = nil, detail: [String: String] = [:]) {
        records.append(EventRecord(time: now, type: type, actor: actor, target: target, detail: detail))
    }
}

/// 事件记录中的对象标识。窗口只写所属应用名称（`app:<ownerName>`），从不写标题（Requirement 21.8）。
enum EventRef {
    static func plank(_ id: PlankID) -> String { "plank:\(id.rawValue)" }
    static func ladder(_ id: LadderID) -> String { "ladder:\(id.rawValue)" }
    static func flower(_ id: ItemID) -> String { "flower:\(id.rawValue.uuidString)" }
    static func fruit(_ id: ItemID) -> String { "fruit:\(id.rawValue.uuidString)" }
    static func decor(_ id: DecorID) -> String { "decor:\(id.rawValue)" }
    static let ground = "ground"
}

extension WorldEngine {
    /// 窗口所属应用的标识；窗口已不在窗口表中时用本帧关闭窗口的最后可见快照。
    private func appRef(_ wid: WindowID) -> String? {
        let name = state.windows.records[wid]?.snapshot.ownerName ?? eventLog.closed[wid]?.ownerName
        return name.map(EventRecord.appRef)
    }

    /// Surface 的标识：窗沿为所属应用，Ground 为 `ground`，木板为 `plank:<id>`。
    private func surfaceRef(_ id: SurfaceID) -> String? {
        switch id {
        case .ground: return EventRef.ground
        case let .ledge(wid, _): return appRef(wid)
        case let .plank(pid): return EventRef.plank(pid)
        }
    }

    /// 居民所站位置的标识；下落、悬挂中（`free`）为 nil。
    private func attachmentRef(_ a: Attachment) -> String? {
        switch a {
        case let .window(wid, _): return appRef(wid)
        case .ground: return EventRef.ground
        case let .plank(pid, _): return EventRef.plank(pid)
        case let .ladder(lid, _): return EventRef.ladder(lid)
        case .free: return nil
        }
    }

    /// 只更新比较基准，不产生事件。
    private func rebaselineResidents() {
        residentBaseline = state.residents
    }

    /// 与比较基准对照，产生居民相关事件，然后更新基准：
    /// - `fell`：进入 `falling`（含悬挂结束后下落）；
    /// - `landed`：离开 `falling` 落到 Surface 上；
    /// - `waiting_started`：进入 `waiting`，`target` 为要找的居民；
    /// - `crossed_bridge`：从木板走到与上木板时不同的窗口；
    /// - `climbed_ladder`：爬完梯子，离开梯子到另一条 Surface。
    private func noteResidentTransitions() {
        for id in sortedResidentIDs {
            guard let now = state.residents[id] else { continue }
            let actor = EventRecord.residentRef(id)
            guard let before = residentBaseline[id] else { continue }

            if now.state == .falling, before.state != .falling {
                eventLog.add(.fell, actor: actor, target: attachmentRef(before.attachment),
                             detail: ["from_state": before.state.rawValue])
            }
            if before.state == .falling, now.state != .falling, now.state != .hanging {
                eventLog.add(.landed, actor: actor, target: attachmentRef(now.attachment))
            }
            if now.state == .waiting, before.state != .waiting {
                var target: String?
                if case let .reach(other) = now.goal { target = EventRecord.residentRef(other) }
                var detail: [String: String] = [:]
                if let on = attachmentRef(now.attachment) { detail["on"] = on }
                eventLog.add(.waitingStarted, actor: actor, target: target, detail: detail)
            }
            notePlankCrossing(id, before: before, now: now, actor: actor)
            noteLadderClimb(id, before: before, now: now, actor: actor)
        }
        residentBaseline = state.residents
    }

    private func notePlankCrossing(_ id: ResidentID, before: Resident, now: Resident, actor: String) {
        let beforePlank: PlankID? = if case let .plank(p, _) = before.attachment { p } else { nil }
        let nowPlank: PlankID? = if case let .plank(p, _) = now.attachment { p } else { nil }
        if let p = nowPlank, p != beforePlank {
            let from: WindowID? = if case let .window(w, _) = before.attachment { w } else { nil }
            plankEntry[id] = (p, from)
        }
        guard let p = beforePlank, nowPlank == nil else { return }
        let entry = plankEntry.removeValue(forKey: id)
        // 只在走下木板、站到某个窗沿上时算过桥；悬挂、下落不算，回到上木板时的同一窗口也不算。
        guard now.state != .falling, now.state != .hanging,
              case let .window(to, _) = now.attachment else { return }
        let from = entry?.plank == p ? entry?.window : nil
        guard from != to else { return }
        var detail: [String: String] = [:]
        if let f = from.flatMap(appRef) { detail["from"] = f }
        if let t = appRef(to) { detail["to"] = t }
        eventLog.add(.crossedBridge, actor: actor, target: EventRef.plank(p), detail: detail)
    }

    private func noteLadderClimb(_ id: ResidentID, before: Resident, now: Resident, actor: String) {
        let beforeLadder: LadderID? = if case let .ladder(l, _) = before.attachment { l } else { nil }
        let nowLadder: LadderID? = if case let .ladder(l, _) = now.attachment { l } else { nil }
        if let l = nowLadder, l != beforeLadder {
            ladderEntry[id] = (l, attachmentRef(before.attachment))
        }
        guard let l = beforeLadder, nowLadder == nil else { return }
        let entry = ladderEntry.removeValue(forKey: id)
        guard now.state != .falling, now.state != .hanging, let to = attachmentRef(now.attachment) else { return }
        var detail: [String: String] = ["to": to]
        if entry?.ladder == l, let from = entry?.from { detail["from"] = from }
        if let top = state.ladders.ladders[l]?.placed?.top.window {
            let up: Bool = if case let .window(w, _) = now.attachment { w == top } else { false }
            detail["direction"] = up ? "up" : "down"
        }
        eventLog.add(.climbedLadder, actor: actor, target: EventRef.ladder(l), detail: detail)
    }

    // MARK: 木板、梯子与剧情事件

    private func plankDetail(_ placed: PlacedPlank?) -> [String: String] {
        guard let placed else { return [:] }
        var d: [String: String] = [:]
        if let a = appRef(placed.endA.window) { d["from"] = a }
        if let b = appRef(placed.endB.window) { d["to"] = b }
        return d
    }

    private func ladderDetail(_ placed: PlacedLadder?) -> [String: String] {
        guard let placed else { return [:] }
        var d: [String: String] = [:]
        if let t = appRef(placed.top.window) { d["top"] = t }
        if let b = surfaceRef(placed.bottomSurface) { d["bottom"] = b }
        return d
    }

    /// `plank_dropped`：玩家红色预览松手（`actor` 为玩家，`cause` 为 `released`）和已架设木板失效
    /// （没有发起方，`cause` 为 `collapsed`）都记录（design.md「事件和触发点的对应」）。
    private func recordPlankDropped(_ id: PlankID, placed: PlacedPlank?, actor: String?, cause: String) {
        var d = plankDetail(placed)
        d["cause"] = cause
        eventLog.add(.plankDropped, actor: actor, target: EventRef.plank(id), detail: d)
    }

    /// `ladder_dropped`：规则同 `plank_dropped`。
    private func recordLadderDropped(_ id: LadderID, placed: PlacedLadder?, actor: String?, cause: String) {
        var d = ladderDetail(placed)
        d["cause"] = cause
        eventLog.add(.ladderDropped, actor: actor, target: EventRef.ladder(id), detail: d)
    }

    /// 玩家输入产生的事件：木板、梯子的架设和松手下落。戳居民、拖动和物件放置不在 Requirement 21.1 的列表中。
    private func recordInteractions(_ outcomes: [InteractionOutcome]) {
        let player = EventRecord.playerActor
        for o in outcomes {
            switch o {
            case let .plankPlaced(pid):
                eventLog.add(.plankPlaced, actor: player, target: EventRef.plank(pid),
                             detail: plankDetail(state.planks.planks[pid]?.placed))
            case let .plankDropped(pid):
                recordPlankDropped(pid, placed: nil, actor: player, cause: "released")
            case let .ladderPlaced(lid):
                eventLog.add(.ladderPlaced, actor: player, target: EventRef.ladder(lid),
                             detail: ladderDetail(state.ladders.ladders[lid]?.placed))
            case let .ladderDropped(lid):
                recordLadderDropped(lid, placed: nil, actor: player, cause: "released")
            case let .decorPlaced(did, type, surface):
                recordDecorPlaced(did, type: type, surface: surface)
            case let .decorRemoved(did, type):
                eventLog.add(.decorRemoved, actor: player, target: EventRef.decor(did),
                             detail: ["decor_type": type.rawValue])
            case .poked, .dragStarted, .itemAttached, .itemDropped,
                 .decorLimitReached, .decorDropped, .decorDiscarded:
                // 玩家松手下落的 Decor 在落地时写 `decor_placed`（`advanceFallingDecors`）；
                // 新建后放回 Toolbox 的 Decor 不写事件（v2 Requirement 3.5）。
                break
            }
        }
    }

    /// `decor_placed`：玩家松手附着，或玩家松手下落后落地（v2 Requirement 3.10、18.4）。
    private func recordDecorPlaced(_ id: DecorID, type: DecorType, surface: SurfaceKindTag) {
        eventLog.add(.decorPlaced, actor: EventRecord.playerActor, target: EventRef.decor(id),
                     detail: ["decor_type": type.rawValue, "surface": surface.rawValue])
    }

    /// `decor_unlocked`：`actor`、`target` 为 null，`detail` 含 `decor_type`（v2 Requirement 1.4、18.4）。
    func recordDecorUnlocked(_ type: DecorType) {
        eventLog.add(.decorUnlocked, detail: ["decor_type": type.rawValue])
    }

    /// WishDirector 事件按发生顺序写入事件记录（v2 design.md「EventType 扩充」表格，Requirement 18.2）：
    /// WishDirector 已保证 `wish_started` 在由它引起的 `decor_unlocked` 和剧情事件之前，`sat`、`slept`、
    /// Visit_Wish 的 `visited` 在对应的 `wish_fulfilled` 之前。返回其中的剧情事件（Flower_Wish 开始时的
    /// `round_started` 等），供 `StepOutput.storyEvents` 使用。
    @discardableResult
    func recordWishEvents(_ events: [WishEvent]) -> [StoryEvent] {
        var story: [StoryEvent] = []
        for e in events {
            switch e {
            case let .started(w):
                recordWish(.wishStarted, w, state: .active, outcome: nil)
            case let .fulfilled(w, outcome):
                recordWish(.wishFulfilled, w, state: .fulfilled, outcome: outcome)
            case let .dropped(w):
                recordWish(.wishDropped, w, state: .dropped, outcome: nil)
            case let .decorUnlocked(t):
                recordDecorUnlocked(t)
            case let .visitedWindow(r, ownerName):
                eventLog.add(.visited, actor: EventRecord.residentRef(r), target: EventRecord.appRef(ownerName),
                             detail: ["source": "visit_wish"])
            case let .activity(a):
                recordActivityEvents([a])
            case let .story(s):
                recordStoryEvents([s])
                story.append(s)
            }
        }
        return story
    }

    /// `wish_started` / `wish_fulfilled` / `wish_dropped`：`actor` 为 Wisher；`target` 为 Flower_Wish 的
    /// Receiver、Chase_Wish 的另一位居民、Visit_Wish 的 `app:<名称>`，Chair_Wish 和 Lamp_Wish 为 null；
    /// `detail` 含 `wish_type`、`wish_state`，Chase_Wish 的 `wish_fulfilled` 另含 `chase_outcome`。
    private func recordWish(_ type: EventType, _ w: Wish, state ws: WishState, outcome: ChaseOutcome?) {
        recordWish(type, type: w.type, wisher: w.wisher, visitApp: w.visitTarget?.ownerName,
                   state: ws, outcome: outcome)
    }

    private func recordWish(
        _ type: EventType, type wishType: WishType, wisher: ResidentID, visitApp: String?,
        state ws: WishState, outcome: ChaseOutcome?
    ) {
        let target: String?
        switch wishType {
        case .flower, .chase: target = EventRecord.residentRef(wisher.other)
        case .visit: target = visitApp.map(EventRecord.appRef)
        case .chair, .lamp: target = nil
        }
        var detail = ["wish_type": wishType.rawValue, "wish_state": ws.rawValue]
        if let outcome { detail["chase_outcome"] = outcome.rawValue }
        eventLog.add(type, actor: EventRecord.residentRef(wisher), target: target, detail: detail)
    }

    /// 剧情事件：`round_started`、`sprouted`、`bloomed` 没有发起方；`planted` 的发起方是 Giver、对象是 Receiver；
    /// `gift_delivered` 的发起方是送果子的一方、对象是收果子的一方。阶段变化和花被移除不记录。
    private func recordStoryEvents(_ events: [StoryEvent]) {
        for e in events {
            switch e {
            case let .roundStarted(round, giver, receiver):
                eventLog.add(.roundStarted, detail: [
                    "round": String(round), "giver": EventRecord.residentRef(giver),
                    "receiver": EventRecord.residentRef(receiver),
                ])
            case let .planted(flower, giver, receiver):
                eventLog.add(.planted, actor: EventRecord.residentRef(giver),
                             target: EventRecord.residentRef(receiver),
                             detail: ["flower": EventRef.flower(flower), "round": String(state.story.round)])
            case let .sprouted(flower):
                eventLog.add(.sprouted, target: EventRef.flower(flower))
            case let .bloomed(flower):
                eventLog.add(.bloomed, target: EventRef.flower(flower))
            case let .giftDelivered(fruit, from, to):
                eventLog.add(.giftDelivered, actor: EventRecord.residentRef(from),
                             target: EventRecord.residentRef(to),
                             detail: ["fruit": EventRef.fruit(fruit), "round": String(state.story.round)])
            case .stageChanged, .flowerEvicted:
                break
            }
        }
    }
}
