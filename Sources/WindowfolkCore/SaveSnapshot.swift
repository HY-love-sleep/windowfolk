import Foundation

// 世界快照与恢复（design.md「Core：SaveFile 与 SaveCodec」，任务 16.2）。
//
// snapshot：把当前世界归一为 SaveFile（Requirement 22.3、22.4、22.8）。
// - 未被持有的 Item、全部 Plank 和 Ladder 都记为 Ground_Object，x 取保存时刻的屏幕 x：
//   Plank 取两端中点，Ladder 取下端（即上端 x，梯子竖直）；附着在 Hidden_Window 上的对象用该窗口最后一次
//   可见时的快照计算；下落中、悬挂中、被拖动的对象取当前 x。
// - 被居民持有的 Item 记在居民名下，不作为 Ground_Object。
// - Story_Stage 经 `SavedStory.persistedStage` 映射：`planting` 存为 `travel`，`bloomed` 存为 `returnGift`，
//   且 `bloomed` 时 Receiver 名下带上 Fruit（还没拿到时补一颗）。
// - 全部时间经 `SaveTime.normalized` 取整，保证 `decode(encode(s)) == s`。
//
// restore：在已知当前窗口和路面之后（WorldEngine 第一次成功轮询的那一帧）把存档放回世界：
// - 每个 Ground_Object 从屏幕上沿上方开始下落，x 夹紧到屏幕范围，只落在 Ground 上（Requirement 22.6）；
// - 每位居民从屏幕上沿上方开始下落，x 取离保存 x 水平距离最近的 Window_Ledge 上的最近点，只落在该窗口的
//   窗沿上；只考虑下落能到达的窗沿部分（x 在屏幕范围内、y 在 Ground 上方）；没有任何窗沿时落到 Ground 上
//   保存 x 处（Requirement 22.7）；持有物照旧（Requirement 22.8）；
// - 剧情从保存的阶段和轮次继续，Giver / Receiver 由轮次奇偶决定（Requirement 19.5、19.6、22.9）；
//   Home_Window 不恢复；
// - 每朵花按种下时间和当前时间重算 Growth_Stage（应用未运行期间照常生长，Requirement 22.10）；
//   `Done` 的下一轮开始时刻由保存的 `doneAt` 和 Round_Interval 决定，已过时下一次剧情更新就开始下一轮
//   （Requirement 19.7）。

/// 恢复时下落对象的落点限制。WorldEngine 在这些对象落地之前只让它们落在指定的 Surface 上。
public struct RestoreLanding: Hashable, Sendable {
    /// 居民的目标窗口；nil 表示落到 Ground 上。
    public var residents: [ResidentID: WindowID?]
    /// 只落在 Ground 上的物件、木板和梯子。
    public var items: Set<ItemID>
    public var planks: Set<PlankID>
    public var ladders: Set<LadderID>

    public init(
        residents: [ResidentID: WindowID?] = [:], items: Set<ItemID> = [],
        planks: Set<PlankID> = [], ladders: Set<LadderID> = []
    ) {
        self.residents = residents
        self.items = items
        self.planks = planks
        self.ladders = ladders
    }

    public var isEmpty: Bool { residents.isEmpty && items.isEmpty && planks.isEmpty && ladders.isEmpty }

    /// 只保留 `surface` 允许作为居民 `id` 落点的 Surface。
    public func landingSurfaces(for id: ResidentID, in surfaces: [Surface]) -> [Surface]? {
        guard let target = residents[id] else { return nil }
        return surfaces.filter { s in
            s.id == .ground || (target != nil && s.id.isLedge && s.id.windowID == target)
        }
    }
}

public enum SaveSnapshot {
    // MARK: - snapshot

