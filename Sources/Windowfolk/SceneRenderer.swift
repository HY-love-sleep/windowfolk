import AppKit
import SpriteKit
import WindowfolkCore

/// 按 `WorldView` 更新 SpriteKit 场景。
///
/// 绘制「显示路面」调试线（Requirement 3.11 至 3.13）：Window_Ledge 蓝色、Ground 棕色、Plank 橙色；
/// 以及居民（以 `ResidentID` 为键复用 `SKSpriteNode`，图形来自 `AssetProvider`）。
/// 物件、Toolbox、木板、梯子和气泡同样以对象 ID 为键复用节点。
@MainActor
final class SceneRenderer {
    static let ledgeColor = NSColor.systemBlue
    static let groundColor = NSColor.brown
    static let plankColor = NSColor.systemOrange
    static let surfaceLineWidth: CGFloat = 2

    /// 全部世界节点的根容器，挂在 Overlay 的 SKScene 下。全屏时隐藏它（任务 17.6，Requirement 23.1、23.2）。
    /// 所有节点都加到这里而不是直接加到 SKScene，隐藏期间新建的节点也一并隐藏。
    private let scene = SKNode()
    private var geometry: ScreenGeometry
    /// Overlay 在 AppKit 全局坐标中的原点，用于把全局坐标换成场景坐标。
    private var overlayOrigin: CGPoint

    /// 路面调试线的容器节点。
    private let surfaceLayer = SKNode()
    /// 上一次绘制的路面；只有内容或开关变化时才重建线段。
    private var drawnSurfaces: [Surface]?

    /// 居民动画的播放速度（帧/秒）。
    static let residentAnimationFPS: Double = 8
    /// 低频档位（Idle_Poll_Rate）下循环动画的播放速度（帧/秒，任务 17.2）。
    /// 静止桌面上每换一帧纹理都要重绘整个全屏 Overlay，8 帧/秒的待机动画会让 CPU 超出
    /// Idle_CPU_Budget（Requirement 29.1）；降到 2 帧/秒后每秒只重绘约 2 次。
    /// 只影响循环动画；`planting` 和 `celebrating` 按进度播放，且发生时循环处于高频档位。
    static let idleAnimationFPS: Double = 2
    /// 当前循环动画的播放速度；GameLoop 切换轮询档位时设置。
    var loopAnimationFPS: Double = SceneRenderer.residentAnimationFPS

    private let assets: AssetProvider
    private let constants: Tunables

    /// 居民节点的容器。
    private let residentLayer = SKNode()
    /// 以 `ResidentID` 为键复用的居民节点。
    private var residentNodes: [ResidentID: SKSpriteNode] = [:]
    /// 每个居民节点当前显示的状态和帧，避免每帧重复设置纹理。
    private var residentFrames: [ResidentID: (state: ResidentState, frame: Int)] = [:]
    /// 每个居民进入当前状态的渲染时刻，用于 `celebrating` 只播放一遍。
    private var stateEntered: [ResidentID: (state: ResidentState, time: CFTimeInterval)] = [:]
    /// 以居民和气泡槽为键复用的气泡节点。
    private var bubbleNodes: [BubbleKey: BubbleNode] = [:]

    /// Toolbox 节点与上次绘制的位置。
    private let toolboxNode = SKSpriteNode(color: .clear, size: .zero)
    private var drawnToolbox: Rect?
    /// 以 `PlankID` 为键复用的木板节点。
    private var plankNodes: [PlankID: PlankNode] = [:]
    /// 以 `LadderID` 为键复用的梯子节点。
    private var ladderNodes: [LadderID: LadderNode] = [:]
    /// 以 `ItemID` 为键复用的物件节点，以及每个节点当前显示的素材键。
    private var itemNodes: [ItemID: SKSpriteNode] = [:]
    private var itemKeys: [ItemID: String] = [:]
    /// 木板拖动预览（绿色或红色）。
    private let previewNode = PlankNode()
    /// 梯子拖动预览（绿色或红色）。
    private let ladderPreviewNode = LadderNode()

    /// 以 `DecorID` 为键复用的 Decor 节点，以及每个节点当前显示的素材键。
    private var decorNodes: [DecorID: SKSpriteNode] = [:]
    private var decorKeys: [DecorID: String] = [:]
    /// Visit_Flag 节点，按 `WorldView.visitFlags` 的下标复用。
    private var visitFlagNodes: [SKSpriteNode] = []
    /// Toolbox 右侧的 Decor_Slot 节点，以及上次布局所用的 Unlocked_Decor。
    private var decorSlotNodes: [DecorType: DecorSlotNode] = [:]
    private var drawnUnlocked: Set<DecorType>?
    /// 以居民为键复用的 Thought 文字气泡节点。
    private var thoughtNodes: [ResidentID: ThoughtBubbleNode] = [:]

    init(scene: SKScene, geometry: ScreenGeometry, overlayFrame: CGRect,
         assets: AssetProvider = AssetProvider(), constants: Tunables = Tunables()) {
        self.geometry = geometry
        self.overlayOrigin = overlayFrame.origin
        self.assets = assets
        self.constants = constants
        self.scene.name = "world_root"
        scene.addChild(self.scene)
        residentLayer.name = "residents"
        residentLayer.zPosition = 50
        self.scene.addChild(residentLayer)
        surfaceLayer.name = "surfaces"
        surfaceLayer.zPosition = 100
        self.scene.addChild(surfaceLayer)
    }

