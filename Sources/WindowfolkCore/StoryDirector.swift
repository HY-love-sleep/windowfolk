import Foundation

// 送花剧情状态机（design.md「Core：StoryDirector」与剧情状态图，任务 13.3；Requirement 15 至 20）。
//
// `update` 在每帧居民移动之前调用（由 WorldEngine 接入，任务 13.5）：
// 1. 推进全部已种下花的生长阶段（Requirement 17.1、17.3、17.4）；
// 2. 按当前阶段推进剧情：开局、Wish → Waiting / Travel、送达 → Planting → Growing → Bloomed → ReturnGift → Done → 下一轮；
// 3. 按最终阶段给两位居民分配 Goal：送礼方 `reach(对方)`，另一方 `confined`；未开局时两人 `none`。
//
// 寻路、等待、搬运、掉落都由 ResidentController 按 Goal 执行；StoryDirector 只读取居民位置和通路图判定阶段。
// 居民下落、悬挂、窗口隐藏期间无法定位，此时阶段保持不变（Requirement 20.1、20.3）。
// 快进与重新开始剧情（任务 13.4）见 `fastForward`、`restart`，分别复用 `startRound`、`tryBegin`。
//
// V2（任务 7.2）：开局与轮次调度拆为 `assignHomes`（只分配家并落位）和 `beginFlowerWish`（由 WishDirector 在
// Flower_Wish 开始时调用）；`update(wishDriven: true)` 不再自动开局和开新一轮。v1 路径（`wishDriven: false`，默认）
// 保留到 WorldEngine 切换（任务 7.4）。

public enum StoryDirector {
    /// `celebrating` 动画完整播放一次的时长（秒），之后转为 `idle`（Requirement 18.8）。
    public static let celebrateDuration = 1.2
    /// 种下后心形气泡的显示时长（秒，Requirement 16.12）。
    public static let heartBubbleDuration = 2.0

    // MARK: - 角色

    /// 第 n 轮的 Giver：奇数轮为 Resident_A，偶数轮为 Resident_B（Requirement 19.5）。
    public static func giver(round: Int) -> ResidentID {
        abs(round) % 2 == 1 ? .a : .b
    }

    /// 第 n 轮的 Receiver。
    public static func receiver(round: Int) -> ResidentID {
        giver(round: round).other
    }

    // MARK: - 家的选择（Requirement 15.1 至 15.3）

    /// 从窗口中选出两个 Home_Window。
    ///
    /// 候选为面积 ≥ minSize² 且在 `ledges` 中至少有一段 Window_Ledge 的窗口。在所有无序对中取水平中心距离最大者；
    /// 并列时取 zIndex 之和最小者（最靠前）；仍并列时按窗口 ID 字典序。中心 x 较小的窗口归 Resident_A
    /// （中心 x 相同时取 ID 较小者）。候选少于两个时返回 nil。
    public static func selectHomes(
        windows: [WindowSnapshot], ledges: [Surface], minSize: Double
    ) -> (a: WindowID, b: WindowID)? {
        let withLedge = Set(ledges.compactMap(\.id.windowID))
        let candidates = windows
            .filter { $0.frame.width * $0.frame.height >= minSize * minSize && withLedge.contains($0.id) }
            .sorted { $0.id < $1.id }
        guard candidates.count >= 2 else { return nil }

        var best: (d: Double, z: Int, lo: WindowID, hi: WindowID, p: WindowSnapshot, q: WindowSnapshot)?
        for i in 0 ..< candidates.count {
            for j in (i + 1) ..< candidates.count {
                let p = candidates[i], q = candidates[j]
                let d = abs(p.frame.midX - q.frame.midX)
                let z = p.zIndex + q.zIndex
                let lo = min(p.id, q.id), hi = max(p.id, q.id)
                if let b = best {
                    if d < b.d { continue }
                    if d == b.d {
                        if z > b.z { continue }
                        if z == b.z, (lo, hi) >= (b.lo, b.hi) { continue }
                    }
                }
                best = (d, z, lo, hi, p, q)
            }
        }
        guard let b = best else { return nil }
        let (p, q) = (b.p, b.q)
        if p.frame.midX < q.frame.midX || (p.frame.midX == q.frame.midX && p.id < q.id) {
            return (p.id, q.id)
        }
        return (q.id, p.id)
    }

