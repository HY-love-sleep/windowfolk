import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// 心愿与玩家操作关系的属性测试（design.md Property 27，任务 7.16；Property 28 由任务 7.17 追加）。
//
// 两个副本使用相同的窗口、相同的预置 Plank / Ladder / Item / Decor、相同的随机种子和时钟，剧情与自主活动都启用，
// Decor 全部预先解锁（Toolbox 布局两边一致）。自然生成 Wish 的概率设为 0，于是「无 Wish」副本始终没有 active
// Wish；「有 Wish」副本在开局后用 `triggerWish` 触发 0 至 2 个任意类型、任意 Wisher 的 Wish。
// 随后两边逐帧执行同样的玩家操作：从 Toolbox 拖出 Plank、Ladder、Chair、Lamp，拖动或点击场上的 Plank、Ladder、
// Item、Decor，点击居民，等待。时区固定为 UTC。
//
// 居民在两个副本中的行为不同（Busy_Resident 由 WishDirector 控制、随机源消耗不同），居民本身不在比较范围内：
// - 按下点在某个副本中命中居民、而另一个副本命中物体时，两边是不同的世界状态而不是 Wish 的限制，
//   这次操作在两边都不发送指针事件（只推进同样的帧数）；
// - 点击居民时每个副本按各自居民的命中区域按下与松开；
// - Flower_Wish 自身产生的花盆不是玩家操作的结果，Item 只比较预置的那些（Item ID 为 UUID，两边相同）。

// MARK: - 生成器

fileprivate struct PreItem: Sendable {
    var isFruit: Bool
    /// 0 为 Ground，1...3 为窗口 1...3 的窗沿。
    var surface: Int
    /// 位置比例（1...9）。
    var frac: Int
}

fileprivate struct PreDecor: Sendable {
    var isLamp: Bool
    var surface: Int
    var frac: Int
}

fileprivate struct InteractionOp: Sendable, CustomStringConvertible {
    /// 0 等待、1 从 Toolbox 拖出、2 拖动场上物体、3 点击场上物体、4 点击居民。
    var kind: Int
    /// Toolbox 区域、场上物体或居民的下标。
    var index: Int
    /// 按下点在命中区域内的相对位置（1...9 → 0.1...0.9）。
    var u: Int, v: Int
    /// 松开点：x = tx × 20 + 10；ty < 9 时 y 为窗口 ty / 3 + 1 的上沿减 `ledgeLift[ty % 3]`，否则取 `lowYs[ty - 9]`。
    var tx: Int, ty: Int
    /// 拖动经过的帧数（含松开那一帧）。
    var moveFrames: Int
    /// 操作结束后再推进的帧数。
    var settle: Int

    static let names = ["wait", "toolbox", "drag", "click", "poke"]
    /// 松开点贴近窗沿，让木板、梯子经常能吸附，Item 和 Decor 经常能放上窗沿。
    static let ledgeLift: [Double] = [0, 4, 15]
    static let lowYs: [Double] = [700, 780, 820]
    static let targetYCount = 12

    func target(windowYs: [Int]) -> Point {
        let y = ty < 9 ? Double(windowYs[ty / 3]) - Self.ledgeLift[ty % 3] : Self.lowYs[ty - 9]
        return Point(x: Double(tx * 20) + 10, y: y)
    }

    var description: String {
        "\(Self.names[kind])(\(index), press \(u)/\(v), to \(tx)/\(ty), \(moveFrames)f) + \(settle)f"
    }
}