    /// 全屏时为 true：隐藏全部居民、物件、Toolbox 和路面线（Requirement 23.1、23.2）。
    /// 只改显示，不影响世界状态（Requirement 23.3）；节点照常按 `WorldView` 更新，取消隐藏后立即是最新画面。
    var isWorldHidden: Bool {
        get { scene.isHidden }
        set { scene.isHidden = newValue }
    }

    /// Overlay 尺寸或位置变化时调用（任务 17.4）。主显示器高度变化时同时传入新的 `geometry`。
    func overlayDidMove(to frame: CGRect, geometry: ScreenGeometry? = nil) {
        if let geometry { self.geometry = geometry }
        overlayOrigin = frame.origin
        drawnSurfaces = nil
        drawnToolbox = nil
        drawnUnlocked = nil
        lastView = nil
    }

    /// 上一次完整绘制所用的世界快照。
    private var lastView: WorldView?

    /// 按快照更新场景，返回画面是否可能有变化（任务 17.2）。
    ///
    /// 快照与上一次相同时跳过全部节点更新，只按时间推进居民动画帧；动画帧也没变时返回 false，
    /// GameLoop 据此暂停 SKView，不再重复渲染同一画面。
    @discardableResult
    func render(_ view: WorldView) -> Bool {
        let time = CACurrentMediaTime()
        if view == lastView {
            return advanceResidentAnimations(view.residents, story: view.story, time: time)
        }
        lastView = view
        renderToolbox(view)
        renderPlanks(view.planks)
        renderLadders(view.ladders)
        renderPreview(view)
        renderSurfaces(view.showSurfaces ? view.surfaces : nil)
        renderResidents(view.residents, story: view.story, time: time)
        renderItems(view.items)
        renderDecors(view.decors, isNight: view.isNight)
        renderVisitFlags(view.visitFlags)
        return true
    }

    /// 快照不变时只推进可见居民的动画帧；返回是否换了任何纹理。
    private func advanceResidentAnimations(_ residents: [ResidentView], story: StoryView?,
                                           time: CFTimeInterval) -> Bool {
        var changed = false
        for resident in residents where !resident.isHidden && resident.position != nil {
            guard let node = residentNodes[resident.id] else { continue }
            if updateResidentTexture(resident, node: node, story: story, time: time) {
                changed = true
            }
        }
        return changed
    }

    /// 按状态和时间选出动画帧，与当前显示的不同时换纹理；返回是否换了纹理。
    private func updateResidentTexture(_ resident: ResidentView, node: SKSpriteNode,
                                       story: StoryView?, time: CFTimeInterval) -> Bool {
        let spec = AssetCatalog.residentSpec(resident.id, resident.state)
        let frame = Self.animationFrame(
            state: resident.state, frames: spec.frames, time: time,
            enteredAt: stateEntered[resident.id]?.time ?? time,
            plantingProgress: story?.stage == .planting ? story?.plantingProgress : nil,
            plantDuration: constants.plantAnimationDuration, fps: loopAnimationFPS)
        if let shown = residentFrames[resident.id], shown.state == resident.state, shown.frame == frame {
            return false
        }
        guard let texture = assets.residentTexture(resident.id, resident.state, frame: frame) else {
            return false
        }
        node.texture = texture
        residentFrames[resident.id] = (resident.state, frame)
        return true
    }

    // MARK: - 物件

    /// 放在窗沿、Ground、Plank 上或下落中的物件：在木板之上、居民之后。
    static let itemZ: CGFloat = 30
    /// 被居民持有的物件：画在居民前面（居民层 z = 50）。
    static let heldItemZ: CGFloat = 55
    /// 拖动中的物件：画在预览之上、气泡之下。
    static let draggedItemZ: CGFloat = 65

    /// 以 `ItemID` 为键复用物件节点。`view.items` 已排除隐藏窗口上和隐藏居民持有的物件，
    /// 不在列表中的节点直接移除（Requirement 5.2）。Flower 按 Growth_Stage 换图（Requirement 17.8）。
    private func renderItems(_ items: [ItemView]) {
        var seen = Set<ItemID>()
        for item in items {
            seen.insert(item.id)
            let node = itemNodes[item.id] ?? {
                let n = SKSpriteNode(color: .clear, size: .zero)
                n.anchorPoint = CGPoint(x: 0.5, y: 0)   // 底边中点对齐 position
                n.name = "item_\(item.id)"
                scene.addChild(n)
                itemNodes[item.id] = n
                return n
            }()

            let key = item.assetKey
            if itemKeys[item.id] != key, let texture = assets.texture(for: key) {
                node.texture = texture
                node.size = AssetProvider.displaySize(SpriteMetrics.itemSize(item.kind))
                itemKeys[item.id] = key
            }

            var point = scenePoint(item.position)
            point.y += CGFloat(item.jumpLift)
            node.position = point
            node.zPosition = item.isDragged ? Self.draggedItemZ
                : (item.holder != nil ? Self.heldItemZ : Self.itemZ)
        }
        for (id, node) in itemNodes where !seen.contains(id) {
            node.removeFromParent()
            itemNodes[id] = nil
            itemKeys[id] = nil
        }
    }

    // MARK: - Decor 与 Visit_Flag

    /// 放置或下落中的 Decor：在木板之上、物件和居民之后（坐着的居民画在 Chair 前面）。
    static let decorZ: CGFloat = 25
    /// Visit_Flag：与放置的 Decor 同层。
    static let visitFlagZ: CGFloat = 25