    /// 窗口最长一段 Window_Ledge 水平中点的 Attachment（Requirement 15.4）。长度相等时取 `SurfaceID` 较小的一段。
    public static func homeAttachment(window: WindowID, world: WorldState) -> Attachment? {
        guard let snap = world.windows.visibleSnapshot(window) else { return nil }
        let own = world.surfaces.filter { $0.id.windowID == window }.sorted { $0.id < $1.id }
        guard var longest = own.first else { return nil }
        for s in own.dropFirst() where s.end.x - s.start.x > longest.end.x - longest.start.x {
            longest = s
        }
        let mid = (longest.start.x + longest.end.x) / 2
        return .window(window, offset: mid - snap.frame.minX)
    }

    // MARK: - 每帧更新

    /// 推进一帧剧情。`world.nav` 应为本帧居民移动之前重建好的通路图。返回本帧的剧情事件（按发生顺序）。
    ///
    /// `wishDriven` 选择轮次调度方式（V2 design.md「StoryDirector 改动」，任务 7.2）：
    /// - `false`（v1）：未开局时调用 `tryBegin` 开局，`Done` 满 Round_Interval 后自动开始下一轮；
    /// - `true`（V2，由 WishDirector 驱动）：只在 `stage != nil` 时推进阶段，不再开局；`Done` 只记录 `doneAt`
    ///   并播放庆祝，不开新一轮；Goal 只在 `stage != nil` 时写入。Home_Window 由 `assignHomes` 分配，
    ///   新一轮由 `beginFlowerWish` 开始。两种方式下已种下的花都照常生长、心形气泡照常倒计时。
    @discardableResult
    public static func update(
        _ s: inout StoryState, world: inout WorldState, constants c: Tunables, now: Date, dt: Double,
        wishDriven: Bool = false
    ) -> [StoryEvent] {
        let dt = dt.isFinite ? max(dt, 0) : 0
        var events = advanceGrowth(world: &world, now: now, bloomDuration: c.bloomDuration)
        tickHeart(&s, world: &world, dt: dt)

        switch s.stage {
        case nil:
            if !wishDriven { events += tryBegin(&s, world: &world, constants: c, now: now) }
        case .wish?, .waiting?, .travel?:
            events += syncReachability(&s, world: &world, constants: c)
            if s.stage == .travel { events += checkFlowerDelivery(&s, world: &world, constants: c) }
        case .planting?:
            events += updatePlanting(&s, world: &world, constants: c, now: now, dt: dt)
        case .growing?:
            let flower = s.currentFlower.flatMap { world.items[$0] }
            if flower == nil || flower?.growth?.reached == .bloom {
                events += enterBloomed(&s, world: &world)
            }
        case .bloomed?:
            events += enterBloomed(&s, world: &world)
        case .returnGift?:
            events += checkFruitDelivery(&s, world: &world, constants: c, now: now)
        case .done?:
            events += updateDone(&s, world: &world, constants: c, now: now, dt: dt, autoNextRound: !wishDriven)
        }

        assignGoals(s, world: &world, wishDriven: wishDriven)
        return events
    }

    // MARK: 生长

    /// 推进场上全部已种下花的生长阶段，返回 `sprouted` / `bloomed` 事件（Requirement 17.1、17.3、17.4）。
    /// 生长与花所在位置无关。
    @discardableResult
    public static func advanceGrowth(world: inout WorldState, now: Date, bloomDuration: Double) -> [StoryEvent] {
        var events: [StoryEvent] = []
        for id in world.items.sortedIDs {
            guard var item = world.items[id], var g = item.growth, g.plantedAt != nil else { continue }
            let before = g.reached
            guard let reached = Growth.advance(&g, now: now, bloomDuration: bloomDuration) else { continue }
            item.growth = g
            world.items[id] = item
            if before < .sprout, reached >= .sprout { events.append(.sprouted(flower: id)) }
            if reached == .bloom { events.append(.bloomed(flower: id)) }
        }
        return events
    }