fileprivate struct InteractionScenario: Sendable, CustomStringConvertible {
    /// 三个窗口的上沿 y。窗口 1、2 为 x 100、450，宽 250，上沿 360 至 400，两者之间能架木板；
    /// 窗口 3 在窗口 2 右下方（x 550、宽 300），上沿比窗口 2 低 160 或 180，窗口 2 的窗沿能向下架梯子到窗口 3。
    /// 窗口 2 高 120，不遮挡窗口 3 的窗沿；其余高 200。
    var windowYs: [Int]
    var planks: [Int]
    var ladders: [Int]
    var items: [PreItem]
    var decors: [PreDecor]
    /// 「有 Wish」副本触发的 Wish：(Wish_Type 下标, Wisher 下标 0 = A、1 = B；Flower_Wish 忽略 Wisher)。
    var wishes: [(Int, Int)]
    var startHour: Int
    var seed: Int
    var ops: [InteractionOp]

    var description: String {
        "hour \(startHour) seed \(seed) windowYs \(windowYs) planks \(planks) ladders \(ladders) "
            + "items \(items.map { "\($0.isFruit ? "fruit" : "flower")@\($0.surface):\($0.frac)" }) "
            + "decors \(decors.map { "\($0.isLamp ? "lamp" : "chair")@\($0.surface):\($0.frac)" }) "
            + "wishes \(wishes.map { "\(WishType.allCases[$0.0])/\(["a", "b"][$0.1])" }) ops \(ops)"
    }
}

fileprivate var interactionScenarioGen: Generator<InteractionScenario, some SendableSequenceType> {
    let windowYs = zip(Gen<Int>.int(in: 18...20), Gen<Int>.int(in: 18...20), Gen<Int>.int(in: 8...9))
        .map { a, b, d in [a * 20, b * 20, b * 20 + d * 20] }
    let groundX = Gen<Int>.int(in: 2...12).map { $0 * 100 }
    let item = zip(Gen<Bool>.bool, Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 1...9))
        .map { PreItem(isFruit: $0, surface: $1, frac: $2) }
    let decor = zip(Gen<Bool>.bool, Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 1...9))
        .map { PreDecor(isLamp: $0, surface: $1, frac: $2) }
    // Flower_Wish、Chase_Wish 让两人都成为 Busy_Resident，其后不能再有第二个 Wish；类型下标 5...7 再映射到
    // chair、lamp、visit，让两个 Wish 同时 active 的场景更常见。
    let wish = zip(Gen<Int>.int(in: 0...7), Gen<Int>.int(in: 0...1))
        .map { t, w in (t < 5 ? t : t - 4, w) }
    let op = zip(
        Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...11), Gen<Int>.int(in: 1...9), Gen<Int>.int(in: 1...9),
        Gen<Int>.int(in: 0...70), Gen<Int>.int(in: 0...(InteractionOp.targetYCount - 1)),
        Gen<Int>.int(in: 1...5), Gen<Int>.int(in: 1...20)
    ).map { InteractionOp(kind: $0, index: $1, u: $2, v: $3, tx: $4, ty: $5, moveFrames: $6, settle: $7) }
    let world = zip(
        windowYs, groundX.array(of: 0...2), groundX.array(of: 0...2),
        item.array(of: 0...3), decor.array(of: 0...3)
    )
    return zip(
        world, wish.array(of: 0...2), Gen<Int>.int(in: 0...23), Gen<Int>.int(in: 0...1_000_000),
        op.array(of: 1...6)
    ).map { w, wishes0, hour, seed, ops in
        // 两个 Wish 指定同一位 Wisher 时，第二个改为另一位（同一居民不能参与两个 Wish）。
        var wishes = wishes0
        if wishes.count == 2, wishes[1].1 == wishes[0].1 { wishes[1].1 = 1 - wishes[0].1 }
        return InteractionScenario(windowYs: w.0, planks: w.1, ladders: w.2, items: w.3, decors: w.4,
                            wishes: wishes, startHour: hour, seed: seed, ops: ops)
    }
}

// MARK: - 模拟