    /// 以 `DecorID` 为键复用 Decor 节点；只在素材键变化时换纹理。
    /// Lamp 在 Night 时用发光外观 `decor_lamp_on`，否则 `decor_lamp_off`（v2 Requirement 5.10、16.5）；
    /// Night 变化后下一次快照更新时换图。`view.decors` 已排除隐藏窗口上的 Decor。
    private func renderDecors(_ decors: [DecorView], isNight: Bool) {
        var seen = Set<DecorID>()
        for decor in decors {
            seen.insert(decor.id)
            let node = decorNodes[decor.id] ?? {
                let n = SKSpriteNode(color: .clear, size: .zero)
                n.anchorPoint = CGPoint(x: 0.5, y: 0)   // 底边中点对齐 position
                n.name = "decor_\(decor.id)"
                scene.addChild(n)
                decorNodes[decor.id] = n
                return n
            }()
            let key = AssetCatalog.decorKey(decor.type, isNight: isNight)
            if decorKeys[decor.id] != key, let texture = assets.texture(for: key) {
                node.texture = texture
                node.size = AssetProvider.displaySize(SpriteMetrics.decorSize(decor.type))
                decorKeys[decor.id] = key
            }
            node.position = scenePoint(decor.position)
            node.zPosition = decor.isDragged ? Self.draggedItemZ : Self.decorZ
        }
        for (id, node) in decorNodes where !seen.contains(id) {
            node.removeFromParent()
            decorNodes[id] = nil
            decorKeys[id] = nil
        }
    }

    /// Visit_Flag 底边中点放在 `WorldView.visitFlags` 给出的窗沿中点上（v2 Requirement 9.2、9.7）。
    private func renderVisitFlags(_ flags: [Point]) {
        while visitFlagNodes.count < flags.count {
            let n = SKSpriteNode(texture: assets.texture(for: AssetCatalog.visitFlagKey),
                                 size: AssetProvider.displaySize(SpriteMetrics.visitFlag))
            n.anchorPoint = CGPoint(x: 0.5, y: 0)
            n.zPosition = Self.visitFlagZ
            n.name = "visit_flag_\(visitFlagNodes.count)"
            scene.addChild(n)
            visitFlagNodes.append(n)
        }
        while visitFlagNodes.count > flags.count {
            visitFlagNodes.removeLast().removeFromParent()
        }
        for (node, p) in zip(visitFlagNodes, flags) {
            node.position = scenePoint(p)
        }
    }

    // MARK: - Toolbox

    /// 晃动的最大水平偏移（pt）。
    static let toolboxShakeAmplitude: CGFloat = 3

    /// 外框左侧 72pt 画 v1 `toolbox` 图（Plank、Ladder 两区），右侧每个 Decor_Slot 画一个同色木箱底和
    /// 该 Decor 的缩小图标（v2 Requirement 2.1、2.2、2.8）。布局只在外框或 Unlocked_Decor 变化时更新；
    /// 晃动（v2 Requirement 2.4）只改对应 Decor_Slot 的水平偏移。
    private func renderToolbox(_ view: WorldView) {
        let frame = view.toolbox
        if frame != drawnToolbox || view.unlockedDecor != drawnUnlocked {
            drawnToolbox = frame
            drawnUnlocked = view.unlockedDecor
            layoutToolbox(frame, screen: view.screen, unlocked: view.unlockedDecor)
        }
        for (type, node) in decorSlotNodes {
            node.shakeOffset = Self.shakeOffset(view.toolboxShake, zone: .decor(type),
                                                duration: constants.toolboxShakeDuration)
        }
    }

    private func layoutToolbox(_ frame: Rect, screen: ScreenInfo, unlocked: Set<DecorType>) {
        if toolboxNode.parent == nil {
            toolboxNode.texture = assets.texture(for: AssetCatalog.toolboxKey)
            toolboxNode.anchorPoint = .zero
            toolboxNode.name = "toolbox"
            toolboxNode.zPosition = 10
            scene.addChild(toolboxNode)
        }
        let base = Rect(minX: frame.minX, minY: frame.minY,
                        width: min(frame.width, ToolboxLayout.zoneWidth * 2), height: frame.height)
        let r = sceneRect(base)
        toolboxNode.size = r.size
        toolboxNode.position = r.origin

        for type in DecorType.allCases {
            guard unlocked.contains(type),
                  let zone = ToolboxLayout.zoneFrame(.decor(type), screen: screen, unlocked: unlocked) else {
                decorSlotNodes[type]?.removeFromParent()
                decorSlotNodes[type] = nil
                continue
            }
            let node = decorSlotNodes[type] ?? {
                let n = DecorSlotNode(type: type, assets: assets)
                n.zPosition = 10
                n.name = "decor_slot_\(type.rawValue)"
                scene.addChild(n)
                decorSlotNodes[type] = n
                return n
            }()
            node.layout(in: sceneRect(zone))
        }
    }

    /// 晃动偏移：在晃动时长内走一个完整正弦周期（先右后左再回中），结束或不是该取物区时为 0。
    static func shakeOffset(_ shake: ToolboxShake?, zone: ToolboxZone, duration: Double) -> CGFloat {
        guard let shake, shake.zone == zone, duration > 0 else { return 0 }
        let progress = min(1, max(0, 1 - shake.remaining / duration))
        return toolboxShakeAmplitude * CGFloat(sin(2 * Double.pi * progress))
    }

    // MARK: - 木板

