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
        renderToolbox(view.toolbox)
        renderPlanks(view.planks)
        renderLadders(view.ladders)
        renderPreview(view)
        renderSurfaces(view.showSurfaces ? view.surfaces : nil)
        renderResidents(view.residents, story: view.story, time: time)
        renderItems(view.items)
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

    // MARK: - Toolbox

    private func renderToolbox(_ frame: Rect) {
        guard frame != drawnToolbox else { return }
        drawnToolbox = frame
        if toolboxNode.parent == nil {
            toolboxNode.texture = assets.texture(for: AssetCatalog.toolboxKey)
            toolboxNode.anchorPoint = .zero
            toolboxNode.name = "toolbox"
            toolboxNode.zPosition = 10
            scene.addChild(toolboxNode)
        }
        let r = sceneRect(frame)
        toolboxNode.size = r.size
        toolboxNode.position = r.origin
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
                continue
            }
            node.isHidden = false

            if stateEntered[resident.id]?.state != resident.state {
                stateEntered[resident.id] = (resident.state, time)
            }
            _ = updateResidentTexture(resident, node: node, story: story, time: time)

            // 底边中点对齐 position；朝左时水平镜像。戳居民的跳跃只是向上的显示偏移。
            var point = scenePoint(position)
            point.y += CGFloat(resident.jumpLift)
            node.position = point
            node.xScale = resident.facing == .left ? -1 : 1

            renderBubbles(for: resident, residentTop: point.y + CGFloat(SpriteMetrics.resident.height),
                          x: point.x)
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
    }

    // MARK: - 气泡

    /// 每位居民头顶的两个气泡槽：剧情气泡（「...」、许愿、心形）贴着头顶，
    /// 戳居民的「?」气泡在它上方；没有剧情气泡时「?」直接贴着头顶。
    /// 两者互不覆盖，因此 `waiting` 期间「...」持续显示（Requirement 12.10），戳一下也不会把它挡掉。
    private enum BubbleSlot: Hashable { case story, poke }
    private struct BubbleKey: Hashable { var resident: ResidentID; var slot: BubbleSlot }

    private func renderBubbles(for resident: ResidentView, residentTop: CGFloat, x: CGFloat) {
        var y = residentTop + Self.bubbleGap
        let story = resident.bubble.map(Self.icon(for:))
        if showBubble(story, receiver: Self.wishReceiver(resident.bubble),
                      key: BubbleKey(resident: resident.id, slot: .story), at: CGPoint(x: x, y: y)) {
            y += CGFloat(SpriteMetrics.bubble.height) + Self.bubbleGap
        }
        // 戳居民的「?」气泡（Requirement 7.6、7.8）。
        let poking = (resident.poke?.bubbleRemaining ?? 0) > 0
        showBubble(poking ? .question : nil, receiver: nil,
                   key: BubbleKey(resident: resident.id, slot: .poke), at: CGPoint(x: x, y: y))
    }

    /// 在 `point`（底边中点）显示一个图标气泡；`icon` 为 nil 时隐藏该槽。返回是否显示。
    /// 气泡全部是图形，不含文字（Requirement 15.9）。
    @discardableResult
    private func showBubble(_ icon: BubbleIcon?, receiver: ResidentID?, key: BubbleKey, at point: CGPoint) -> Bool {
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
        node.isHidden = false
        node.position = point
        return true
    }

    private static func icon(for bubble: Bubble) -> BubbleIcon {
        switch bubble {
        case .wish: return .wish
        case .dots: return .dots
        case .heart: return .heart
        }
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