    /// 把世界状态归一为存档（Requirement 22.3、22.4、22.8）。
    public static func snapshot(world: WorldState, now: Date) -> SaveFile {
        var residents: [SavedResident] = []
        var heldIDs: Set<ItemID> = []
        let story = world.story
        let stage = SavedStory.persistedStage(story.stage)

        for id in world.residents.keys.sorted() {
            guard let r = world.residents[id] else { continue }
            var held: SavedHeldItem?
            if let iid = r.heldItem, let item = world.items[iid] {
                held = savedHeld(item)
                heldIDs.insert(iid)
            }
            // `bloomed` 存为 `returnGift`：Receiver 必须带着 Fruit（design.md「world.json」）。
            if story.stage == .bloomed, id == story.receiver, held?.kind != .fruit {
                let fid = story.currentFruit.flatMap { world.items[$0] == nil ? $0 : nil } ?? ItemID()
                held = SavedHeldItem(id: fid.rawValue.uuidString, kind: .fruit)
            }
            residents.append(SavedResident(id: id, x: residentX(r, world: world), heldItem: held))
        }

        var objects: [SavedObject] = []
        for iid in world.items.sortedIDs {
            guard let item = world.items[iid], !heldIDs.contains(iid) else { continue }
            if case let .held(holder) = item.placement, world.residents[holder] != nil { continue }
            // 其中 `bloomed` 时补给 Receiver 的那颗 Fruit 已在居民名下，不重复记录。
            let x = itemX(item, world: world)
            objects.append(SavedObject(
                id: iid.rawValue.uuidString, kind: item.kind.isFlower ? .flower : .fruit, x: x,
                flower: savedFlower(item)))
        }
        for pid in world.planks.planks.keys.sorted() {
            guard let p = world.planks.planks[pid], let x = plankX(p, id: pid, world: world) else { continue }
            objects.append(SavedObject(id: "plank-\(pid.rawValue)", kind: .plank, x: x))
        }
        for lid in world.ladders.ladders.keys.sorted() {
            guard let l = world.ladders.ladders[lid], let x = ladderX(l, id: lid, world: world) else { continue }
            objects.append(SavedObject(id: "ladder-\(lid.rawValue)", kind: .ladder, x: x))
        }

        return SaveFile(
            savedAt: SaveTime.normalized(now),
            story: SavedStory(stage: stage, round: story.round, doneAt: story.doneAt.map(SaveTime.normalized)),
            residents: residents, groundObjects: objects)
    }

    private static func savedFlower(_ item: Item) -> SavedFlower? {
        guard case let .flower(round) = item.kind else { return nil }
        let g = item.growth ?? FlowerGrowth()
        return SavedFlower(storyRound: round, plantedAt: g.plantedAt.map(SaveTime.normalized), reached: g.reached)
    }

    private static func savedHeld(_ item: Item) -> SavedHeldItem {
        SavedHeldItem(id: item.id.rawValue.uuidString, kind: item.kind.isFlower ? .flower : .fruit,
                      flower: savedFlower(item))
    }

    /// Attachment 的屏幕坐标；附着在隐藏窗口上时用该窗口最后一次可见的快照。窗口已关闭时为 nil。
    static func lastKnownPoint(_ a: Attachment, world: WorldState) -> Point? {
        switch a {
        case let .window(wid, offset):
            return world.windows.records[wid].map {
                Point(x: $0.snapshot.frame.minX + offset, y: $0.snapshot.frame.minY)
            }
        case let .ground(x):
            return Point(x: x, y: world.screen.groundY)
        case let .plank(pid, t):
            guard let p = world.planks.planks[pid]?.placed,
                  let (l, r) = lastKnownEnds(p, world: world) else { return nil }
            let u = min(max(t, 0), 1)
            return Point(x: l.x + (r.x - l.x) * u, y: l.y + (r.y - l.y) * u)
        case let .ladder(lid, height):
            guard let l = world.ladders.ladders[lid]?.placed else { return nil }
            let top = l.top.lastKnownPoint(windows: world.windows) ?? l.bottom
            let h = min(max(height, 0), max(l.bottom.y - top.y, 0))
            return Point(x: top.x, y: l.bottom.y - h)
        case let .free(p):
            return p
        }
    }

    /// 已架设木板两端的最后已知坐标，按 x 从左到右；一端窗口已关闭时用另一端；两端都没有时为 nil。
    private static func lastKnownEnds(_ p: PlacedPlank, world: WorldState) -> (Point, Point)? {
        let a = p.endA.lastKnownPoint(windows: world.windows)
        let b = p.endB.lastKnownPoint(windows: world.windows)
        guard let pa = a ?? b, let pb = b ?? a else { return nil }
        return pb.x < pa.x ? (pb, pa) : (pa, pb)
    }

    private static func fallbackX(_ world: WorldState) -> Double { world.screen.frame.midX }

    static func residentX(_ r: Resident, world: WorldState) -> Double {
        if r.state == .falling, let f = r.fall { return f.position.x }
        if let t = r.traversal { return ResidentController.traversalPoint(t).x }
        return lastKnownPoint(r.attachment, world: world)?.x ?? fallbackX(world)
    }

    static func itemX(_ item: Item, world: WorldState) -> Double {
        switch item.placement {
        case let .attached(a):
            return lastKnownPoint(a, world: world)?.x ?? fallbackX(world)
        case let .falling(f):
            return f.position.x
        case .dragged:
            return InteractionController.draggedItemPosition(item.id, gesture: world.gesture)?.x ?? fallbackX(world)
        case let .held(holder):
            // 持有者不存在（不应发生）：按持有者原位置兜底。
            return world.residents[holder].map { residentX($0, world: world) } ?? fallbackX(world)
        }
    }