/// 一个副本：剧情与自主活动启用的完整 V2 世界。
fileprivate final class Copy {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!

    let engine: WorldEngine
    var source: FakeWindowSource
    var view: WorldView

    init(_ s: InteractionScenario, windows: [WindowSnapshot], itemIDs: [ItemID], start: Date) {
        var c = Tunables()
        c.wishSpawnChance = 0
        engine = WorldEngine(constants: c, clockStart: start, screen: Self.screen,
                             rng: RandomSource(seed: UInt64(s.seed)))
        source = FakeWindowSource(snapshots: windows)
        engine.unlockDecor(.chair)
        engine.unlockDecor(.lamp)
        for x in s.planks { engine.insertPlank(.loose(.ground(x: Double(x)))) }
        for x in s.ladders { engine.insertLadder(.loose(.ground(x: Double(x) + 50))) }
        func anchor(_ surface: Int, _ frac: Int) -> CoreAttachment {
            surface == 0 ? .ground(x: 150 + Double(frac) * 120) : .window(WindowID(surface), offset: 24 * Double(frac))
        }
        for (i, it) in s.items.enumerated() {
            let p = ItemPlacement.attached(anchor(it.surface, it.frac))
            engine.insertItem(it.isFruit ? .fruit(id: itemIDs[i], placement: p)
                                         : .flowerPot(id: itemIDs[i], placement: p))
        }
        for (i, d) in s.decors.enumerated() {
            engine.insertDecor(Decor(id: DecorID(UInt64(i + 1)), type: d.isLamp ? .lamp : .chair,
                                     placement: .attached(anchor(d.surface, d.frac))))
        }
        view = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: start, timeZone: Self.utc)).view
    }

    func step(_ now: Date, commands: [Command] = [], pointer: [PointerEvent] = []) {
        view = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, pointer: pointer,
                                      commands: commands, now: now, timeZone: Self.utc)).view
    }

    func hit(_ p: Point) -> HitTarget? { HitTesting.hitTest(p, regions: view.hitRegions) }
}

/// 比较范围：Plank、Ladder、Item（只取预置的）和 Decor（含 Unlocked_Decor）。
fileprivate struct ObjectState: Equatable, CustomStringConvertible {
    var planks: [PlankID: PlankState]
    var ladders: [LadderID: LadderState]
    var items: [ItemID: Item]
    var decors: [DecorID: Decor]
    var unlocked: Set<DecorType>

    init(_ st: WorldState, items ids: Set<ItemID>) {
        planks = st.planks.planks
        ladders = st.ladders.ladders
        items = st.items.items.filter { ids.contains($0.key) }
        decors = st.decors.decors
        unlocked = st.decors.unlocked
    }

    var description: String {
        "planks \(planks.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue): \($0.value)" }) "
            + "ladders \(ladders.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue): \($0.value)" }) "
            + "items \(items.values.sorted { $0.id < $1.id }.map { "\($0.kind) \($0.placement)" }) "
            + "decors \(decors.values.sorted { $0.id < $1.id }.map { "\($0.id.rawValue) \($0.type) \($0.placement)" }) "
            + "unlocked \(unlocked)"
    }
}

/// 两个副本与共同的时钟。
fileprivate final class Pair {
    static let dt = 1.0 / 30
    let plain: Copy
    let wished: Copy
    let itemIDs: Set<ItemID>
    let windowYs: [Int]
    var now: Date

    init(_ s: InteractionScenario) {
        now = Date(timeIntervalSince1970: 23 * 86400 + Double(s.startHour) * 3600)
        windowYs = s.windowYs
        let windows = s.windowYs.enumerated().map { i, y in
            StoryEngineTests.win(WindowID(i + 1), x: [100, 450, 550][i], y: Double(y), w: [250, 250, 300][i],
                                 h: [200, 120, 200][i])
        }
        let ids = s.items.map { _ in ItemID() }
        itemIDs = Set(ids)
        plain = Copy(s, windows: windows, itemIDs: ids, start: now)
        wished = Copy(s, windows: windows, itemIDs: ids, start: now)
        // 开局之后（Home_Window 已分配）逐帧触发 Wish，再让预置物体和居民稳定几帧。
        for (t, w) in s.wishes {
            step(wishedCommands: [.triggerWish(WishType.allCases[t], [ResidentID.a, .b][w])])
        }
        for _ in 0 ..< 10 { step() }
    }

    func step(plain p: [PointerEvent] = [], wished w: [PointerEvent] = [], wishedCommands: [Command] = []) {
        now = now.addingTimeInterval(Self.dt)
        plain.step(now, pointer: p)
        wished.step(now, commands: wishedCommands, pointer: w)
    }

    /// 两个副本的比较结果；相同时为 nil。
    func mismatch() -> String? {
        let a = ObjectState(plain.engine.state, items: itemIDs)
        let b = ObjectState(wished.engine.state, items: itemIDs)
        guard a != b else { return nil }
        return "no wish: \(a)\nwith \(wished.engine.state.wishes.active.map(\.type)): \(b)"
    }
}

