import Foundation

// WishDirector：Wish 的生成、推进与结束（design.md「Core：Wish 模型与 WishDirector」，任务 7.3）。
//
// 全部为纯函数：输入只有 `WishBook`、`WorldState`、`WishContext` 和注入的 `RandomSource`，返回本帧的
// `WishEvent`（按发生顺序）。由 WorldEngine 按 design.md「每帧更新顺序（V2）」调用（任务 7.4）：
// - 第 9 步 `plan`（居民移动之前）：结束到时的庆祝；Wish_Timeout 与场景前提放弃（不含 flower、chase）；
//   按 Wish_Check_Interval 检查并生成（先 A 后 B）；为 Chair_Wish、Lamp_Wish、Visit_Wish 的 Wisher 写 Goal。
// - 第 10 步 `StoryDirector.update(wishDriven: true)`：只在 Flower_Wish 进行中推进。
// - 第 13 步 `resolve`（居民移动之后，`ctx` 按移动后的位置重建）：Chair 坐下、Lamp 入睡、Visit 到达、
//   Flower_Wish 进入 Done 时完成；没有路线的 Wisher 进入 `waiting`（以 Wish_Bubble 代替「...」）。
// - 菜单命令：`trigger`（Debug 触发，只检查 Requirement 17.2 前提）、`fastForward`（快进）。
//
// 随机数用量固定（Requirement 19.3）：每位通过前置条件的居民 1 次 `nextUnit()` 判定 Wish_Spawn_Chance；
// 抽中后 1 次选类型（候选按 `WishType.allCases` 顺序，取 `Int(u * n)`）；Visit_Wish 再 1 次选窗口
// （候选按窗口 ID 升序）。Debug 触发 Visit_Wish 时只用 1 次选窗口。
//
// Chase_Wish（任务 8.4，Requirement 20 至 22）：生成或触发时进入 `ready`，两人 `hold(face: 对方)`；`plan` 中
// 满 Chase_Ready_Duration 进入 `running`，此后每帧按可达性写两人的 Goal（Chaser `.reach(Runner)` 或
// `.wait(face: Runner)`，Runner `.reachPoint(Flee_Target)` 或 `.hold(face: Chaser)`），Flee_Target 按
// Chase_Replan_Interval 或 `navVersion` 变化重新选择；`resolve` 中先判 `caught` 再判 `escaped`，得出结局后
// 同帧 `fulfilled`，可庆祝者 `celebrating` 加心形气泡。Chase_Wish 不受 Wish_Timeout 和场景前提影响（Requirement 20.6）。
//
// 气泡：Wish_Bubble 的图标由 `wishIcon(for:...)` 给出，由第 14 步的气泡覆盖（任务 7.4）写入 `Bubble`。
// 本文件只负责让 Wisher 在没有路线时进入 `waiting` 并清掉「...」气泡（Requirement 6.13）。

/// WishDirector 的只读输入。由 WorldEngine 每帧构造；`resolve` 应按居民移动之后的位置重建。
public struct WishContext: Sendable {
    public var nav: NavGraph
    /// Nav_Graph 真正重建的次数，供追逐判断「Nav_Graph 发生变化」（任务 8.4）。
    public var navVersion: Int
    /// 各居民当前所在的 Surface 和屏幕 x。下落、悬挂、爬梯或在 Hidden_Window 上的居民不在其中。
    public var locations: [ResidentID: ResidentLocation]
    /// 附着在可见 Surface 上的 Decor 所在的 Surface 和屏幕 x。拖动中、下落中或在 Hidden_Window 上的不在其中。
    public var decorLocations: [DecorID: ResidentLocation]
    /// Home_Window；未分配的居民不在其中。
    public var homes: [ResidentID: WindowID]
    public var isNight: Bool
    public var now: Date
    public var constants: Tunables
    /// 附着在 Hidden_Window 上的居民。
    public var hiddenResidents: Set<ResidentID>

    public init(
        nav: NavGraph, navVersion: Int = 0, locations: [ResidentID: ResidentLocation] = [:],
        decorLocations: [DecorID: ResidentLocation] = [:], homes: [ResidentID: WindowID] = [:],
        isNight: Bool = false, now: Date, constants: Tunables = Tunables(),
        hiddenResidents: Set<ResidentID> = []
    ) {
        self.nav = nav
        self.navVersion = navVersion
        self.locations = locations
        self.decorLocations = decorLocations
        self.homes = homes
        self.isNight = isNight
        self.now = now
        self.constants = constants
        self.hiddenResidents = hiddenResidents
    }

    /// 由世界状态构造：`nav`、`isNight`、Home_Window（`story.homes`）取自 `world`，居民与 Decor 位置按当前
    /// Attachment 求出。
    public init(world: WorldState, now: Date, navVersion: Int = 0, constants: Tunables = Tunables()) {
        let wc = StoryDirector.context(world, constants)
        var locations: [ResidentID: ResidentLocation] = [:]
        var hidden: Set<ResidentID> = []
        for (id, r) in world.residents {
            if StoryDirector.isHidden(r.attachment, world: world) {
                hidden.insert(id)
                continue
            }
            locations[id] = ResidentController.location(of: r, world: wc)
        }
        var decorLocations: [DecorID: ResidentLocation] = [:]
        for (did, d) in world.decors.decors {
            guard case let .attached(a) = d.placement, !StoryDirector.isHidden(a, world: world) else { continue }
            decorLocations[did] = ActivityContext.location(of: a, world: wc)
        }
        let homes = world.story.homes.filter { world.residents[$0.key] != nil }
        self.init(
            nav: world.nav, navVersion: navVersion, locations: locations, decorLocations: decorLocations,
            homes: homes, isNight: world.isNight, now: now, constants: constants, hiddenResidents: hidden)
    }
}

/// Wish_Bubble 的图标（design.md「WorldEngine 编排改动」中 `Bubble.wishIcon(WishIcon)` 的取值）。
public enum WishIcon: Hashable, Sendable {
    case chair, lamp
    /// 小旗，箭头指向 Visit_Flag（Requirement 9.3）。
    case flag(arrow: Facing)
    /// 脚印，只有 Chase_Wish 的 Wisher 显示（Requirement 20.3）。
    case footprints
}