    private func renderPlanks(_ planks: [PlankView]) {
        var seen = Set<PlankID>()
        for plank in planks {
            seen.insert(plank.id)
            let (leftTop, rightTop) = Self.topEdge(plank.shape)
            let node = plankNodes[plank.id] ?? {
                let n = PlankNode()
                n.zPosition = 20
                scene.addChild(n)
                plankNodes[plank.id] = n
                return n
            }()
            node.update(from: scenePoint(leftTop), to: scenePoint(rightTop), tint: nil, assets: assets)
        }
        for (id, node) in plankNodes where !seen.contains(id) {
            node.removeFromParent()
            plankNodes[id] = nil
        }
    }

    /// 木板上表面的左右端点（Core 坐标）。已架设木板的上表面就是 Plank Surface；
    /// 平放木板以底边中点定位，上表面在其上方一个厚度处。
    private static func topEdge(_ shape: PlankView.Shape) -> (Point, Point) {
        switch shape {
        case let .placed(l, r):
            return (l, r)
        case let .loose(c):
            return looseTopEdge(bottomCenter: c)
        }
    }

    private static func looseTopEdge(bottomCenter c: Point) -> (Point, Point) {
        let half = SpriteMetrics.loosePlankLength / 2
        let y = c.y - SpriteMetrics.plankThickness
        return (Point(x: c.x - half, y: y), Point(x: c.x + half, y: y))
    }

    // MARK: - 梯子

    /// 上端窗口隐藏的已架设梯子和隐藏窗口上的落下梯子不在 `view.ladders` 中，节点随之移除（Requirement 5.2）。
    private func renderLadders(_ ladders: [LadderView]) {
        var seen = Set<LadderID>()
        for ladder in ladders {
            seen.insert(ladder.id)
            let (foot, head) = Self.axis(ladder.shape)
            let node = ladderNodes[ladder.id] ?? {
                let n = LadderNode()
                n.zPosition = 20
                scene.addChild(n)
                ladderNodes[ladder.id] = n
                return n
            }()
            node.update(from: scenePoint(foot), to: scenePoint(head), tint: nil, assets: assets)
        }
        for (id, node) in ladderNodes where !seen.contains(id) {
            node.removeFromParent()
            ladderNodes[id] = nil
        }
    }

    /// 梯子中轴线的两端（Core 坐标）：横档从 `foot` 平铺到 `head`。
    /// 已架设梯子从下端到上端；平放梯子以底边中点定位，中轴线在其上方半个梯宽处，从左到右。
    private static func axis(_ shape: LadderView.Shape) -> (Point, Point) {
        switch shape {
        case let .placed(top, bottom):
            return (bottom, top)
        case let .loose(c):
            return looseLadderAxis(bottomCenter: c)
        }
    }

    private static func looseLadderAxis(bottomCenter c: Point) -> (Point, Point) {
        let half = SpriteMetrics.looseLadderLength / 2
        let y = c.y - SpriteMetrics.ladderWidth / 2
        return (Point(x: c.x - half, y: y), Point(x: c.x + half, y: y))
    }

    // MARK: - 拖动预览

    static let validPreviewColor = NSColor.systemGreen
    static let invalidPreviewColor = NSColor.systemRed

    /// 参数取整个 `WorldView`：`Preview` 这个名字与 AppKit 带进来的 DeveloperToolsSupport.Preview 冲突。
    private func renderPreview(_ view: WorldView) {
        for node in [previewNode, ladderPreviewNode] as [SKNode] where node.parent == nil {
            node.zPosition = 60
            node.alpha = 0.85
            scene.addChild(node)
        }
        guard let preview = view.preview else {
            previewNode.isHidden = true
            ladderPreviewNode.isHidden = true
            return
        }
        let tint = preview.isValid ? Self.validPreviewColor : Self.invalidPreviewColor
        switch preview.geometry {
        case let .snappedPlank(a, b, _, _):
            let (left, right) = a.x <= b.x ? (a, b) : (b, a)
            showPlankPreview(left, right, tint: tint)
        case let .loosePlank(c):
            let (left, right) = Self.looseTopEdge(bottomCenter: c)
            showPlankPreview(left, right, tint: tint)
        case let .snappedLadder(top, bottom, _):
            // 上端正下方没有 Surface 时（预览必为红色）按 Ladder_Length 画出竖直长度。
            let foot = bottom ?? Point(x: top.x, y: top.y + constants.ladderLength)
            showLadderPreview(foot, top, tint: tint)
        case let .looseLadder(c):
            let (left, right) = Self.looseLadderAxis(bottomCenter: c)
            showLadderPreview(left, right, tint: tint)
        }
    }

    private func showPlankPreview(_ left: Point, _ right: Point, tint: NSColor) {
        ladderPreviewNode.isHidden = true
        previewNode.isHidden = false
        previewNode.update(from: scenePoint(left), to: scenePoint(right), tint: tint, assets: assets)
    }

    private func showLadderPreview(_ foot: Point, _ head: Point, tint: NSColor) {
        previewNode.isHidden = true
        ladderPreviewNode.isHidden = false
        ladderPreviewNode.update(from: scenePoint(foot), to: scenePoint(head), tint: tint, assets: assets)
    }

    // MARK: - 居民