/// 场上可拖动、可点击的物体（按下点取自「无 Wish」副本的命中区域）。
fileprivate func objectRegions(_ view: WorldView) -> [HitRegion] {
    view.hitRegions.filter {
        switch $0.target {
        case .item, .decor, .plank, .ladder: return true
        case .resident, .toolbox: return false
        }
    }
}

fileprivate func point(in r: Rect, _ op: InteractionOp) -> Point {
    Point(x: r.minX + r.width * Double(op.u) / 10, y: r.minY + r.height * Double(op.v) / 10)
}

/// 执行一个操作并推进 `settle` 帧。
fileprivate func run(_ op: InteractionOp, _ pair: Pair) {
    let to = op.target(windowYs: pair.windowYs)
    var start: Point?
    var drag = true
    switch InteractionOp.names[op.kind] {
    case "toolbox":
        let zones: [ToolboxZone] = [.plank, .ladder, .decor(.chair), .decor(.lamp)]
        if let r = ToolboxLayout.zoneFrame(zones[op.index % zones.count], screen: Copy.screen,
                                           unlocked: pair.plain.engine.state.decors.unlocked) {
            start = point(in: r, op)
        }
    case "drag", "click":
        let regions = objectRegions(pair.plain.view)
        if !regions.isEmpty { start = point(in: regions[op.index % regions.count].rect, op) }
        drag = InteractionOp.names[op.kind] == "drag"
    case "poke":
        // 每个副本点击各自的居民（位置可能不同）；点击只让居民反应。
        let id: ResidentID = op.index % 2 == 0 ? .a : .b
        func tap(_ c: Copy) -> [PointerEvent] {
            guard let r = c.view.hitRegions.first(where: { $0.target == .resident(id) })?.rect else { return [] }
            let p = Point(x: r.midX, y: r.midY)
            return c.hit(p) == .resident(id) ? [.down(p)] : []
        }
        let dp = tap(pair.plain), dw = tap(pair.wished)
        pair.step(plain: dp, wished: dw)
        pair.step(plain: dp.map { if case let .down(p) = $0 { return .up(p) } else { return $0 } },
                  wished: dw.map { if case let .down(p) = $0 { return .up(p) } else { return $0 } })
    default:
        break
    }

    if let p = start {
        // 两个副本命中不同对象（一边被居民或 Wish 的花盆挡住）时，这次按下在两边都不发送。
        if pair.plain.hit(p) == pair.wished.hit(p) {
            if drag {
                let n = op.moveFrames
                for f in 0 ..< n {
                    let k = Double(f + 1) / Double(n)
                    let q = Point(x: p.x + (to.x - p.x) * k, y: p.y + (to.y - p.y) * k)
                    var events: [PointerEvent] = f == 0 ? [.down(p)] : []
                    events.append(.moved(q))
                    if f == n - 1 { events.append(.up(q)) }
                    pair.step(plain: events, wished: events)
                }
            } else {
                pair.step(plain: [.down(p)], wished: [.down(p)])
                pair.step(plain: [.up(p)], wished: [.up(p)])
            }
        } else {
            pair.step()
        }
    }
    for _ in 0 ..< op.settle { pair.step() }
}