    // MARK: 开局（Requirement 15）

    /// 未开局时尝试开局：有两个合格窗口时分配家、放好两人并开始当前轮（Requirement 15.1 至 15.5、15.7）；
    /// 否则把两人放在 Ground 上闲逛（只放一次，Requirement 15.6）。
    @discardableResult
    public static func tryBegin(
        _ s: inout StoryState, world: inout WorldState, constants c: Tunables, now: Date
    ) -> [StoryEvent] {
        guard assignHomes(&s, world: &world, constants: c, placeResidents: true) else { return [] }
        return startRound(&s, round: s.round, world: &world, constants: c)
    }

    /// 只分配 Home_Window，不开始送花（V2 Requirement 6.1；v1 R15.1 至 15.4、15.7）。返回是否分配成功。
    ///
    /// - 成功：写入 `s.homes`；`placeResidents` 为 true 时把两人放到各自家的最长窗沿中点（v1 R15.4），
    ///   并清除 `groundPlaced`；为 false 时（恢复存档后）不移动居民。
    /// - 失败：`s.homes` 不变；`placeResidents` 为 true 时把两人放在 Ground 上闲逛，只放一次（v1 R15.6）。
    ///
    /// 不改变 `stage`、`round` 和任何物件。
    @discardableResult
    public static func assignHomes(
        _ s: inout StoryState, world: inout WorldState, constants c: Tunables, placeResidents: Bool
    ) -> Bool {
        if let homes = selectHomes(
            windows: world.windows.visibleSnapshots, ledges: world.surfaces, minSize: c.minWindowSize),
           let aAt = homeAttachment(window: homes.a, world: world),
           let bAt = homeAttachment(window: homes.b, world: world) {
            s.homes = [.a: homes.a, .b: homes.b]
            if placeResidents {
                s.groundPlaced = false
                place(.a, at: aAt, world: &world)
                place(.b, at: bAt, world: &world)
            }
            return true
        }
        if placeResidents, !s.groundPlaced {
            let ground = world.surfaces.first { $0.id == .ground } ?? SurfaceBuilder.ground(screen: world.screen)
            let w = ground.end.x - ground.start.x
            place(.a, at: .ground(x: ground.start.x + w / 3), world: &world)
            place(.b, at: .ground(x: ground.start.x + w * 2 / 3), world: &world)
            s.groundPlaced = true
        }
        return false
    }

    /// Flower_Wish 变为 active 时调用（V2 Requirement 8.2、8.6）：以 `round`（= 已开始过的 Flower_Wish 次数，
    /// 含本次）为 Story_Round 开始送花，阶段进入 `Wish`，Giver 按 `giver(round:)`（奇数 A、偶数 B），
    /// 同一次调用按可达性进入 `Travel` 或 `Waiting`。之前各轮的花和果子不受影响。
    @discardableResult
    public static func beginFlowerWish(
        _ s: inout StoryState, round: Int, world: inout WorldState, constants c: Tunables, now: Date
    ) -> [StoryEvent] {
        startRound(&s, round: round, world: &world, constants: c)
    }

    /// 开始第 `round` 轮：Giver 持有一个 `pot` 阶段的新 Story_Flower，阶段设为 `Wish` 并显示许愿气泡，
    /// 同一帧按可达性进入 `Travel` 或 `Waiting`（Requirement 16.1 至 16.4、19.1、19.2）。
    /// 之前各轮的 Story_Flower 和 Fruit 不受影响（Requirement 19.3）。
    @discardableResult
    public static func startRound(
        _ s: inout StoryState, round: Int, world: inout WorldState, constants c: Tunables
    ) -> [StoryEvent] {
        let previous = s.stage
        s.round = max(round, 1)
        s.stage = .wish
        s.currentFruit = nil
        s.plantingElapsed = 0
        s.doneAt = nil
        s.celebrateElapsed = 0
        let g = s.giver, r = s.receiver

        for id in [g, r] {
            guard var res = world.residents[id] else { continue }
            if res.state == .celebrating || res.state == .planting { res.state = .idle }
            world.residents[id] = res
        }
        let flower = Item.flowerPot(storyRound: s.round, placement: .held(g))
        s.currentFlower = forceGive(flower, to: g, world: &world) ? flower.id : nil
        world.residents[g]?.bubble = .wish(receiver: r)

        var events: [StoryEvent] = [
            .stageChanged(from: previous, to: .wish),
            .roundStarted(round: s.round, giver: g, receiver: r),
        ]
        assignGoals(s, world: &world)
        events += syncReachability(&s, world: &world, constants: c)
        return events
    }