    /// 选出居民当前应显示的动画帧。
    /// - `planting`：两人共用 Core 的种花进度（0...1），在 Plant_Animation_Duration 内从第一帧走到最后一帧，
    ///   前半蹲下、后半一起跳一下，两人画面同步；窗口隐藏时进度暂停，画面也停住（Requirement 16.10、16.14）。
    /// - `celebrating`：从进入该状态起在 `StoryDirector.celebrateDuration` 内播放一遍，停在最后一帧，
    ///   不循环（Requirement 18.8）；随后 Core 把状态转为 `idle`。
    /// - 其他状态按 `fps`（默认 `residentAnimationFPS`）循环。
    static func animationFrame(state: ResidentState, frames: Int, time: CFTimeInterval,
                               enteredAt: CFTimeInterval, plantingProgress: Double?,
                               plantDuration: Double, fps: Double = residentAnimationFPS) -> Int {
        let count = max(1, frames)
        switch state {
        case .planting:
            let progress = plantingProgress
                ?? (time - enteredAt) / max(0.01, plantDuration)
            return min(count - 1, max(0, Int(progress * Double(count))))
        case .celebrating:
            let elapsed = max(0, time - enteredAt)
            let progress = elapsed / max(0.01, StoryDirector.celebrateDuration)
            return min(count - 1, Int(progress * Double(count)))
        default:
            return Int(time * fps) % count
        }
    }

    private func renderResidents(_ residents: [ResidentView], story: StoryView?, time: CFTimeInterval) {
        var seen = Set<ResidentID>()
        for resident in residents {
            seen.insert(resident.id)
            let node = residentNode(for: resident.id)

            // 隐藏窗口上的居民不绘制（Requirement 5.2）。
            guard !resident.isHidden, let position = resident.position else {
                node.isHidden = true
                thoughtNodes[resident.id]?.isHidden = true
                continue
            }
            node.isHidden = false

            if stateEntered[resident.id]?.state != resident.state {
                stateEntered[resident.id] = (resident.state, time)
            }
            _ = updateResidentTexture(resident, node: node, story: story, time: time)

            // 底边中点对齐 position；朝左时水平镜像。戳居民的跳跃和坐在 Chair 上的上移
            // （v2 `seatLift`）都只是向上的显示偏移，与 `SpriteMetrics.residentRect` 的命中矩形一致。
            var point = scenePoint(position)
            point.y += CGFloat(resident.jumpLift + resident.seatLift)
            node.position = point
            node.xScale = resident.facing == .left ? -1 : 1

            let iconCount = renderBubbles(for: resident,
                                          residentTop: point.y + CGFloat(SpriteMetrics.resident.height),
                                          x: point.x)
            renderThought(for: resident, iconBubblesBelow: iconCount)
        }

        for (id, node) in residentNodes where !seen.contains(id) {
            node.removeFromParent()
            residentNodes[id] = nil
            residentFrames[id] = nil
            stateEntered[id] = nil
        }
        for (key, node) in bubbleNodes where !seen.contains(key.resident) {
            node.removeFromParent()
            bubbleNodes[key] = nil
        }
        for (id, node) in thoughtNodes where !seen.contains(id) {
            node.removeFromParent()
            thoughtNodes[id] = nil
        }
    }

    // MARK: - 气泡

    /// 每位居民头顶的两个气泡槽：剧情气泡（「...」、许愿、心形，以及 v2 的 Wish_Bubble、Zzz、花朵）贴着头顶，
    /// 戳居民的「?」气泡在它上方；没有剧情气泡时「?」直接贴着头顶。
    /// 两者互不覆盖，因此 `waiting` 期间「...」持续显示（Requirement 12.10），戳一下也不会把它挡掉。
    /// 例外：「?」显示期间隐藏 Wish_Bubble（`.wishIcon` 与送花的 `.wish(receiver:)`），「?」结束后的下一帧恢复
    /// （v2 Requirement 10.6）。
    private enum BubbleSlot: Hashable { case story, poke }
    private struct BubbleKey: Hashable { var resident: ResidentID; var slot: BubbleSlot }

    /// 返回本帧显示的图标气泡个数（0 至 2），Thought 气泡画在它们上方。
    private func renderBubbles(for resident: ResidentView, residentTop: CGFloat, x: CGFloat) -> Int {
        var y = residentTop + Self.bubbleGap
        var count = 0
        // 戳居民的「?」气泡（Requirement 7.6、7.8）。
        let poking = (resident.poke?.bubbleRemaining ?? 0) > 0
        let storyBubble = Self.storyBubble(resident.bubble, poking: poking)
        let story = storyBubble.map(BubbleIcon.init)
        if showBubble(story, receiver: Self.wishReceiver(storyBubble), mirrored: Self.isMirrored(storyBubble),
                      key: BubbleKey(resident: resident.id, slot: .story), at: CGPoint(x: x, y: y)) {
            y += CGFloat(SpriteMetrics.bubble.height) + Self.bubbleGap
            count += 1
        }
        if showBubble(poking ? .question : nil, receiver: nil, mirrored: false,
                      key: BubbleKey(resident: resident.id, slot: .poke), at: CGPoint(x: x, y: y)) {
            count += 1
        }
        return count
    }

    /// 剧情槽本帧显示的气泡：「?」显示期间 Wish_Bubble 让位，其余气泡（「...」、心形、Zzz、花朵）照常；
    /// 「?」结束后的下一帧 `poking` 为 false，原气泡恢复（v2 Requirement 10.6）。
    /// Wish_Bubble 包括 v2 的 `.wishIcon` 和送花心愿沿用的 v1 许愿气泡 `.wish(receiver:)`。
    static func storyBubble(_ bubble: Bubble?, poking: Bool) -> Bubble? {
        guard poking else { return bubble }
        switch bubble {
        case .wishIcon, .wish: return nil
        default: return bubble
        }
    }