// MARK: - Property 28 的场景与模拟
//
// 四个窗口（x 100、450、800、1150，宽 250，上沿 y 640，高 150）排成一行，相邻窗口间距 100，可以预置木板；
// 每个窗口可以预置一架从窗沿到 Ground 的梯子；Chair、Lamp 放在 Ground 或窗沿上。居民走路、爬梯加快，
// Wish_Timeout 缩短到 1 至 2.5 秒，让 Wish 在几秒内经常完成或因超时放弃。自然生成 Wish 的概率为 0。
//
// 两个副本使用相同的窗口、物体、随机种子和时钟，相隔 `gap` 帧给 Resident_A、Resident_B 各触发一个
// 非 Flower、非 Chase 的 Wish（chair、lamp 或 visit），两边执行同样的关窗操作；只有「点击」副本点击居民。
// 每一帧检查：
// - 每个副本中，上一帧 active、本帧仍 active 的 Wish 的 Wish_State、Wish_Type、Wisher、Visit_Target 和
//   createdAt 不变（另一个 Wish 结束的那一帧也一样）；本帧结束的 Wish 恰有一条 `wish_fulfilled` 或
//   `wish_dropped` 记录，`dropped` 必须由它自己的超时或场景前提消失解释（不能因为另一个 Wish 结束而被放弃）。
// - 两个副本的居民（不计「?」气泡、跳跃和气泡显示）仍然相同时，两边的 active Wish（ID 与上述字段）完全相同：
//   点击既不改变 Wish，也不使其结束。点击 `idle`、`waiting` 的 Wisher 只显示「?」并原地跳一下，两边的居民保持
//   一致；点击行走中的居民时，按 v1 R7.7 跳跃期间暂停移动，到达时刻因此推后，Wish 可以合理地晚一些完成或先超时。
//   居民一旦不同，此后只推进并检查「点击」副本。

fileprivate struct IndepOp: Sendable, CustomStringConvertible {
    /// 0...2 点击 Resident_A，3...4 点击 Resident_B，5 关闭窗口 `index + 1`（两个副本同时）。
    var kind: Int
    var index: Int
    /// 操作之前推进的帧数。
    var delay: Int

    var description: String {
        switch kind {
        case 0...2: return "+\(delay)f poke a"
        case 3...4: return "+\(delay)f poke b"
        default: return "+\(delay)f close \(index + 1)"
        }
    }
}

fileprivate struct IndependenceScenario: Sendable, CustomStringConvertible {
    static let wishTypes: [WishType] = [.chair, .lamp, .visit]

    /// 位 i：窗口 i + 1 上有梯子到 Ground。
    var ladderMask: Int
    /// 位 i：窗口 i + 1 与 i + 2 之间有木板。
    var plankMask: Int
    /// `surface` 0 为 Ground，1...4 为窗口 1...4 的窗沿。
    var decors: [PreDecor]
    /// 先触发的 Wisher：0 = A、1 = B。
    var firstWisher: Int
    /// 先、后两个 Wish 的类型（`wishTypes` 下标）。
    var types: [Int]
    /// 两次触发相隔的帧数（≥ 1，两个 Wish 的 createdAt 不同）。
    var gap: Int
    /// Wish_Timeout（0.1 秒）。
    var timeoutTenths: Int
    var startHour: Int
    var seed: Int
    var ops: [IndepOp]

    var wishers: [ResidentID] { firstWisher == 0 ? [.a, .b] : [.b, .a] }

    var description: String {
        "hour \(startHour) seed \(seed) ladders \(ladderMask) planks \(plankMask) "
            + "decors \(decors.map { "\($0.isLamp ? "lamp" : "chair")@\($0.surface):\($0.frac)" }) "
            + "wishes \(zip(types, wishers).map { "\(Self.wishTypes[$0.0])/\($0.1)" }) gap \(gap)f "
            + "timeout \(Double(timeoutTenths) / 10)s ops \(ops)"
    }
}