public enum WishDirector {
    /// 两位居民的检查顺序：先 A 后 B（Requirement 20.1）。
    public static let checkOrder: [ResidentID] = [.a, .b]

    // MARK: - 调度

    /// Home_Window 分配完成那一帧调用：第一次检查在满 1 个 Wish_Check_Interval 时进行（Requirement 6.1）。
    public static func startScheduling(_ book: inout WishBook, now: Date, constants c: Tunables) {
        book.nextCheckAt = now.addingTimeInterval(c.wishCheckInterval)
    }

    // MARK: - 生成条件（Requirement 6.2、6.3、8.1、20.1）

    /// 下一次 Flower_Wish 的 Giver：`flowerCount` 为偶数时 A，奇数时 B（Requirement 8.1(b)、8.6）。
    public static func nextFlowerGiver(_ book: WishBook) -> ResidentID {
        StoryDirector.giver(round: book.flowerCount + 1)
    }

    /// 距上一个 Wish 结束已满 Wish_Cooldown；从未参与过 Wish 的居民视为已满足。
    public static func cooledDown(_ r: ResidentID, book: WishBook, now: Date, constants c: Tunables) -> Bool {
        guard let t = book.lastEnded[r] else { return true }
        return now.timeIntervalSince(t) >= c.wishCooldown
    }

    /// Requirement 6.2 的前置条件（不含「至少有一种可生成的 Wish_Type」）：不是 Busy_Resident，不在 `falling`
    /// 或 `hanging`，冷却已满。
    public static func passesPreconditions(
        _ r: ResidentID, book: WishBook, world: WorldState, ctx: WishContext
    ) -> Bool {
        guard let res = world.residents[r], !book.busy.contains(r),
              res.state != .falling, res.state != .hanging else { return false }
        return cooledDown(r, book: book, now: ctx.now, constants: ctx.constants)
    }

    /// 居民 `r` 当前满足生成条件的 Wish_Type，按 `WishType.allCases` 顺序（Requirement 6.3、8.1、20.1）。
    /// 只判定各类型自身的条件，不含 Requirement 6.2 的前置条件。
    public static func eligibleTypes(
        _ r: ResidentID, book: WishBook, world: WorldState, ctx: WishContext
    ) -> [WishType] {
        guard let res = world.residents[r] else { return [] }
        let c = ctx.constants
        let busy = book.busy
        let other = r.other
        let field = ctx.locations[r].map { ctx.nav.horizontalField(from: $0.surface, at: $0.x) }
        func reachable(_ did: DecorID) -> Bool {
            guard let f = field, let loc = ctx.decorLocations[did] else { return false }
            return f.isReachable(loc.surface)
        }
        var out: [WishType] = []

        // flower：两人都不 Busy；是下一次的 Giver；距上次 Done 已满 Round_Interval（从未有过时跳过）。
        if busy.isEmpty, world.residents[other] != nil, nextFlowerGiver(book) == r,
           book.lastFlowerDoneAt.map({ ctx.now.timeIntervalSince($0) >= c.roundInterval }) ?? true {
            out.append(.flower)
        }

        // chair：累了，且不存在一把空闲、有路线可达的 Chair。
        if res.walkDistance >= c.tiredWalkDistance {
            let seats = seats(world)
            let hasFree = world.decors.sortedIDs.contains { did in
                guard let d = world.decors.decors[did], DecorRules.isFreeChair(d, seats: seats) else { return false }
                return reachable(did)
            }
            if !hasFree { out.append(.chair) }
        }

        // lamp：Night，且不存在一盏有路线可达的 Lamp。
        if ctx.isNight {
            let hasLamp = world.decors.sortedIDs.contains { did in
                world.decors.decors[did]?.type == .lamp && reachable(did)
            }
            if !hasLamp { out.append(.lamp) }
        }

        // visit：至少一个 Visit_Target 候选。
        if !visitCandidates(book: book, world: world, ctx: ctx).isEmpty { out.append(.visit) }

        // chase：非 Night；另一位不 Busy、不在 falling / hanging、冷却已满；A 有路线到 B 的 Surface（同一 Surface 视为有）。
        if !ctx.isNight, let o = world.residents[other], !busy.contains(other),
           o.state != .falling, o.state != .hanging,
           cooledDown(other, book: book, now: ctx.now, constants: c),
           let la = ctx.locations[ChaseRules.chaser], let lb = ctx.locations[ChaseRules.runner],
           ctx.nav.horizontalField(from: la.surface, at: la.x).isReachable(lb.surface) {
            out.append(.chase)
        }
        return out
    }

    /// Visit_Target 候选（Requirement 6.3）：可见的 Eligible_Window，不是任何 Home_Window，当前至少有一段
    /// Window_Ledge，且不是另一个 active Visit_Wish 的目标。按窗口 ID 升序。
    public static func visitCandidates(book: WishBook, world: WorldState, ctx: WishContext) -> [VisitTarget] {
        let homes = Set(ctx.homes.values)
        let taken = Set(book.active.compactMap { $0.visitTarget?.window })
        let withLedge = Set(world.surfaces.compactMap(\.id.windowID))
        return world.windows.visibleSnapshots
            .filter { !homes.contains($0.id) && !taken.contains($0.id) && withLedge.contains($0.id) }
            .sorted { $0.id < $1.id }
            .map { VisitTarget(window: $0.id, ownerName: $0.ownerName) }
    }

    // MARK: - plan（居民移动之前）