    /// 拖动中对象的 x：指针减去抓取偏移。
    private static func draggedX(_ subject: DragSubject, world: WorldState) -> Double? {
        guard case let .dragging(s, grab, pointer) = world.gesture, s == subject else { return nil }
        return pointer.x - grab.x
    }

    static func plankX(_ p: PlankState, id: PlankID, world: WorldState) -> Double? {
        switch p {
        case let .placed(placed):
            guard let (l, r) = lastKnownEnds(placed, world: world) else { return fallbackX(world) }
            return (l.x + r.x) / 2
        case let .loose(a):
            return lastKnownPoint(a, world: world)?.x ?? fallbackX(world)
        case let .falling(f):
            return f.position.x
        case .dragged:
            return draggedX(.plank(id), world: world) ?? fallbackX(world)
        }
    }

    static func ladderX(_ l: LadderState, id: LadderID, world: WorldState) -> Double? {
        switch l {
        case let .placed(placed):
            return placed.top.lastKnownPoint(windows: world.windows)?.x ?? placed.bottom.x
        case let .loose(a):
            return lastKnownPoint(a, world: world)?.x ?? fallbackX(world)
        case let .falling(f):
            return f.position.x
        case .dragged:
            return draggedX(.ladder(id), world: world) ?? fallbackX(world)
        }
    }

    // MARK: - restore

    /// 下落起点：屏幕上沿上方一个对象高度处。
    static func startY(_ world: WorldState, height: Double) -> Double {
        world.screen.frame.minY - height
    }