    /// 「小旗」气泡的箭头朝左时整个气泡水平镜像（占位图的箭头朝右，v2 Requirement 9.3）。
    static func isMirrored(_ bubble: Bubble?) -> Bool {
        if case .wishIcon(.flag(arrow: .left)) = bubble { return true }
        return false
    }

    /// 在 `point`（底边中点）显示一个图标气泡；`icon` 为 nil 时隐藏该槽。返回是否显示。
    /// 图标气泡全部是图形，不含文字（Requirement 15.9、v2 Requirement 14.6）。
    @discardableResult
    private func showBubble(_ icon: BubbleIcon?, receiver: ResidentID?, mirrored: Bool,
                            key: BubbleKey, at point: CGPoint) -> Bool {
        guard let icon else {
            bubbleNodes[key]?.isHidden = true
            return false
        }
        let node = bubbleNodes[key] ?? {
            let n = BubbleNode(size: AssetProvider.displaySize(SpriteMetrics.bubble))
            n.zPosition = 70
            n.name = "bubble_\(key.resident.rawValue)_\(key.slot)"
            scene.addChild(n)
            bubbleNodes[key] = n
            return n
        }()
        node.show(icon, receiver: receiver, assets: assets)
        node.xScale = mirrored ? -1 : 1
        node.isHidden = false
        node.position = point
        return true
    }

    /// Thought 单行文字气泡（v2 Requirement 14.4、16.6、16.7）。位置和宽度取自 `ThoughtLayout`：
    /// 有图标气泡时画在最上面一个图标气泡之上并留间隔，否则贴着头顶。
    private func renderThought(for resident: ResidentView, iconBubblesBelow: Int) {
        guard let text = resident.thought, !text.isEmpty, var head = ThoughtLayout.headTop(of: resident) else {
            thoughtNodes[resident.id]?.isHidden = true
            return
        }
        let node = thoughtNodes[resident.id] ?? {
            let n = ThoughtBubbleNode()
            n.zPosition = 70
            n.name = "thought_\(resident.id.rawValue)"
            scene.addChild(n)
            thoughtNodes[resident.id] = n
            return n
        }()
        node.setText(text, baseTexture: assets.bubbleBaseTexture)
        // `ThoughtLayout` 只考虑一个图标气泡；「?」与剧情气泡同时显示时，把头顶再上移一个气泡位。
        if iconBubblesBelow > 1 {
            head.y -= Double(iconBubblesBelow - 1) * (ThoughtLayout.iconBubble.height + ThoughtLayout.gap)
        }
        let rect = ThoughtLayout.thoughtRect(textWidth: Double(node.textWidth), headTop: head,
                                             hasWishBubble: iconBubblesBelow > 0)
        node.layout(in: sceneRect(rect))
        node.isHidden = false
    }

    private static func wishReceiver(_ bubble: Bubble?) -> ResidentID? {
        if case let .wish(receiver) = bubble { return receiver }
        return nil
    }

    static let bubbleGap: CGFloat = 2

    private func residentNode(for id: ResidentID) -> SKSpriteNode {
        if let node = residentNodes[id] { return node }
        let node = SKSpriteNode(color: .clear, size: AssetProvider.displaySize(AssetCatalog.residentSize))
        node.anchorPoint = CGPoint(x: 0.5, y: 0)
        node.name = id.rawValue
        // 都都在前、嘟嘟在后，重叠时顺序固定。
        node.zPosition = id == .a ? 1 : 0
        residentLayer.addChild(node)
        residentNodes[id] = node
        return node
    }

    // MARK: - 路面

    private func renderSurfaces(_ surfaces: [Surface]?) {
        guard surfaces != drawnSurfaces else { return }
        drawnSurfaces = surfaces
        surfaceLayer.removeAllChildren()
        guard let surfaces else { return }

        for surface in surfaces {
            let path = CGMutablePath()
            path.move(to: scenePoint(surface.start))
            path.addLine(to: scenePoint(surface.end))

            let node = SKShapeNode(path: path)
            node.strokeColor = Self.color(for: surface.id)
            node.lineWidth = Self.surfaceLineWidth
            node.lineCap = .round
            node.isAntialiased = true
            surfaceLayer.addChild(node)
        }
    }

    /// 三种 Surface 类型各用一种颜色。用 `if case` 而不是 `switch`，
    /// 这样任务 6.1 给 `SurfaceID` 加入 `.plank` 后无需改这里也能编译，并自动落到橙色。
    static func color(for id: SurfaceID) -> NSColor {
        if case .ground = id { return groundColor }
        if case .ledge = id { return ledgeColor }
        return plankColor
    }

    /// Core 坐标 → 场景坐标。y 翻转只经 `ScreenGeometry`；场景 anchorPoint 为 (0, 0)，
    /// 尺寸等于 Overlay，因此场景坐标等于 Overlay 内的 AppKit 坐标。
    private func scenePoint(_ p: Point) -> CGPoint {
        let global = geometry.appKitPoint(fromCore: p)
        return CGPoint(x: global.x - overlayOrigin.x, y: global.y - overlayOrigin.y)
    }

    /// Core 矩形 → 场景矩形（翻转同样只经 `ScreenGeometry`）。
    private func sceneRect(_ r: Rect) -> CGRect {
        let global = geometry.appKitRect(fromCore: r)
        return global.offsetBy(dx: -overlayOrigin.x, dy: -overlayOrigin.y)
    }
}