    // MARK: Wish / Waiting / Travel（Requirement 16.3 至 16.9）

    /// Giver 能定位（不在下落、悬挂、隐藏窗口或梯子上）且 Receiver 能定位时，
    /// 按通路图中 Giver 所在 Surface 到 Receiver 所在 Surface 是否可达，把阶段设为 `Travel` 或 `Waiting`。
    static func syncReachability(_ s: inout StoryState, world: inout WorldState, constants c: Tunables) -> [StoryEvent] {
        guard let stage = s.stage, stage == .wish || stage == .waiting || stage == .travel else { return [] }
        let ctx = context(world, c)
        guard let gr = world.residents[s.giver], gr.state != .falling, gr.state != .hanging,
              let gl = location(s.giver, world: world, ctx: ctx),
              let rl = location(s.receiver, world: world, ctx: ctx) else { return [] }
        let next: StoryStage = world.nav.isReachable(from: gl.surface, to: rl.surface) ? .travel : .waiting
        guard next != stage else { return [] }
        if stage == .wish, world.residents[s.giver]?.bubble == .wish(receiver: s.receiver) {
            world.residents[s.giver]?.bubble = nil
        }
        s.stage = next
        return [.stageChanged(from: stage, to: next)]
    }

    /// 送达判定：两人站在同一 Surface，屏幕 x 差 ≤ Gift_Reach_Distance，送礼方不在下落、悬挂、爬梯或跳跃中。
    static func canDeliver(
        carrier: ResidentID, to other: ResidentID, world: WorldState, constants c: Tunables
    ) -> (carrier: ResidentLocation, other: ResidentLocation)? {
        guard let cr = world.residents[carrier], cr.traversal == nil,
              cr.state != .falling, cr.state != .hanging, cr.state != .climbing,
              let or = world.residents[other], or.state != .falling, or.state != .hanging else { return nil }
        let ctx = context(world, c)
        guard let cl = location(carrier, world: world, ctx: ctx),
              let ol = location(other, world: world, ctx: ctx),
              cl.surface == ol.surface, abs(cl.x - ol.x) <= c.giftReachDistance else { return nil }
        return (cl, ol)
    }

    /// `Travel` 中送达时进入 `Planting`：两人停下，状态设为 `planting`（Requirement 16.9、16.10）。
    static func checkFlowerDelivery(_ s: inout StoryState, world: inout WorldState, constants c: Tunables) -> [StoryEvent] {
        guard let (gl, rl) = canDeliver(carrier: s.giver, to: s.receiver, world: world, constants: c) else { return [] }
        s.stage = .planting
        s.plantingElapsed = 0
        for (id, facingRight) in [(s.giver, rl.x >= gl.x), (s.receiver, gl.x >= rl.x)] {
            guard var r = world.residents[id] else { continue }
            r.state = .planting
            r.route = nil
            r.traversal = nil
            if r.bubble == .dots || r.bubble == .wish(receiver: s.receiver) { r.bubble = nil }
            r.wander.groundCenter = nil
            r.wander.groundPatrolling = false
            if gl.x != rl.x { r.facing = facingRight ? .right : .left }
            world.residents[id] = r
        }
        return [.stageChanged(from: .travel, to: .planting)]
    }

    // MARK: Planting（Requirement 16.10 至 16.14、19.4、20.5）