    /// 把存档放回世界。`world.windows` 和 `world.surfaces` 应已是当前帧的结果。
    /// 返回恢复下落对象的落点限制，由 WorldEngine 在它们落地前使用。
    @discardableResult
    public static func restore(
        _ save: SaveFile, into world: inout WorldState, now: Date, constants c: Tunables
    ) -> RestoreLanding {
        var landing = RestoreLanding()
        let screen = world.screen

        // Ground_Object：从屏幕上方落到 Ground 上（x 夹紧到屏幕范围）。
        for obj in save.groundObjects {
            switch obj.kind {
            case .flower, .fruit:
                var item = makeItem(id: obj.id, kind: obj.kind, flower: obj.flower, placement: .held(.a))
                let h = SpriteMetrics.itemSize(item.kind).height
                item.placement = .falling(Physics.startFall(
                    at: Point(x: obj.x, y: startY(world, height: h)), screen: screen))
                regrow(&item, now: now, constants: c)
                world.items[item.id] = item
                landing.items.insert(item.id)
            case .plank:
                let id = world.planks.makeID()
                world.planks.planks[id] = .falling(Physics.startFall(
                    at: Point(x: obj.x, y: startY(world, height: SpriteMetrics.plankThickness)), screen: screen))
                landing.planks.insert(id)
            case .ladder:
                let id = world.ladders.makeID()
                world.ladders.ladders[id] = .falling(Physics.startFall(
                    at: Point(x: obj.x, y: startY(world, height: SpriteMetrics.ladderWidth)), screen: screen))
                landing.ladders.insert(id)
            }
        }

        // 居民：落到离保存 x 最近的窗沿上；没有窗沿时落到 Ground 上保存 x 处。
        // 只考虑下落能到达的窗沿部分：x 在下落起点的夹紧范围（`Physics.clampX`）内，y 在 Ground 上方。
        // 否则最近点可能在屏幕外或 Ground 下方，夹紧后的下落会错过该窗沿而落到 Ground 上。
        let ledges = world.surfaces.compactMap { s -> Surface? in
            guard s.id.isLedge, s.id.windowID.map({ world.windows.visibleSnapshot($0) != nil }) == true,
                  s.start.y < screen.groundY else { return nil }
            return clippedToFallRange(s, screen: screen)
        }
        var saved = Dictionary(save.residents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in ResidentID.allCases where saved[id] == nil {
            // 存档缺少某位居民（不应发生）：放在 Ground 的三分之一 / 三分之二处。
            let lo = screen.visibleFrame.minX, w = screen.visibleFrame.width
            saved[id] = SavedResident(id: id, x: lo + w * (id == .a ? 1.0 / 3 : 2.0 / 3))
        }
        for id in ResidentID.allCases {
            guard let s = saved[id] else { continue }
            let target = nearestLedgePoint(to: s.x, ledges: ledges)
            let x = target?.x ?? s.x
            var r = Resident(id: id, attachment: .ground(x: x), facing: id == .a ? .right : .left)
            ResidentController.startFalling(
                &r, from: Point(x: x, y: startY(world, height: SpriteMetrics.resident.height)), screen: screen)
            if let h = s.heldItem {
                var item = makeItem(id: h.id, kind: h.kind == .flower ? .flower : .fruit,
                                    flower: h.flower, placement: .held(id))
                regrow(&item, now: now, constants: c)
                world.items.give(item, to: &r)
            }
            world.residents[id] = r
            landing.residents[id] = .some(target?.window)
        }

        // 剧情。
        var story = StoryState(
            stage: SavedStory.persistedStage(save.story.stage), round: save.story.round,
            doneAt: save.story.doneAt, groundPlaced: true)
        restoreStoryItems(&story, world: &world)
        world.story = story
        return landing
    }

    /// 窗沿与下落 x 范围（`Physics.clampX` 的范围）的交集；没有交集时为 nil。窗沿是水平线段。
    static func clippedToFallRange(_ s: Surface, screen: ScreenInfo) -> Surface? {
        let lo = max(s.start.x, Physics.clampX(-.greatestFiniteMagnitude, screen: screen))
        let hi = min(s.end.x, Physics.clampX(.greatestFiniteMagnitude, screen: screen))
        guard lo <= hi else { return nil }
        var c = s
        c.start.x = lo
        c.end.x = hi
        return c
    }

    /// 离 `x` 水平距离最近的窗沿上的最近点（距离相等时按 `SurfaceID` 顺序取前者）。
    static func nearestLedgePoint(to x: Double, ledges: [Surface]) -> (x: Double, window: WindowID)? {
        var best: (d: Double, x: Double, window: WindowID)?
        for s in ledges.sorted(by: { $0.id < $1.id }) {
            guard let wid = s.id.windowID else { continue }
            let px = min(max(x, s.start.x), s.end.x)
            let d = abs(px - x)
            if best == nil || d < best!.d { best = (d, px, wid) }
        }
        return best.map { ($0.x, $0.window) }
    }

    private static func makeItem(
        id: String, kind: SavedObjectKind, flower: SavedFlower?, placement: ItemPlacement
    ) -> Item {
        let iid = UUID(uuidString: id).map(ItemID.init) ?? ItemID()
        if kind == .flower {
            let f = flower ?? SavedFlower(storyRound: nil, plantedAt: nil, reached: .pot)
            return Item(id: iid, kind: .flower(storyRound: f.storyRound), placement: placement, growth: f.growth)
        }
        return Item.fruit(id: iid, placement: placement)
    }

    /// 按种下时间和当前时间重算阶段（只前进不后退，Requirement 17.4、22.10）。
    private static func regrow(_ item: inout Item, now: Date, constants c: Tunables) {
        guard var g = item.growth else { return }
        Growth.advance(&g, now: now, bloomDuration: c.bloomDuration)
        item.growth = g
    }

    /// 找回本轮的 Story_Flower 和 Fruit，并补齐阶段要求的持有物：
    /// `Wish` / `Waiting` / `Travel` 中 Giver 抱着花盆；`ReturnGift` 中 Receiver 带着 Fruit。
    private static func restoreStoryItems(_ s: inout StoryState, world: inout WorldState) {
        guard let stage = s.stage else { return }
        let g = s.giver, r = s.receiver
        switch stage {
        case .wish, .waiting, .travel, .planting:
            if let held = world.residents[g]?.heldItem, world.items[held]?.kind.isFlower == true {
                world.items[held]?.kind = .flower(storyRound: s.round)
                s.currentFlower = held
            } else {
                let pot = Item.flowerPot(storyRound: s.round, placement: .held(g))
                s.currentFlower = StoryDirector.forceGive(pot, to: g, world: &world) ? pot.id : nil
            }
        case .growing, .bloomed, .returnGift, .done:
            s.currentFlower = world.items.items.values
                .filter { $0.kind == .flower(storyRound: s.round) && $0.growth?.plantedAt != nil }
                .max { a, b in
                    let ta = a.growth!.plantedAt!, tb = b.growth!.plantedAt!
                    return ta != tb ? ta < tb : a.id < b.id
                }?.id
        }
        if stage == .returnGift || stage == .bloomed {
            if let held = world.residents[r]?.heldItem, world.items[held]?.kind == .fruit {
                s.currentFruit = held
            } else {
                let fruit = Item.fruit(placement: .held(r))
                s.currentFruit = StoryDirector.forceGive(fruit, to: r, world: &world) ? fruit.id : nil
            }
            s.stage = .returnGift
        }
    }
}