    /// 移动之前推进全部 Wish。返回本帧事件（按发生顺序）。
    public static func plan(
        _ book: inout WishBook, world: inout WorldState, ctx: WishContext, rng: inout RandomSource
    ) -> [WishEvent] {
        var events: [WishEvent] = []
        let now = ctx.now
        let c = ctx.constants

        endCelebrations(&book, world: &world, now: now)

        // 1. Wish_Timeout 与场景前提（Requirement 6.11、6.12；flower、chase 不适用，Requirement 8.5、20.6）。
        for wish in book.active {
            guard wish.type != .flower, wish.type != .chase else { continue }
            var w = wish
            if w.type == .lamp, ctx.isNight { w.sawNight = true }
            let timedOut = max(now.timeIntervalSince(w.createdAt), 0) >= c.wishTimeout
            if timedOut || premiseGone(w, world: world, ctx: ctx) {
                events.append(drop(w, book: &book, world: &world, now: now))
            } else if w != wish {
                replace(w, in: &book)
            }
        }

        // 2. 检查与生成（Requirement 6.1、6.2、6.4 至 6.6、20.1）。
        if let next = book.nextCheckAt, now >= next {
            var after = next.addingTimeInterval(c.wishCheckInterval)
            if after <= now { after = now.addingTimeInterval(c.wishCheckInterval) }
            book.nextCheckAt = after
            for r in checkOrder {
                guard passesPreconditions(r, book: book, world: world, ctx: ctx) else { continue }
                let types = eligibleTypes(r, book: book, world: world, ctx: ctx)
                guard !types.isEmpty else { continue }
                guard rng.nextUnit() < c.wishSpawnChance else { continue }
                let type = types[pick(types.count, rng: &rng)]
                var target: VisitTarget?
                if type == .visit {
                    let candidates = visitCandidates(book: book, world: world, ctx: ctx)
                    target = candidates[pick(candidates.count, rng: &rng)]
                }
                events += start(type, wisher: r, visitTarget: target, book: &book, world: &world, ctx: ctx)
            }
        }

        // 3. 为 Chair_Wish、Lamp_Wish、Visit_Wish 的 Wisher 写 Goal（含本帧新生成的）。
        for wish in book.active {
            var w = wish
            switch w.type {
            case .chair, .lamp: advanceDecorWish(&w, world: &world, ctx: ctx)
            case .visit: advanceVisitWish(w, world: &world)
            case .chase: advanceChase(&w, world: &world, ctx: ctx)
            case .flower: continue
            }
            if w != wish { replace(w, in: &book) }
        }
        return events
    }

    /// 场景前提消失（Requirement 6.12）：Visit_Target 关闭或不再有 Window_Ledge（隐藏不算）；Lamp_Wish 进行中
    /// Night 结束（经历过 Night 之后）。
    static func premiseGone(_ w: Wish, world: WorldState, ctx: WishContext) -> Bool {
        switch w.type {
        case .visit:
            guard let t = w.visitTarget, world.windows.records[t.window] != nil else { return true }
            if world.windows.isHidden(t.window) { return false }
            return !world.surfaces.contains { $0.id.windowID == t.window }
        case .lamp:
            return w.sawNight && !ctx.isNight
        case .chair, .flower, .chase:
            return false
        }
    }

    /// Chair_Wish、Lamp_Wish：校验已选目标，失效时清除（Requirement 7.7）；没有目标时选择（Requirement 7.2、7.5）；
    /// 写 Goal。前往途中不受 Activity_Reach_Timeout 约束（Requirement 7.8）。
    static func advanceDecorWish(_ w: inout Wish, world: inout WorldState, ctx: WishContext) {
        guard var r = world.residents[w.wisher] else { return }
        let type: DecorType = w.type == .chair ? .chair : .lamp
        let me = ctx.locations[w.wisher]
        let seats = seats(world)

        if let t = w.decorTarget, !isValidTarget(t, type: type, wisher: w.wisher, from: me, world: world,
                                                 seats: seats, ctx: ctx) {
            w.decorTarget = nil
            halt(&r)
        }
        if w.decorTarget == nil, let me {
            w.decorTarget = selectDecorTarget(
                type, for: w.wisher, from: me, decors: world.decors, decorLocations: ctx.decorLocations,
                seats: seats, nav: ctx.nav)
        }
        if let t = w.decorTarget, let loc = ctx.decorLocations[t] {
            let within = type == .chair ? ctx.constants.giftReachDistance : ctx.constants.lampRange
            setGoal(&r, .reachPoint(loc.surface, x: loc.x, arriveWithin: within))
        } else if let me {
            // 没有目标：与任何该类型 Decor 之间都没有路线时 `wait`（停在原地、`waiting`、无「...」），否则 `hold`
            // （`idle`）。移动阶段与 `resolve` 给出相同状态，每次进入等待只写一条 `waiting_started`
            // （Requirement 7.1、7.4、6.13）。
            let waiting = !anyReachable(type, from: me, world: world, ctx: ctx)
            setGoal(&r, waiting ? .wait(face: nil) : .hold(face: nil))
        } else if r.goal != .wait(face: nil) {
            // 无法定位（下落、悬挂、爬梯或在 Hidden_Window 上）：保留等待，否则停下；能定位后重新判定。
            setGoal(&r, .hold(face: nil))
        }
        r.routeMetric = .horizontal
        world.residents[w.wisher] = r
    }

    /// Visit_Wish：Goal 为 `reachWindow(target)`，水平度量（Requirement 9.4）。目标隐藏时自然等待（Requirement 9.7）。
    static func advanceVisitWish(_ w: Wish, world: inout WorldState) {
        guard var r = world.residents[w.wisher], let t = w.visitTarget else { return }
        setGoal(&r, .reachWindow(t.window))
        r.routeMetric = .horizontal
        world.residents[w.wisher] = r
    }

    /// 从 `me` 出发是否有路线可达任何一件放在可见 Surface 上的 `type` 类型 Decor（不论 Chair 是否被占用，
    /// Requirement 7.1、7.4 的 `waiting` 判定）。
    static func anyReachable(
        _ type: DecorType, from me: ResidentLocation, world: WorldState, ctx: WishContext
    ) -> Bool {
        let field = ctx.nav.horizontalField(from: me.surface, at: me.x)
        return world.decors.sortedIDs.contains { did in
            guard world.decors.decors[did]?.type == type, let loc = ctx.decorLocations[did] else { return false }
            return field.isReachable(loc.surface)
        }
    }

    /// 已选目标是否仍有效：Decor 存在、类型一致、放在可见 Surface 上；Chair 未被他人占用；Wisher 能定位时仍有路线。
    static func isValidTarget(
        _ t: DecorID, type: DecorType, wisher: ResidentID, from me: ResidentLocation?, world: WorldState,
        seats: [ResidentID: DecorID], ctx: WishContext
    ) -> Bool {
        guard let d = world.decors.decors[t], d.type == type, case .attached = d.placement,
              let loc = ctx.decorLocations[t] else { return false }
        if type == .chair, seats.contains(where: { $0.key != wisher && $0.value == t }) { return false }
        if let me, !ctx.nav.horizontalField(from: me.surface, at: me.x).isReachable(loc.surface) { return false }
        return true
    }