/// 一块木板的图形：沿上表面从左端到右端平铺 `plank` 单元，厚度向下延伸，可以倾斜。
/// 节点原点在左端上表面，按两端连线旋转；只有长度或颜色变化时才重建平铺单元。
@MainActor
final class PlankNode: SKNode {
    private var builtLength: CGFloat = -1
    private var builtTint: NSColor?

    func update(from left: CGPoint, to right: CGPoint, tint: NSColor?, assets: AssetProvider) {
        let dx = right.x - left.x, dy = right.y - left.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        position = left
        zRotation = atan2(dy, dx)

        let rounded = (length * 2).rounded() / 2
        guard rounded != builtLength || tint != builtTint else { return }
        builtLength = rounded
        builtTint = tint
        rebuild(length: rounded, tint: tint, assets: assets)
    }

    private func rebuild(length: CGFloat, tint: NSColor?, assets: AssetProvider) {
        removeAllChildren()
        let tile = AssetProvider.displaySize(AssetCatalog.plankTileSize)
        guard let texture = assets.texture(for: AssetCatalog.plankKey), tile.width > 0 else { return }

        var x: CGFloat = 0
        while x < length - 0.01 {
            let w = min(tile.width, length - x)
            // 最后一块不足一个单元时裁掉纹理右侧，而不是拉伸。
            let tex = w < tile.width
                ? SKTexture(rect: CGRect(x: 0, y: 0, width: w / tile.width, height: 1), in: texture)
                : texture
            let sprite = SKSpriteNode(texture: tex, size: CGSize(width: w, height: tile.height))
            sprite.anchorPoint = CGPoint(x: 0, y: 1)   // 上表面在节点 y = 0，厚度向下
            sprite.position = CGPoint(x: x, y: 0)
            if let tint {
                sprite.color = tint
                sprite.colorBlendFactor = 0.65
            }
            addChild(sprite)
            x += w
        }
    }
}

/// 一架梯子的图形：沿中轴线从 `foot` 到 `head` 平铺 `ladder` 单元，单元宽度横跨中轴线两侧。
/// 已架设时竖直（从下端到上端），平放时水平；节点原点在 `foot`，按两端连线旋转。
/// 只有长度或颜色变化时才重建平铺单元。
@MainActor
final class LadderNode: SKNode {
    private var builtLength: CGFloat = -1
    private var builtTint: NSColor?

    func update(from foot: CGPoint, to head: CGPoint, tint: NSColor?, assets: AssetProvider) {
        let dx = head.x - foot.x, dy = head.y - foot.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        position = foot
        // 平铺沿节点本地 +y 方向；旋转让 +y 指向 head。
        zRotation = atan2(dy, dx) - .pi / 2

        let rounded = (length * 2).rounded() / 2
        guard rounded != builtLength || tint != builtTint else { return }
        builtLength = rounded
        builtTint = tint
        rebuild(length: rounded, tint: tint, assets: assets)
    }

    private func rebuild(length: CGFloat, tint: NSColor?, assets: AssetProvider) {
        removeAllChildren()
        let tile = AssetProvider.displaySize(AssetCatalog.ladderTileSize)
        guard let texture = assets.texture(for: AssetCatalog.ladderKey), tile.height > 0 else { return }

        var y: CGFloat = 0
        while y < length - 0.01 {
            let h = min(tile.height, length - y)
            // 最后一块不足一个单元时裁掉纹理上侧，而不是拉伸。
            let tex = h < tile.height
                ? SKTexture(rect: CGRect(x: 0, y: 0, width: 1, height: h / tile.height), in: texture)
                : texture
            let sprite = SKSpriteNode(texture: tex, size: CGSize(width: tile.width, height: h))
            sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
            sprite.position = CGPoint(x: 0, y: y)
            if let tint {
                sprite.color = tint
                sprite.colorBlendFactor = 0.65
            }
            addChild(sprite)
            y += h
        }
    }
}

/// 一个图标气泡：底边中点为锚点。许愿气泡在花盆右侧叠加 Receiver 的小头像
/// （占位图里留出了右半边，Requirement 15.9、16.2）。只有图标或头像变化时才换纹理。
@MainActor
final class BubbleNode: SKSpriteNode {
    static let avatarSize = CGSize(width: 10, height: 10)
    /// 头像中心相对气泡底边中点的位置，对应占位气泡圆形内的右半边。
    static let avatarCenter = CGPoint(x: 4.5, y: 13)

    private var shownIcon: BubbleIcon?
    private var shownReceiver: ResidentID?
    private let avatar = SKSpriteNode(color: .clear, size: BubbleNode.avatarSize)

    init(size: CGSize) {
        super.init(texture: nil, color: .clear, size: size)
        anchorPoint = CGPoint(x: 0.5, y: 0)
        avatar.position = Self.avatarCenter
        avatar.zPosition = 1
        avatar.isHidden = true
        addChild(avatar)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ icon: BubbleIcon, receiver: ResidentID?, assets: AssetProvider) {
        if icon != shownIcon {
            texture = assets.texture(for: AssetCatalog.bubbleKey(icon))
            shownIcon = icon
        }
        if receiver != shownReceiver {
            shownReceiver = receiver
            if let receiver {
                avatar.texture = assets.residentTexture(receiver, .idle, frame: 0)
            }
        }
        avatar.isHidden = icon != .wish || receiver == nil
    }
}