fileprivate var independenceScenarioGen: Generator<IndependenceScenario, some SendableSequenceType> {
    let decor = zip(Gen<Bool>.bool, Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 1...9))
        .map { PreDecor(isLamp: $0, surface: $1, frac: $2) }
    let op = zip(Gen<Int>.int(in: 0...5), Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...15))
        .map { IndepOp(kind: $0, index: $1, delay: $2) }
    let world = zip(Gen<Int>.int(in: 0...15), Gen<Int>.int(in: 0...7), decor.array(of: 0...4))
    let wishes = zip(Gen<Int>.int(in: 0...1), Gen<Int>.int(in: 0...2), Gen<Int>.int(in: 0...2),
                     Gen<Int>.int(in: 1...15), Gen<Int>.int(in: 10...25))
    return zip(world, wishes, Gen<Int>.int(in: 0...23), Gen<Int>.int(in: 0...1_000_000), op.array(of: 1...5))
        .map { w, h, hour, seed, ops in
            IndependenceScenario(ladderMask: w.0, plankMask: w.1, decors: w.2, firstWisher: h.0,
                                 types: [h.1, h.2], gap: h.3, timeoutTenths: h.4, startHour: hour,
                                 seed: seed, ops: ops)
        }
}

/// Property 28 比较的 Wish 字段。
fileprivate struct WishFields: Equatable, CustomStringConvertible {
    var id: WishID
    var type: WishType
    var wisher: ResidentID
    var visitTarget: VisitTarget?
    var createdAt: Date
    var state: WishState

    init(_ w: Wish) {
        id = w.id
        type = w.type
        wisher = w.wisher
        visitTarget = w.visitTarget
        createdAt = w.createdAt
        state = w.state
    }

    var description: String {
        "#\(id.rawValue) \(type)/\(wisher.rawValue) \(state) created \(createdAt.timeIntervalSince1970)"
            + (visitTarget.map { " → window \($0.window)" } ?? "")
    }
}

/// Property 28 的一个副本。
fileprivate final class WishWorld {
    static let screen = StoryEngineTests.screen
    static let frames: [Rect] = (0 ..< 4).map {
        Rect(minX: 100 + Double($0) * 350, minY: 640, width: 250, height: 150)
    }

    let engine: WorldEngine
    var source: FakeWindowSource
    var view: WorldView
    var events: [EventRecord] = []

    init(_ s: IndependenceScenario, start: Date) {
        var c = Tunables()
        c.wishSpawnChance = 0
        c.wishTimeout = Double(s.timeoutTenths) / 10
        c.walkSpeed = 200
        c.climbSpeed = 150
        engine = WorldEngine(constants: c, clockStart: start, screen: Self.screen,
                             rng: RandomSource(seed: UInt64(s.seed)))
        source = FakeWindowSource(snapshots: Self.frames.enumerated().map { i, f in
            StoryEngineTests.win(WindowID(i + 1), x: f.minX, y: f.minY, w: f.width, h: f.height)
        })
        engine.unlockDecor(.chair)
        engine.unlockDecor(.lamp)
        for i in 0 ..< 4 where s.ladderMask & (1 << i) != 0 {
            engine.insertLadder(.placed(PlacedLadder(
                id: LadderID(0), top: PlankEnd(window: WindowID(i + 1), offset: 200),
                bottomSurface: .ground, bottom: Point(x: Self.frames[i].minX + 200, y: Self.screen.groundY))))
        }
        for i in 0 ..< 3 where s.plankMask & (1 << i) != 0 {
            engine.insertPlank(.placed(PlacedPlank(
                id: PlankID(0), endA: PlankEnd(window: WindowID(i + 1), offset: 250),
                endB: PlankEnd(window: WindowID(i + 2), offset: 0))))
        }
        for (i, d) in s.decors.enumerated() {
            let anchor: CoreAttachment = d.surface == 0
                ? .ground(x: 150 + Double(d.frac) * 120)
                : .window(WindowID(d.surface), offset: 24 * Double(d.frac))
            engine.insertDecor(Decor(id: DecorID(UInt64(i + 1)), type: d.isLamp ? .lamp : .chair,
                                     placement: .attached(anchor)))
        }
        view = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: start,
                                      timeZone: Copy.utc)).view
    }

    func step(_ now: Date, commands: [Command], pointer: [PointerEvent] = []) {
        let out = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, pointer: pointer,
                                         commands: commands, now: now, timeZone: Copy.utc))
        view = out.view
        events = out.events
    }

    var fields: [WishFields] { engine.state.wishes.active.map(WishFields.init) }

    /// 本帧结束的 Wish `w` 被设为 dropped 是否有它自己的原因：Wish_Timeout 到时，或场景前提消失
    /// （Visit_Target 关闭或不再有 Window_Ledge；Lamp_Wish 经历过 Night 后 Night 结束）。
    func dropJustified(_ w: Wish) -> Bool {
        if max(engine.lastNow.timeIntervalSince(w.createdAt), 0) >= engine.constants.wishTimeout { return true }
        switch w.type {
        case .visit:
            guard let t = w.visitTarget, source.window(t.window) != nil else { return true }
            return !engine.state.surfaces.contains { $0.id.windowID == t.window }
        case .lamp:
            return w.sawNight
        case .chair, .flower, .chase:
            return false
        }
    }

    /// 本帧的单副本检查；通过时为 nil。
    func check(before: [Wish]) -> String? {
        let after = engine.state.wishes.active
        if let w = after.first(where: { $0.state != .active }) { return "active 列表中有 \(WishFields(w))" }
        if after.count > 2 { return "active Wish 超过 2 个：\(fields)" }
        let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        let ended = before.filter { byID[$0.id] == nil }
        for b in before {
            if let a = byID[b.id] {
                if WishFields(a) != WishFields(b) {
                    return "Wish 字段改变：\(WishFields(b)) → \(WishFields(a))（本帧结束：\(ended.map(WishFields.init))）"
                }
                continue
            }
            let ref = EventRecord.residentRef(b.wisher)
            let dropped = events.filter { $0.type == .wishDropped && $0.actor == ref }.count
            let fulfilled = events.filter { $0.type == .wishFulfilled && $0.actor == ref }.count
            guard dropped + fulfilled == 1 else {
                return "\(WishFields(b)) 结束时有 \(dropped) 条 wish_dropped、\(fulfilled) 条 wish_fulfilled"
            }
            if dropped == 1, !dropJustified(b) {
                return "\(WishFields(b)) 未超时、前提仍在却被设为 dropped（本帧结束：\(ended.map(WishFields.init))）"
            }
        }
        return nil
    }
}