    /// Decor 目标选择（Requirement 7.2、7.5）：可选对象中水平路线总长度最小者，并列时 `placedSeq` 最小，仍并列时
    /// ID 最小。可选对象为放在可见 Surface 上（在 `decorLocations` 中）、有路线可达的该类型 Decor；Chair 还要求
    /// 未被占用。没有可选对象时返回 nil。
    public static func selectDecorTarget(
        _ type: DecorType, for wisher: ResidentID, from me: ResidentLocation, decors: DecorStore,
        decorLocations: [DecorID: ResidentLocation], seats: [ResidentID: DecorID], nav: NavGraph
    ) -> DecorID? {
        let field = nav.horizontalField(from: me.surface, at: me.x)
        var best: (id: DecorID, length: Double, seq: UInt64)?
        for did in decors.sortedIDs {
            guard let d = decors.decors[did], d.type == type, case .attached = d.placement,
                  let loc = decorLocations[did] else { continue }
            if type == .chair, seats.contains(where: { $0.key != wisher && $0.value == did }) { continue }
            guard let length = field.length(to: loc.surface, x: loc.x) else { continue }
            if let b = best, length > b.length || (length == b.length && d.placedSeq >= b.seq) { continue }
            best = (did, length, d.placedSeq)
        }
        return best?.id
    }

    // MARK: - resolve（居民移动之后）

    /// 移动之后推进到达与完成。`ctx` 应按移动之后的位置构造。返回本帧事件（按发生顺序）。
    public static func resolve(_ book: inout WishBook, world: inout WorldState, ctx: WishContext) -> [WishEvent] {
        var events: [WishEvent] = []
        for wish in book.active {
            var w = wish
            switch w.type {
            case .flower:
                events += resolveFlower(w, book: &book, world: &world, ctx: ctx)
                continue
            case .chair, .lamp:
                events += resolveDecorWish(&w, book: &book, world: &world, ctx: ctx)
            case .visit:
                events += resolveVisitWish(w, book: &book, world: &world, ctx: ctx)
            case .chase:
                events += resolveChase(&w, book: &book, world: &world, ctx: ctx)
            }
            if book.active.contains(where: { $0.id == w.id }), w != wish { replace(w, in: &book) }
        }
        return events
    }

    /// Flower_Wish：Story_Stage 进入 `Done` 的那次更新中完成，`lastFlowerDoneAt = doneAt`，然后清 `stage`
    /// （Requirement 8.4）。v1 进入 Done 时的 `celebrating` 即 Requirement 6.10 的庆祝，到时由 `plan` 转回 `idle`。
    static func resolveFlower(
        _ w: Wish, book: inout WishBook, world: inout WorldState, ctx: WishContext
    ) -> [WishEvent] {
        guard world.story.stage == .done else { return [] }
        let doneAt = world.story.doneAt ?? ctx.now
        book.lastFlowerDoneAt = doneAt
        let remaining = max(StoryDirector.celebrateDuration - world.story.celebrateElapsed, 0)
        for id in checkOrder where world.residents[id]?.state == .celebrating {
            book.celebrations[id] = ctx.now.addingTimeInterval(remaining)
        }
        world.story.stage = nil
        for id in checkOrder where world.residents[id] != nil {
            setGoal(&world.residents[id]!, .hold(face: nil))
        }
        return [fulfill(w, outcome: nil, book: &book, world: &world, now: ctx.now)]
    }

    /// Chair_Wish、Lamp_Wish 的到达与完成（Requirement 7.3、7.6），以及没有目标时的 `waiting` / `idle`
    /// （Requirement 7.1、7.4、6.13）。
    static func resolveDecorWish(
        _ w: inout Wish, book: inout WishBook, world: inout WorldState, ctx: WishContext
    ) -> [WishEvent] {
        guard var r = world.residents[w.wisher] else { return [] }
        let c = ctx.constants
        let type: DecorType = w.type == .chair ? .chair : .lamp
        let me = ctx.locations[w.wisher]

        guard let t = w.decorTarget else {
            // 没有目标：与任何该类型 Decor 之间都没有路线时 waiting，否则 idle（Requirement 7.1、7.4）。
            // Goal 与 `plan` 的判定一致，下一帧的移动阶段不会把状态改回 idle。
            if let me {
                let waiting = !anyReachable(type, from: me, world: world, ctx: ctx)
                setWaiting(&r, waiting)
                setGoal(&r, waiting ? .wait(face: nil) : .hold(face: nil))
            }
            world.residents[w.wisher] = r
            return []
        }

        // 前往途中路线消失（ResidentController 进入 waiting）：清除目标，回到等待行为（Requirement 7.7）。
        // 仍没有可达的该类型 Decor 时保持 `waiting`（不重复写 `waiting_started`），Wish_Bubble 代替「...」。
        if r.state == .waiting {
            w.decorTarget = nil
            if let me, !anyReachable(type, from: me, world: world, ctx: ctx) {
                r.route = nil
                setWaiting(&r, true)
                setGoal(&r, .wait(face: nil))
            } else {
                halt(&r)
                setGoal(&r, .hold(face: nil))
            }
            world.residents[w.wisher] = r
            return []
        }

        let within = type == .chair ? c.giftReachDistance : c.lampRange
        guard r.traversal == nil, r.state != .falling, r.state != .hanging, r.state != .climbing,
              let me, let loc = ctx.decorLocations[t], loc.surface == me.surface, abs(loc.x - me.x) <= within,
              let d = world.decors.decors[t], d.type == type, case .attached = d.placement else { return [] }

        let seats = seats(world)
        if type == .chair, seats.contains(where: { $0.key != w.wisher && $0.value == t }) {
            // 到达前被占用（Requirement 7.7）。
            w.decorTarget = nil
            halt(&r)
            setGoal(&r, .hold(face: nil))
            world.residents[w.wisher] = r
            return []
        }

        ResidentController.stop(&r)
        setGoal(&r, .hold(face: nil))
        r.routeMetric = .standard
        let activityEvent: ActivityEvent
        if type == .chair {
            // 坐下（与 rest 相同）：x 设为 Chair 的 x，sitting，占用 Chair；Activity 视为 rest（Requirement 7.3）。
            ResidentController.setX(&r, loc.x, world: StoryDirector.context(world, c))
            r.state = .sitting
            r.seat = t
            world.activities[w.wisher] = Activity(
                kind: .rest, target: .chair(t), startedAt: ctx.now,
                phase: .sitting(until: ctx.now.addingTimeInterval(c.sitDuration)))
            activityEvent = .sat(w.wisher, t)
        } else {
            // 入睡；Activity 视为 sleep，之后按 Requirement 5.7、5.8 醒来（Requirement 7.6）。
            r.state = .sleeping
            world.activities[w.wisher] = Activity(
                kind: .sleep, target: .lamp(t), startedAt: ctx.now, phase: .sleeping)
            activityEvent = .slept(w.wisher, t)
        }
        if r.bubble == .dots { r.bubble = nil }
        world.residents[w.wisher] = r
        // sat / slept 在 wish_fulfilled 之前；不庆祝（Requirement 7.3、7.6、18.2）。
        return [.activity(activityEvent), fulfill(w, outcome: nil, book: &book, world: &world, now: ctx.now)]
    }