    static func updatePlanting(
        _ s: inout StoryState, world: inout WorldState, constants c: Tunables, now: Date, dt: Double
    ) -> [StoryEvent] {
        let ids = [s.giver, s.receiver]
        let interrupted = ids.contains { id in
            guard let r = world.residents[id] else { return true }
            return r.state != .planting
        }
        if interrupted {
            // 任一方悬挂或下落（或已不在种花状态）：中止动画，不记录种下时间，花仍在 Giver 手上，回到 Travel。
            for id in ids where world.residents[id]?.state == .planting {
                world.residents[id]?.state = .idle
            }
            s.stage = .travel
            s.plantingElapsed = 0
            return [.stageChanged(from: .planting, to: .travel)]
        }
        // 任一方所在窗口隐藏时暂停计时，重新显示后从暂停处继续。
        if ids.contains(where: { id in world.residents[id].map { isHidden($0.attachment, world: world) } ?? true }) {
            return []
        }
        s.plantingElapsed += dt
        guard s.plantingElapsed >= c.plantAnimationDuration else { return [] }
        return completePlanting(&s, world: &world, constants: c, now: now)
    }

    /// 动画结束：花附着在 Receiver 所在 Surface 上 Receiver 的 x 处，记录种下时间，进入 `Growing`，
    /// 两人显示心形气泡；超过 Max_Story_Flowers 时移除最早种下的一朵（Requirement 16.11、16.12、19.4）。
    static func completePlanting(
        _ s: inout StoryState, world: inout WorldState, constants c: Tunables, now: Date
    ) -> [StoryEvent] {
        let g = s.giver, r = s.receiver
        let ctx = context(world, c)
        guard let rl = location(r, world: world, ctx: ctx),
              let surface = ctx.surface(rl.surface),
              let at = AttachmentResolver.attachment(landingOn: surface, atX: rl.x, windows: world.windows),
              var giverRes = world.residents[g] else { return [] }

        let flowerID: ItemID
        if let held = giverRes.heldItem, world.items[held]?.kind.isFlower == true {
            world.items.release(from: &giverRes, to: .attached(at))
            flowerID = held
        } else {
            let fresh = Item.flowerPot(storyRound: s.round, placement: .attached(at))
            world.items[fresh.id] = fresh
            flowerID = fresh.id
        }
        world.items[flowerID]?.kind = .flower(storyRound: s.round)
        world.items[flowerID]?.growth = FlowerGrowth(plantedAt: now, reached: .pot)
        world.residents[g] = giverRes
        s.currentFlower = flowerID
        s.stage = .growing
        s.plantingElapsed = 0
        s.heartRemaining = heartBubbleDuration
        for id in [g, r] {
            guard var res = world.residents[id] else { continue }
            res.state = .idle
            res.bubble = .heart
            res.wander.pauseRemaining = ResidentController.wanderPauseRange.lowerBound
            world.residents[id] = res
        }

        var events: [StoryEvent] = [
            .planted(flower: flowerID, giver: g, receiver: r),
            .stageChanged(from: .planting, to: .growing),
        ]
        events += evictFlowers(world: &world, max: c.maxStoryFlowers)
        return events
    }

    /// 已种下的 Story_Flower 超过上限时移除种下时间最早的（同时间按 ID），直到等于上限（Requirement 19.4）。
    /// 上限至少为 1，刚种下的花不会被移除。
    @discardableResult
    public static func evictFlowers(world: inout WorldState, max limit: Int) -> [StoryEvent] {
        let planted = world.items.items.values
            .filter { $0.kind.isStoryFlower && $0.growth?.plantedAt != nil }
            .sorted { a, b in
                let ta = a.growth!.plantedAt!, tb = b.growth!.plantedAt!
                return ta != tb ? ta < tb : a.id < b.id
            }
        let excess = planted.count - Swift.max(limit, 1)
        guard excess > 0 else { return [] }
        var events: [StoryEvent] = []
        for item in planted.prefix(excess) {
            world.items[item.id] = nil
            for rid in world.residents.keys.sorted() where world.residents[rid]?.heldItem == item.id {
                world.residents[rid]?.heldItem = nil
            }
            events.append(.flowerEvicted(flower: item.id))
        }
        return events
    }