/// 「不点击」与「点击」两个副本。
fileprivate final class WishTwins {
    /// 触发第二个 Wish 之后最多推进的帧数（Wish_Timeout 最长 2.5 秒，即 75 帧）。
    static let frameCap = 77

    let plain: WishWorld
    let poked: WishWorld
    var now: Date
    var frames = 0
    /// 两个副本的居民出现差别之后为 true，不再比较两个副本。
    var diverged = false

    init(_ s: IndependenceScenario) {
        now = Date(timeIntervalSince1970: 23 * 86400 + Double(s.startHour) * 3600)
        plain = WishWorld(s, start: now)
        poked = WishWorld(s, start: now)
    }

    var anyActive: Bool {
        !poked.engine.state.wishes.active.isEmpty || (!diverged && !plain.engine.state.wishes.active.isEmpty)
    }

    /// 推进一帧并检查；通过时为 nil。两个副本分叉后不再推进「不点击」副本。
    func step(commands: [Command] = [], poke: [PointerEvent] = []) -> String? {
        let before = (plain.engine.state.wishes.active, poked.engine.state.wishes.active)
        now = now.addingTimeInterval(1.0 / 30)
        frames += 1
        poked.step(now, commands: commands, pointer: poke)
        if let m = poked.check(before: before.1) { return "点击副本：\(m)" }
        guard !diverged else { return nil }
        plain.step(now, commands: commands)
        if let m = plain.check(before: before.0) { return "不点击副本：\(m)" }
        if Self.residents(plain) != Self.residents(poked) {
            diverged = true
            return nil
        }
        if plain.fields != poked.fields {
            return "点击改变了 Wish：不点击 \(plain.fields)，点击 \(poked.fields)"
        }
        return nil
    }

    /// 居民状态，不计戳居民的「?」气泡、跳跃计时和气泡显示。
    static func residents(_ w: WishWorld) -> [ResidentID: Resident] {
        w.engine.state.residents.mapValues { r in
            var r = r
            r.poke = nil
            r.bubble = nil
            return r
        }
    }

    /// 在点击副本中点击居民 `id`（按下、下一帧松开）。按下点没有命中该居民时只推进两帧。
    func poke(_ id: ResidentID) -> String? {
        guard let r = poked.view.hitRegions.first(where: { $0.target == .resident(id) })?.rect else {
            return step() ?? step()
        }
        let p = Point(x: r.midX, y: r.midY)
        guard HitTesting.hitTest(p, regions: poked.view.hitRegions) == .resident(id) else {
            return step() ?? step()
        }
        return step(poke: [.down(p)]) ?? step(poke: [.up(p)])
    }
}