    /// Visit_Wish：Wisher 站在 Visit_Target 任一段 Window_Ledge 上且不在 falling / hanging 时完成，先写 `visited`
    /// 再 `fulfilled`，Wisher 庆祝（Requirement 9.6、6.10）。否则没有路线（含目标隐藏）时 `waiting`
    /// （Requirement 9.5、9.7、6.13）。
    static func resolveVisitWish(
        _ w: Wish, book: inout WishBook, world: inout WorldState, ctx: WishContext
    ) -> [WishEvent] {
        guard var r = world.residents[w.wisher], let t = w.visitTarget else { return [] }
        let me = ctx.locations[w.wisher]
        if let me, me.surface.windowID == t.window, r.traversal == nil,
           r.state != .falling, r.state != .hanging, r.state != .climbing {
            ResidentController.stop(&r)
            setGoal(&r, .hold(face: nil))
            r.routeMetric = .standard
            r.state = .celebrating
            if r.bubble == .dots { r.bubble = nil }
            world.residents[w.wisher] = r
            book.celebrations[w.wisher] = ctx.now.addingTimeInterval(StoryDirector.celebrateDuration)
            return [
                .visitedWindow(w.wisher, ownerName: t.ownerName),
                fulfill(w, outcome: nil, book: &book, world: &world, now: ctx.now),
            ]
        }
        if let me {
            let unreachable: Bool
            if world.windows.isHidden(t.window) {
                unreachable = true
            } else {
                let field = ctx.nav.horizontalField(from: me.surface, at: me.x)
                unreachable = !ctx.nav.nodes.keys.contains { $0.windowID == t.window && field.isReachable($0) }
            }
            if unreachable { setWaiting(&r, true) }
        }
        world.residents[w.wisher] = r
        return []
    }

    // MARK: - Chase_Wish（Requirement 20 至 22）

    /// `plan` 中推进 Chase_Wish：`ready` 期间两人 `hold(face: 对方)`；满 Chase_Ready_Duration 的那次更新进入
    /// `running`（记录追逐开始时间，设置速度倍数与水平度量），并在同一次更新中按 `planRunning` 写 Goal
    /// （Requirement 20.3、20.4、20.8）。`now - readyAt` 为负（时钟回拨）时不提前进入 `running`。
    static func advanceChase(_ w: inout Wish, world: inout WorldState, ctx: WishContext) {
        guard var chase = w.chase else { return }
        let c = ctx.constants
        if chase.phase == .ready {
            guard ctx.now.timeIntervalSince(chase.readyAt) >= c.chaseReadyDuration else {
                for id in checkOrder where world.residents[id] != nil {
                    setGoal(&world.residents[id]!, .hold(face: .resident(id.other)))
                }
                return
            }
            chase.phase = .running
            chase.runningAt = ctx.now
        }
        planRunning(&chase, world: &world, ctx: ctx)
        w.chase = chase
    }

    /// `running` 阶段每帧写两人的 Goal（Requirement 21.1 至 21.6、21.9 至 21.11）：
    ///
    /// - 任一人附着在 Hidden_Window 上：视为不可达（Requirement 21.10），隐藏的一方由 WorldEngine 暂停移动；
    /// - 任一人下落、悬挂或爬梯（没有位置）且不在 Hidden_Window 上：保持两人现有 Goal，落地后按 Goal 继续
    ///   （Requirement 21.9）；
    /// - 可达：Chaser `.reach(Runner)`；Runner 在需要时重新选择 Flee_Target（尚无目标、距上次满
    ///   Chase_Replan_Interval、`navVersion` 变化），未到达时 `.reachPoint(目标, arriveWithin: 1)`，已到达或没有
    ///   候选点时 `.hold(face: Chaser)`；
    /// - 不可达：Chaser `.wait(face: Runner)`（`waiting`、无气泡，Requirement 21.3），Runner `.hold(face: Chaser)`
    ///   （`idle`，Requirement 21.6），清除 Flee_Target，路线重新出现的那一帧重新选点。
    static func planRunning(_ chase: inout ChaseState, world: inout WorldState, ctx: WishContext) {
        let a = ChaseRules.chaser, b = ChaseRules.runner
        guard var ra = world.residents[a], var rb = world.residents[b] else { return }
        let c = ctx.constants
        ra.speedFactor = c.chaserSpeedFactor
        rb.speedFactor = c.runnerSpeedFactor
        ra.routeMetric = .horizontal
        rb.routeMetric = .horizontal
        defer {
            world.residents[a] = ra
            world.residents[b] = rb
        }

        let hidden = ctx.hiddenResidents.contains(a) || ctx.hiddenResidents.contains(b)
        let la = ctx.locations[a], lb = ctx.locations[b]
        if !hidden, la == nil || lb == nil { return }

        guard !hidden, let la, let lb else {
            unreachable(&chase, chaser: &ra, runner: &rb)
            return
        }
        let chaserField = ctx.nav.horizontalField(from: la.surface, at: la.x)
        guard chaserField.isReachable(lb.surface) else {
            unreachable(&chase, chaser: &ra, runner: &rb)
            return
        }

        setGoal(&ra, .reach(b))
        let elapsed = chase.lastReplanAt.map { ctx.now.timeIntervalSince($0) }
        let due = chase.fleeTarget == nil || elapsed == nil || elapsed! < 0
            || elapsed! >= c.chaseReplanInterval || ctx.navVersion != chase.lastNavVersion
        guard due else { return }
        let runnerField = ctx.nav.horizontalField(from: lb.surface, at: lb.x)
        let candidates = ChaseRules.candidates(
            runnerField: runnerField, surfaces: world.surfaces, inset: c.fleeEdgeInset)
        let target = ChaseRules.selectFleeTarget(candidates, chaserField: chaserField, runnerField: runnerField)
        chase.fleeTarget = target
        chase.lastReplanAt = ctx.now
        chase.lastNavVersion = ctx.navVersion
        if let t = target, !atFleeTarget(lb, t) {
            setGoal(&rb, .reachPoint(t.surface, x: t.x, arriveWithin: fleeArriveWithin))
        } else {
            setGoal(&rb, .hold(face: .resident(a)))
        }
    }