    // MARK: Bloomed / ReturnGift / Done（Requirement 17.2、18、19.1）

    /// 进入 `Bloomed`，同一次更新中 Receiver 持有一个新 Fruit 并进入 `ReturnGift`（Requirement 17.2、18.1、18.2）。
    static func enterBloomed(_ s: inout StoryState, world: inout WorldState) -> [StoryEvent] {
        var events: [StoryEvent] = []
        if s.stage != .bloomed {
            events.append(.stageChanged(from: s.stage, to: .bloomed))
            s.stage = .bloomed
        }
        let fruit = Item.fruit(placement: .held(s.receiver))
        s.currentFruit = forceGive(fruit, to: s.receiver, world: &world) ? fruit.id : nil
        s.stage = .returnGift
        events.append(.stageChanged(from: .bloomed, to: .returnGift))
        return events
    }

    /// `ReturnGift` 中 Receiver 送达时，Fruit 附着在 Giver 所在 Surface 上 Giver 的 x 处，进入 `Done`，
    /// 两人进入 `celebrating`（Requirement 18.7、18.8）。
    static func checkFruitDelivery(
        _ s: inout StoryState, world: inout WorldState, constants c: Tunables, now: Date
    ) -> [StoryEvent] {
        let g = s.giver, r = s.receiver
        guard let (_, gl) = canDeliver(carrier: r, to: g, world: world, constants: c),
              let surface = context(world, c).surface(gl.surface),
              let at = AttachmentResolver.attachment(landingOn: surface, atX: gl.x, windows: world.windows),
              var carrier = world.residents[r] else { return [] }

        let fruitID: ItemID
        if let held = carrier.heldItem, world.items[held]?.kind == .fruit {
            world.items.release(from: &carrier, to: .attached(at))
            fruitID = held
        } else {
            let fresh = Item.fruit(placement: .attached(at))
            world.items[fresh.id] = fresh
            fruitID = fresh.id
        }
        world.residents[r] = carrier
        s.currentFruit = fruitID
        s.stage = .done
        s.doneAt = now
        s.celebrateElapsed = 0
        for id in [g, r] {
            guard var res = world.residents[id] else { continue }
            res.state = .celebrating
            res.route = nil
            res.traversal = nil
            if res.bubble == .dots { res.bubble = nil }
            res.wander.groundCenter = nil
            res.wander.groundPatrolling = false
            world.residents[id] = res
        }
        return [.giftDelivered(fruit: fruitID, from: r, to: g), .stageChanged(from: .returnGift, to: .done)]
    }

    /// `Done`：`celebrating` 播放一次后转 `idle`；`autoNextRound`（v1）时进入 `Done` 满 Round_Interval 后
    /// 开始下一轮并互换角色（Requirement 18.8、19.1、19.2），否则（V2）不开新一轮，由 WishDirector 调度。
    /// `doneAt` 缺失时以当前时间补上。
    static func updateDone(
        _ s: inout StoryState, world: inout WorldState, constants c: Tunables, now: Date, dt: Double,
        autoNextRound: Bool = true
    ) -> [StoryEvent] {
        s.celebrateElapsed += dt
        if s.celebrateElapsed >= celebrateDuration {
            for id in [s.giver, s.receiver] where world.residents[id]?.state == .celebrating {
                world.residents[id]?.state = .idle
                world.residents[id]?.wander.pauseRemaining = ResidentController.wanderPauseRange.lowerBound
            }
        }
        guard let doneAt = s.doneAt else {
            s.doneAt = now
            return []
        }
        guard autoNextRound, now.timeIntervalSince(doneAt) >= c.roundInterval else { return [] }
        return startRound(&s, round: s.round + 1, world: &world, constants: c)
    }

    // MARK: - 快进与重新开始剧情（任务 13.4；Requirement 17.5 至 17.7、20.6、26.6、26.7）