fileprivate func runIndependence(_ s: IndependenceScenario) -> String? {
    let t = WishTwins(s)
    for _ in 0 ..< 5 { if let m = t.step() { return "开局：\(m)" } }
    let types = s.types.map { IndependenceScenario.wishTypes[$0] }
    if let m = t.step(commands: [.triggerWish(types[0], s.wishers[0])]) { return "触发第一个 Wish：\(m)" }
    for _ in 1 ..< s.gap { if let m = t.step() { return m } }
    if let m = t.step(commands: [.triggerWish(types[1], s.wishers[1])]) { return "触发第二个 Wish：\(m)" }
    t.frames = 0
    for (i, op) in s.ops.enumerated() {
        for _ in 0 ..< op.delay where t.frames < WishTwins.frameCap {
            if let m = t.step() { return "第 \(i) 个操作之前：\(m)" }
        }
        guard t.frames < WishTwins.frameCap, t.anyActive else { break }
        let m: String?
        switch op.kind {
        case 0...2: m = t.poke(.a)
        case 3...4: m = t.poke(.b)
        default:
            t.plain.source.close(WindowID(op.index + 1))
            t.poked.source.close(WindowID(op.index + 1))
            m = t.step()
        }
        if let m { return "第 \(i) 个操作 \(op)：\(m)" }
    }
    while t.anyActive, t.frames < WishTwins.frameCap {
        if let m = t.step() { return "操作之后：\(m)" }
    }
    return nil
}

// MARK: - 属性

struct WishInteractionTests {
    // Feature: V2, Property 27: 玩家操作不受 Wish 影响
    // **Validates: Requirements 10.1**
    @Test func playerOperationsUnaffectedByWishes() async {
        await propertyCheck(count: 100, input: interactionScenarioGen) { s in
            let pair = Pair(s)
            #expect(pair.plain.engine.state.wishes.active.isEmpty)
            #expect(pair.wished.engine.state.wishes.active.count <= 2)
            if let m = pair.mismatch() {
                Issue.record("开局后不同：\(m)")
                return
            }
            for (i, op) in s.ops.enumerated() {
                run(op, pair)
                #expect(pair.plain.engine.state.wishes.active.isEmpty, "无 Wish 副本出现了 active Wish")
                #expect(pair.wished.engine.state.wishes.active.count <= 2)
                if let m = pair.mismatch() {
                    Issue.record("第 \(i) 个操作 \(op) 之后不同：\n\(m)")
                    return
                }
            }
            // 再推进 1 秒，让下落中的物体落定后比较一次。
            for _ in 0 ..< 30 { pair.step() }
            if let m = pair.mismatch() { Issue.record("落定后不同：\n\(m)") }
        }
    }

    // Feature: V2, Property 28: Wish 互相独立且点击不改变 Wish
    // **Validates: Requirements 10.2, 10.3, 10.7**
    @Test func wishesIndependentAndUnchangedByPokes() async {
        await propertyCheck(count: 100, input: independenceScenarioGen) { s in
            if let m = runIndependence(s) { Issue.record("\(m)") }
        }
    }
}