    /// Runner 到达 Flee_Target 的距离（pt，Requirement 21.11）。
    static let fleeArriveWithin = 1.0

    /// Runner 站在 Flee_Target 所在 Surface 上，且与其 x 之差不超过 1pt（Requirement 21.11）。
    static func atFleeTarget(_ loc: ResidentLocation, _ t: FleePoint) -> Bool {
        loc.surface == t.surface && abs(loc.x - t.x) <= fleeArriveWithin
    }

    /// Chaser 没有路线可达 Runner（含任一人在 Hidden_Window 上）：Chaser `waiting`、Runner `idle`，两人面朝对方。
    private static func unreachable(_ chase: inout ChaseState, chaser: inout Resident, runner: inout Resident) {
        setGoal(&chaser, .wait(face: .resident(ChaseRules.runner)))
        setGoal(&runner, .hold(face: .resident(ChaseRules.chaser)))
        chase.fleeTarget = nil
    }

    /// `resolve` 中判定 Chase_Outcome（居民移动之后，Requirement 22.1、22.2）：只在 `running` 时判定，先判
    /// `caught`，否则满 Chase_Duration 时 `escaped`。没有结局时，Runner 刚到达 Flee_Target 的那一帧转为
    /// `hold(face: Chaser)` 并面朝 Chaser（Requirement 21.11）。
    static func resolveChase(
        _ w: inout Wish, book: inout WishBook, world: inout WorldState, ctx: WishContext
    ) -> [WishEvent] {
        guard var chase = w.chase, chase.phase == .running, let runningAt = chase.runningAt,
              let ra = world.residents[ChaseRules.chaser], let rb = world.residents[ChaseRules.runner]
        else { return [] }
        let c = ctx.constants
        let la = ctx.locations[ChaseRules.chaser], lb = ctx.locations[ChaseRules.runner]
        let outcome: ChaseOutcome?
        if ChaseRules.isCaught(chaser: la, runner: lb, chaserState: ra.state, runnerState: rb.state,
                               hidden: ctx.hiddenResidents, distance: c.catchDistance) {
            outcome = .caught
        } else if ctx.now.timeIntervalSince(runningAt) >= c.chaseDuration {
            outcome = .escaped
        } else {
            outcome = nil
        }
        guard let outcome else {
            if let t = chase.fleeTarget, let lb, atFleeTarget(lb, t),
               case .reachPoint = rb.goal, var runner = world.residents[ChaseRules.runner] {
                setGoal(&runner, .hold(face: .resident(ChaseRules.chaser)))
                if let la {
                    if la.x < lb.x { runner.facing = .left } else if la.x > lb.x { runner.facing = .right }
                }
                world.residents[ChaseRules.runner] = runner
            }
            return []
        }
        chase.fleeTarget = nil
        w.chase = chase
        return [finishChase(w, outcome: outcome, book: &book, world: &world, ctx: ctx)]
    }

    /// 得出 Chase_Outcome（Requirement 22.3、22.4）：同帧 `fulfilled`（两人 `lastEnded = now`、结束 Busy 身份）；
    /// 两人恢复速度与度量、离开 `running` 和 `waiting`、Goal 改为 `hold(face: nil)`（Activity_Planner 随后接管）。
    /// 不在 `falling`、`hanging`、`climbing` 且不在 Hidden_Window 上的居民同帧停下，播放 `celebrating` 并显示心形
    /// 气泡；进行中的小跳或往下跳立即完成。两种结局的处理完全相同，只有事件中的 Chase_Outcome 不同。
    static func finishChase(
        _ w: Wish, outcome: ChaseOutcome, book: inout WishBook, world: inout WorldState, ctx: WishContext
    ) -> WishEvent {
        let event = fulfill(w, outcome: outcome, book: &book, world: &world, now: ctx.now)
        let wc = StoryDirector.context(world, ctx.constants)
        let airborne: Set<ResidentState> = [.falling, .hanging, .climbing]
        for id in checkOrder {
            guard var r = world.residents[id] else { continue }
            r.speedFactor = 1
            r.routeMetric = .standard
            let hidden = ctx.hiddenResidents.contains(id)
            if !hidden, !airborne.contains(r.state), let t = r.traversal, t.kind != .climb {
                ResidentController.advanceTraversal(&r, world: wc, dt: max(t.duration - t.elapsed, 0) + 1)
            }
            halt(&r)
            setGoal(&r, .hold(face: nil))
            if !hidden, !airborne.contains(r.state), r.traversal == nil {
                r.state = .celebrating
                r.bubble = .heart
                book.celebrations[id] = ctx.now.addingTimeInterval(StoryDirector.celebrateDuration)
                book.celebrationHearts.insert(id)
            }
            world.residents[id] = r
        }
        return event
    }

    // MARK: - Debug 触发（Requirement 17.2、17.3）