    /// 调试菜单「快进」。只改数据不改时钟（design.md「快进改数据而不改时钟」）：
    /// - `Growing`：当前轮 Story_Flower 进入恰好下一个 Growth_Stage（`Growth.fastForward` 前移 `plantedAt`），
    ///   返回 `sprouted` / `bloomed` 事件；进入 `bloom` 后由下一次 `update` 按正常路径进入 `Bloomed`（Requirement 17.2、17.5）；
    /// - `Done`：把 `doneAt` 前移 Round_Interval，使等待立即结束，并按正常的下一轮路径（`startRound`）开始下一轮
    ///   （Requirement 17.6、19.1）；
    /// - 其他阶段（含未开局）：不改变任何花的阶段和 Story_Stage（Requirement 17.7）。
    @discardableResult
    public static func fastForward(
        _ s: inout StoryState, world: inout WorldState, constants c: Tunables, now: Date
    ) -> [StoryEvent] {
        switch s.stage {
        case .growing?:
            guard let id = s.currentFlower, var item = world.items[id], var g = item.growth,
                  g.plantedAt != nil else { return [] }
            let before = g.reached
            Growth.fastForward(&g, now: now, bloomDuration: c.bloomDuration)
            item.growth = g
            world.items[id] = item
            guard g.reached > before else { return [] }
            return [g.reached == .bloom ? .bloomed(flower: id) : .sprouted(flower: id)]
        case .done?:
            // 时钟回拨时 doneAt 可能晚于 now，先取较早者，保证前移后已等待时长 ≥ Round_Interval。
            let base = min(s.doneAt ?? now, now)
            s.doneAt = base.addingTimeInterval(-c.roundInterval)
            let events = startRound(&s, round: s.round + 1, world: &world, constants: c)
            assignGoals(s, world: &world)
            return events
        default:
            return []
        }
    }

    /// 调试菜单「重新开始剧情」（Requirement 20.6）：
    /// 删除场上全部 Flower 和 Fruit（窗沿上、Ground 上、下落中、拖动中和居民持有的），保留全部 Plank 和 Ladder；
    /// 剧情状态整体重置为未开局、第 1 轮、无家，随后在同一次调用中按当前窗口执行开局（Requirement 15.1 至 15.7）。
    /// 结果与调用前的 Story_Stage 无关。
    @discardableResult
    public static func restart(
        _ s: inout StoryState, world: inout WorldState, constants c: Tunables, now: Date
    ) -> [StoryEvent] {
        clear(&s, world: &world)
        let events = tryBegin(&s, world: &world, constants: c, now: now)
        assignGoals(s, world: &world)
        return events
    }

    /// `restart` 的清理部分（V2「重置世界」复用，任务 7.4）：删除场上全部 Flower 和 Fruit（窗沿上、Ground 上、
    /// 下落中、拖动中和居民持有的），保留全部 Plank 和 Ladder；`planting`、`celebrating` 的居民转 `idle`，
    /// 清除全部气泡；剧情状态整体重置为未开局、第 1 轮、无家。不开局、不分配家。
    public static func clear(_ s: inout StoryState, world: inout WorldState) {
        let removed = Set(world.items.items.keys)
        world.items.items.removeAll()
        for id in world.residents.keys.sorted() {
            guard var r = world.residents[id] else { continue }
            if let held = r.heldItem, removed.contains(held) { r.heldItem = nil }
            if r.state == .planting || r.state == .celebrating { r.state = .idle }
            r.bubble = nil
            world.residents[id] = r
        }
        // 正在拖动或按下的物件已被删除：吞掉本次手势余下的事件。
        switch world.gesture {
        case let .dragging(.item(iid), _, _) where removed.contains(iid):
            world.gesture = .swallowed
        case let .pressed(.item(iid), _) where removed.contains(iid):
            world.gesture = .swallowed
        default:
            break
        }
        s = StoryState()
    }

    // MARK: - Goal 分配