/// Toolbox 右侧的一个 Decor_Slot：与 v1 `toolbox` 占位图同色的木箱底，加该 Decor 的缩小图标（v2 Requirement 2.1）。
/// 节点原点在取物区左下角（场景坐标）；晃动只移动内容子节点，不改布局。只有尺寸变化时才重建图形。
@MainActor
final class DecorSlotNode: SKNode {
    static let boxFill = NSColor(srgbRed: 0.66, green: 0.44, blue: 0.24, alpha: 1)
    static let boxStroke = NSColor(srgbRed: 0.40, green: 0.25, blue: 0.12, alpha: 1)
    static let grain = NSColor(srgbRed: 0.52, green: 0.33, blue: 0.17, alpha: 1)
    /// 图标最大显示尺寸（pt）和最大缩放比例。
    static let iconMax = CGSize(width: 28, height: 26)
    static let iconMaxScale: CGFloat = 0.85

    let type: DecorType
    private let content = SKNode()
    private let icon: SKSpriteNode
    private var builtSize: CGSize?

    init(type: DecorType, assets: AssetProvider) {
        self.type = type
        // 工具箱里始终显示 Lamp 的不发光外观。
        let size = AssetProvider.displaySize(SpriteMetrics.decorSize(type))
        let scale = min(Self.iconMaxScale, Self.iconMax.width / size.width, Self.iconMax.height / size.height)
        icon = SKSpriteNode(texture: assets.texture(for: AssetCatalog.decorKey(type, isNight: false)),
                            size: CGSize(width: size.width * scale, height: size.height * scale))
        icon.anchorPoint = CGPoint(x: 0.5, y: 0)
        icon.zPosition = 1
        super.init()
        addChild(content)
        content.addChild(icon)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 水平晃动偏移（pt）。
    var shakeOffset: CGFloat {
        get { content.position.x }
        set { content.position.x = newValue }
    }

    func layout(in rect: CGRect) {
        position = rect.origin
        guard rect.size != builtSize else { return }
        builtSize = rect.size
        content.children.filter { $0 !== icon }.forEach { $0.removeFromParent() }

        // 与 `toolbox` 占位图的箱身相同：底部留 1pt，顶部留 7pt 给露出箱口的物件。
        let box = CGRect(x: 1, y: 1, width: rect.width - 2, height: max(1, rect.height - 8))
        let shape = SKShapeNode(rect: box, cornerRadius: 3)
        shape.fillColor = Self.boxFill
        shape.strokeColor = Self.boxStroke
        shape.lineWidth = 1.5
        shape.isAntialiased = true
        content.addChild(shape)

        let grainPath = CGMutablePath()
        grainPath.move(to: CGPoint(x: 4, y: box.midY - 4))
        grainPath.addLine(to: CGPoint(x: rect.width - 4, y: box.midY - 4))
        let grain = SKShapeNode(path: grainPath)
        grain.strokeColor = Self.grain
        grain.lineWidth = 0.8
        content.addChild(grain)

        icon.position = CGPoint(x: rect.width / 2, y: box.minY + 5)
    }
}

/// Thought 单行文字气泡（v2 Requirement 14.4、16.6、16.7）：图标气泡的底框横向九宫格拉伸到 `ThoughtLayout` 给出的宽度，
/// 上面放一个单行 `SKLabelNode`。不设最大宽度和行数限制，因此文字不换行、不省略、不被裁切。
/// 只有文字变化时才重新排版；节点原点在气泡左下角（场景坐标）。
@MainActor
final class ThoughtBubbleNode: SKNode {
    static let font = NSFont.systemFont(ofSize: 11)
    static let textColor = NSColor(srgbRed: 0.16, green: 0.14, blue: 0.14, alpha: 1)
    /// 底框圆心在气泡高度中的比例（占位底框圆形为 y 3...23，共 24pt）。
    static let textCenterRatio: CGFloat = 13.0 / 24.0

    private let base = SKSpriteNode(color: .clear, size: .zero)
    private let label = SKLabelNode()
    private var shownText: String?
    private var builtWidth: CGFloat?
    /// 当前文字的单行宽度（pt）。
    private(set) var textWidth: CGFloat = 0

    override init() {
        super.init()
        base.anchorPoint = .zero
        // 只拉伸中间一小段竖条，两侧的圆角和左下角的小尾巴保持原样。
        base.centerRect = CGRect(x: 0.46, y: 0, width: 0.08, height: 1)
        addChild(base)
        label.numberOfLines = 1
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.zPosition = 1
        addChild(label)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setText(_ text: String, baseTexture: SKTexture?) {
        if base.texture == nil, let baseTexture {
            base.texture = baseTexture
            base.size = baseTexture.size()
            builtWidth = nil
        }
        guard text != shownText else { return }
        shownText = text
        let attributed = NSAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: Self.textColor,
        ])
        label.attributedText = attributed
        textWidth = ceil(attributed.size().width)
    }

    /// `rect` 为场景坐标中的气泡外接矩形。
    func layout(in rect: CGRect) {
        position = rect.origin
        if rect.width != builtWidth, base.size.width > 0 {
            builtWidth = rect.width
            // 九宫格拉伸只对 xScale/yScale 生效；文字是兄弟节点，不受缩放影响。
            base.xScale = rect.width / base.size.width
            base.yScale = rect.height / base.size.height
        }
        label.position = CGPoint(x: rect.width / 2, y: rect.height * Self.textCenterRatio)
    }
}