    /// Debug_Menu「触发心愿」。跳过 Wish_Cooldown、Wish_Spawn_Chance、Walk_Distance、Night、Round_Interval，
    /// 只检查 Requirement 17.2 的前提；不满足时返回空事件、不改任何状态。
    ///
    /// - flower：`wisher` 被忽略，取下一次的 Giver；要求两位居民都不是 Busy_Resident。
    /// - chair、lamp：要求 `wisher` 不是 Busy_Resident。
    /// - visit：要求 `wisher` 不是 Busy_Resident 且存在 Visit_Target 候选；用 1 次随机数选窗口。
    /// - chase：要求两位居民都不是 Busy_Resident，且都不在 `falling`、`hanging`（不检查路线）。
    /// - 除 flower 外 `wisher` 为 nil 时不生成。所涉及的居民必须都存在。
    public static func trigger(
        _ type: WishType, wisher: ResidentID?, book: inout WishBook, world: inout WorldState,
        ctx: WishContext, rng: inout RandomSource
    ) -> [WishEvent] {
        let busy = book.busy
        let r: ResidentID
        if type == .flower {
            r = nextFlowerGiver(book)
        } else {
            guard let wisher else { return [] }
            r = wisher
        }
        guard world.residents[r] != nil, !busy.contains(r) else { return [] }
        var target: VisitTarget?
        switch type {
        case .flower:
            guard busy.isEmpty, world.residents[r.other] != nil else { return [] }
        case .chair, .lamp:
            break
        case .visit:
            let candidates = visitCandidates(book: book, world: world, ctx: ctx)
            guard !candidates.isEmpty else { return [] }
            target = candidates[pick(candidates.count, rng: &rng)]
        case .chase:
            guard busy.isEmpty else { return [] }
            for id in checkOrder {
                guard let res = world.residents[id], res.state != .falling, res.state != .hanging else { return [] }
            }
        }
        return start(type, wisher: r, visitTarget: target, book: &book, world: &world, ctx: ctx)
    }

    // MARK: - 快进（Requirement 8.8 至 8.10）

    /// Debug_Menu「快进」：
    /// - 存在 active Flower_Wish 且 Story_Stage 为 `Growing`：按 v1 让 Story_Flower 进入下一个 Growth_Stage；
    /// - 否则若没有 active Flower_Wish、有过 Flower_Wish 进入 Done 且未满 Round_Interval：把 `lastFlowerDoneAt`
    ///   设为 `now - Round_Interval`，立即结束等待；Wish_Check_Interval、Wish_Cooldown、Wish_Spawn_Chance 不变；
    /// - 其余情况不改任何状态。
    @discardableResult
    public static func fastForward(
        _ book: inout WishBook, world: inout WorldState, constants c: Tunables, now: Date
    ) -> [StoryEvent] {
        let flowerActive = book.active.contains { $0.type == .flower }
        if flowerActive {
            guard world.story.stage == .growing else { return [] }
            var story = world.story
            let events = StoryDirector.fastForward(&story, world: &world, constants: c, now: now)
            world.story = story
            return events
        }
        if let done = book.lastFlowerDoneAt, now.timeIntervalSince(done) < c.roundInterval {
            // Date 加减有浮点舍入，`now - (now - R)` 可能比 R 小一个 ulp；逐 ulp 前移直到条件 (c) 成立（最多几步）。
            var t = now.addingTimeInterval(-c.roundInterval)
            while now.timeIntervalSince(t) < c.roundInterval {
                t = Date(timeIntervalSinceReferenceDate: t.timeIntervalSinceReferenceDate.nextDown)
            }
            book.lastFlowerDoneAt = t
        }
        return []
    }

    // MARK: - 气泡图标（Requirement 6.9、7.1、7.4、9.3、20.3）

    /// 居民 `resident` 因 Wish 应显示的 Wish_Bubble 图标；不显示时为 nil。
    ///
    /// - flower：按 v1 R16.2 由 StoryDirector 管理，这里返回 nil；
    /// - chase：只有 Wisher 显示脚印；
    /// - visit：`flagX` 小于 `residentX` 时箭头朝左，其余（含任一为 nil）朝右。
    public static func wishIcon(
        for wish: Wish, resident: ResidentID, residentX: Double?, flagX: Double?
    ) -> WishIcon? {
        guard wish.wisher == resident else { return nil }
        switch wish.type {
        case .flower: return nil
        case .chair: return .chair
        case .lamp: return .lamp
        case .chase: return .footprints
        case .visit:
            if let fx = flagX, let rx = residentX, fx < rx { return .flag(arrow: .left) }
            return .flag(arrow: .right)
        }
    }

    /// Visit_Flag 的 x：窗口当前最长一段 Window_Ledge 的中点（长度相等取 `SurfaceID` 较小者）。没有窗沿时为 nil。
    public static func visitFlagX(window: WindowID, surfaces: [Surface]) -> Double? {
        visitFlagPoint(window: window, surfaces: surfaces)?.x
    }

    /// Visit_Flag 的位置：窗口当前最长一段 Window_Ledge 的中点（底边中点，渲染层画在其上方）。没有窗沿时为 nil。
    public static func visitFlagPoint(window: WindowID, surfaces: [Surface]) -> Point? {
        var best: Surface?
        for s in surfaces.sorted(by: { $0.id < $1.id }) where s.id.windowID == window {
            if best == nil || s.end.x - s.start.x > best!.end.x - best!.start.x { best = s }
        }
        guard let s = best else { return nil }
        let x = (s.start.x + s.end.x) / 2
        return Point(x: x, y: s.y(atX: x))
    }

    // MARK: - 生成与结束