    /// 按阶段分配 Goal（design.md「目标分配」）。只在 Goal 变化时写入，避免打断现有路线。
    /// `wishDriven`（V2）时 `stage == nil` 不写任何 Goal：没有 Flower_Wish 时居民的 Goal 归 Activity_Planner。
    public static func assignGoals(_ s: StoryState, world: inout WorldState, wishDriven: Bool = false) {
        let g = s.giver, r = s.receiver
        let goals: [ResidentID: Goal]
        switch s.stage {
        case nil:
            if wishDriven { return }
            goals = [.a: .none, .b: .none]
        case .wish?, .waiting?, .travel?, .planting?:
            goals = [g: .reach(r), r: .confined]
        case .returnGift?:
            goals = [r: .reach(g), g: .confined]
        case .growing?, .bloomed?, .done?:
            goals = [g: .confined, r: .confined]
        }
        for (id, goal) in goals where world.residents[id] != nil && world.residents[id]?.goal != goal {
            world.residents[id]?.goal = goal
        }
    }

    // MARK: - 辅助

    /// 心形气泡倒计时，到时清除。
    static func tickHeart(_ s: inout StoryState, world: inout WorldState, dt: Double) {
        guard s.heartRemaining > 0 else { return }
        s.heartRemaining -= dt
        guard s.heartRemaining <= 0 else { return }
        s.heartRemaining = 0
        for id in world.residents.keys.sorted() where world.residents[id]?.bubble == .heart {
            world.residents[id]?.bubble = nil
        }
    }

    /// 把居民放到 `attachment` 处并重置为 `idle`；居民不存在时新建。保留持有物和戳状态。
    static func place(_ id: ResidentID, at attachment: Attachment, world: inout WorldState) {
        var r = world.residents[id] ?? Resident(id: id, attachment: attachment)
        r.state = .idle
        r.attachment = attachment
        r.facing = id == .a ? .right : .left
        r.goal = .none
        r.route = nil
        r.traversal = nil
        r.fall = nil
        r.hangElapsed = 0
        r.bubble = nil
        r.wander = WanderState()
        world.residents[id] = r
    }

    /// 让居民持有 `item`。居民已持有其他物件时，先让那件物件从居民当前位置下落。
    @discardableResult
    static func forceGive(_ item: Item, to id: ResidentID, world: inout WorldState) -> Bool {
        guard var r = world.residents[id] else { return false }
        if r.heldItem != nil {
            let p = AttachmentResolver.screenPosition(
                r.attachment, windows: world.windows, planks: world.planks.lookup(windows: world.windows),
                ladders: world.ladders.lookup(windows: world.windows), screen: world.screen)
                ?? Point(x: world.screen.frame.midX, y: world.screen.frame.minY)
            let held = ItemHolding.heldPosition(residentPosition: p)
            world.items.release(from: &r, to: .falling(Physics.startFall(at: held, screen: world.screen)))
        }
        let ok = world.items.give(item, to: &r)
        world.residents[id] = r
        return ok
    }

    /// 由世界状态构造 ResidentController 使用的只读上下文。
    static func context(_ world: WorldState, _ c: Tunables) -> WorldContext {
        WorldContext(
            windows: world.windows, surfaces: world.surfaces, screen: world.screen, constants: c,
            nav: world.nav, ladders: world.ladders.lookup(windows: world.windows))
    }

    /// 居民当前所在的 Surface 和 x；下落、悬挂、在隐藏窗口或梯子上时为 nil。
    static func location(_ id: ResidentID, world: WorldState, ctx: WorldContext) -> ResidentLocation? {
        guard let r = world.residents[id], !isHidden(r.attachment, world: world) else { return nil }
        return ResidentController.location(of: r, world: ctx)
    }

    /// Attachment 指向 Hidden_Window：窗口隐藏；木板任一端窗口隐藏；梯子上端窗口隐藏。
    public static func isHidden(_ a: Attachment, world: WorldState) -> Bool {
        switch a {
        case let .window(wid, _):
            return world.windows.isHidden(wid)
        case let .plank(pid, _):
            guard let p = world.planks.planks[pid]?.placed else { return false }
            return world.windows.isHidden(p.endA.window) || world.windows.isHidden(p.endB.window)
        case let .ladder(lid, _):
            guard let l = world.ladders.ladders[lid]?.placed else { return false }
            return world.windows.isHidden(l.top.window)
        default:
            return false
        }
    }
}