    /// 生成一个 active Wish（Requirement 6.8）。chair、lamp 必要时解锁并在 `started` 之后写 `decorUnlocked`
    /// （Requirement 1.2 至 1.4、18.2）；flower `flowerCount += 1` 并开始送花（Requirement 8.2）；chase 进入 ready，
    /// 两人停下对望（Requirement 20.2、20.3）；其余 Wisher 停下（Requirement 7.1、7.4）。
    static func start(
        _ type: WishType, wisher r: ResidentID, visitTarget: VisitTarget?, book: inout WishBook,
        world: inout WorldState, ctx: WishContext
    ) -> [WishEvent] {
        let now = ctx.now
        var wish = Wish(id: book.makeID(), type: type, wisher: r, createdAt: now, visitTarget: visitTarget)
        switch type {
        case .lamp:
            wish.sawNight = ctx.isNight
        case .chase:
            wish.chase = ChaseState(phase: .ready, readyAt: now, lastNavVersion: ctx.navVersion)
        default:
            break
        }
        book.active.append(wish)
        book.active.sort { $0.id < $1.id }
        for id in wish.participants {
            book.celebrations[id] = nil
            let hadHeart = book.celebrationHearts.remove(id) != nil
            guard var res = world.residents[id] else { continue }
            if res.state == .celebrating { res.state = .idle }
            if hadHeart, res.bubble == .heart { res.bubble = nil }
            world.residents[id] = res
        }

        var events: [WishEvent] = [.started(wish)]
        switch type {
        case .chair, .lamp:
            let decor: DecorType = type == .chair ? .chair : .lamp
            if world.decors.unlock(decor) { events.append(.decorUnlocked(decor)) }
            stopForWish(r, goal: .hold(face: nil), world: &world)
        case .visit:
            stopForWish(r, goal: .hold(face: nil), world: &world)
        case .flower:
            book.flowerCount += 1
            var story = world.story
            let storyEvents = StoryDirector.beginFlowerWish(
                &story, round: book.flowerCount, world: &world, constants: ctx.constants, now: now)
            world.story = story
            events += storyEvents.map { .story($0) }
        case .chase:
            for id in checkOrder {
                stopForWish(id, goal: .hold(face: .resident(id.other)), world: &world)
                world.residents[id]?.speedFactor = 1
            }
        }
        return events
    }

    /// 放弃（Requirement 6.11、10.5）：移除 Wish，`lastEnded[wisher] = now`，Wisher 转 `idle`、Goal `hold`。
    /// 不改 Decor、Unlocked_Decor 和任何计数。
    static func drop(_ w: Wish, book: inout WishBook, world: inout WorldState, now: Date) -> WishEvent {
        var ended = w
        ended.state = .dropped
        book.active.removeAll { $0.id == w.id }
        book.lastEnded[w.wisher] = now
        if var r = world.residents[w.wisher] {
            halt(&r)
            setGoal(&r, .hold(face: nil))
            r.routeMetric = .standard
            world.residents[w.wisher] = r
        }
        return .dropped(ended)
    }

    /// 完成（Requirement 6.10）：移除 Wish，全部参与者 `lastEnded = now`。庆祝由调用方处理。
    static func fulfill(
        _ w: Wish, outcome: ChaseOutcome?, book: inout WishBook, world: inout WorldState, now: Date
    ) -> WishEvent {
        var ended = w
        ended.state = .fulfilled
        book.active.removeAll { $0.id == w.id }
        for id in w.participants {
            book.lastEnded[id] = now
            world.residents[id]?.routeMetric = .standard
        }
        return .fulfilled(ended, outcome)
    }

    /// 庆祝到时：仍在 `celebrating` 的居民转 `idle`；已离开 `celebrating`（例如下落）的记录直接移除。
    static func endCelebrations(_ book: inout WishBook, world: inout WorldState, now: Date) {
        for (id, until) in book.celebrations.sorted(by: { $0.key < $1.key }) {
            let celebrating = world.residents[id]?.state == .celebrating
            if celebrating, now < until { continue }
            if celebrating {
                world.residents[id]?.state = .idle
                world.residents[id]?.wander.pauseRemaining = ResidentController.wanderPauseRange.lowerBound
            }
            book.celebrations[id] = nil
            // 心形气泡与 `celebrating` 同一帧结束（Requirement 22.3）。
            if book.celebrationHearts.remove(id) != nil, world.residents[id]?.bubble == .heart {
                world.residents[id]?.bubble = nil
            }
        }
        book.celebrationHearts.formIntersection(book.celebrations.keys)
    }

    // MARK: - 辅助

    /// 用 `u ∈ [0, 1)` 在 `n` 个候选中等概率取一个下标（Requirement 6.5、6.6、9.1）。
    static func pick(_ n: Int, rng: inout RandomSource) -> Int {
        min(Int(rng.nextUnit() * Double(n)), max(n - 1, 0))
    }

    /// 当前坐着的居民与 Chair。
    static func seats(_ world: WorldState) -> [ResidentID: DecorID] {
        world.residents.compactMapValues(\.seat)
    }

    static func replace(_ w: Wish, in book: inout WishBook) {
        guard let i = book.active.firstIndex(where: { $0.id == w.id }) else { return }
        book.active[i] = w
    }

    /// 只在 Goal 变化时写入，避免打断现有路线。
    static func setGoal(_ r: inout Resident, _ g: Goal) {
        if r.goal != g { r.goal = g }
    }

    /// 停止水平移动：清路线，离开 waiting，行走中的状态转 `idle`。动作（小跳、往下跳、爬梯）、下落、悬挂、
    /// 坐着、睡着不受影响。
    static func halt(_ r: inout Resident) {
        if r.state == .waiting { ResidentController.leaveWaiting(&r) }
        r.route = nil
        guard r.traversal == nil else { return }
        switch r.state {
        case .walking, .carrying, .running: r.state = .idle
        default: break
        }
    }

    /// Wish 开始时让居民停下并写 Goal。
    static func stopForWish(_ id: ResidentID, goal: Goal, world: inout WorldState) {
        guard var r = world.residents[id] else { return }
        halt(&r)
        setGoal(&r, goal)
        world.residents[id] = r
    }

    /// Requirement 6.13：没有路线时进入 `waiting`，以 Wish_Bubble 代替「...」；有路线时离开 `waiting`。
    /// 只作用于站在 Surface 上、没有进行中动作的 `idle`、`walking`、`carrying`、`running`、`waiting` 居民。
    static func setWaiting(_ r: inout Resident, _ waiting: Bool) {
        guard r.traversal == nil else { return }
        switch r.state {
        case .idle, .walking, .carrying, .running, .waiting: break
        default: return
        }
        if waiting {
            if r.state != .waiting {
                r.state = .waiting
                r.route = nil
            }
            if r.bubble == .dots { r.bubble = nil }
        } else if r.state == .waiting {
            ResidentController.leaveWaiting(&r)
        }
    }
}
