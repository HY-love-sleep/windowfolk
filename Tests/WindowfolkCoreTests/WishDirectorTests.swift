import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 WishDirector 属性测试。
// - Property 18（任务 7.6）：Wish 生成合法。
// - Property 19（任务 7.5）：生成条件判定。

// MARK: - 生成器（Property 19）

/// 一扇窗口：左上角与宽度（高度固定 200）。
fileprivate struct EligibilityWindowSpec: Sendable {
    var x: Int, y: Int, width: Int
}

/// 一位居民：附着方式（0 窗沿、1 Ground、2 free）、所在窗口下标与水平比例、状态、Walk_Distance、正在坐的 Chair。
fileprivate struct EligibilityResidentSpec: Sendable {
    var attach: Int, window: Int, frac: Double
    var state: Int
    /// 0：0；1：Tired_Walk_Distance − 1；2：恰好 Tired_Walk_Distance；3：随机。
    var walkPick: Int, walkRandom: Double
    /// 0 为不坐，k 为 Decor k。
    var seat: Int
}

/// 一件 Decor：类型、放置方式（0 窗沿、1 Ground、2 拖动中）、所在窗口下标与水平比例。
fileprivate struct EligibilityDecorSpec: Sendable {
    var lamp: Bool, placement: Int, window: Int, frac: Double
}

/// WishBook 的取值参数。
fileprivate struct EligibilityBookSpec: Sendable {
    /// 0 只有 A 的单人 Wish；1 只有 B 的；2 两人各一个；3 Flower_Wish；4 Chase_Wish；≥ 5 没有 active Wish。
    var pattern: Int
    /// 单人 Wish 的类型下标（chair、lamp、visit）。
    var typeA: Int, typeB: Int
    /// Visit_Wish 的 Visit_Target 窗口下标；共享 Wish 的 Wisher 是否为 B。
    var visitA: Int, visitB: Int, sharedWisherB: Bool
    /// 距上一个 Wish 结束的秒数；nil 为从未参与。
    var endedA: Int?, endedB: Int?
    var flowerCount: Int
    /// 距上一个 Flower_Wish 进入 Done 的秒数；nil 为从未有过。
    var flowerDone: Int?
}

/// 世界的其余参数：Hidden_Window 掩码、Night、Home_Window 下标（0 为未分配，k 为窗口 k）；
/// `bWithA` 为 true 时 B 与 A 的附着方式和窗口相同（只保留 B 自己的水平比例），使追逐的路线条件更常成立。
fileprivate struct EligibilityMiscSpec: Sendable {
    var hiddenMask: Int, isNight: Bool, homeA: Int, homeB: Int, bWithA: Bool
}

fileprivate struct EligibilityScenario: Sendable {
    var windows: [EligibilityWindowSpec]
    var a: EligibilityResidentSpec
    var b: EligibilityResidentSpec
    var decors: [EligibilityDecorSpec]
    var book: EligibilityBookSpec
    var misc: EligibilityMiscSpec
}

fileprivate extension Gen where Value == EligibilityScenario {
    static var eligibilityWindow: Generator<EligibilityWindowSpec, some SendableSequenceType> {
        zip(Gen<Int>.int(in: 0...1300), Gen<Int>.int(in: 100...700), Gen<Int>.int(in: 80...600))
            .map { EligibilityWindowSpec(x: $0, y: $1, width: $2) }
    }

    static var eligibilityResident: Generator<EligibilityResidentSpec, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...5), Gen<Int>.int(in: 0...3), Gen<Double>.double(in: 0...1),
            Gen<Int>.int(in: 0...(ResidentState.allCases.count - 1)),
            Gen<Int>.int(in: 0...3), Gen<Double>.double(in: 0...4000), Gen<Int>.int(in: 0...4)
        ).map {
            // 附着方式：0–2 窗沿、3–4 Ground、5 free。
            EligibilityResidentSpec(attach: $0 <= 2 ? 0 : ($0 <= 4 ? 1 : 2), window: $1, frac: $2,
                                    state: $3, walkPick: $4, walkRandom: $5, seat: $6)
        }
    }

    static var eligibilityDecor: Generator<EligibilityDecorSpec, some SendableSequenceType> {
        zip(Gen<Bool>.bool, Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...3), Gen<Double>.double(in: 0...1))
            .map { EligibilityDecorSpec(lamp: $0, placement: $1 <= 2 ? 0 : ($1 == 3 ? 1 : 2), window: $2, frac: $3) }
    }

    static var eligibilityBook: Generator<EligibilityBookSpec, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...8),
            zip(Gen<Int>.int(in: 0...2), Gen<Int>.int(in: 0...2)),
            zip(Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...3), Gen<Bool>.bool),
            Gen<Int>.int(in: 0...400).optional(valueRate: 0.5),
            Gen<Int>.int(in: 0...400).optional(valueRate: 0.5),
            Gen<Int>.int(in: 0...5),
            Gen<Int>.int(in: 0...250).optional(valueRate: 0.6)
        ).map { pattern, types, visit, endedA, endedB, count, done in
            EligibilityBookSpec(pattern: pattern, typeA: types.0, typeB: types.1, visitA: visit.0, visitB: visit.1,
                                sharedWisherB: visit.2, endedA: endedA, endedB: endedB, flowerCount: count,
                                flowerDone: done)
        }
    }

    static var eligibilityScenario: Generator<EligibilityScenario, some SendableSequenceType> {
        zip(
            eligibilityWindow.array(of: 4),
            eligibilityResident,
            eligibilityResident,
            eligibilityDecor.array(of: 0...4),
            eligibilityBook,
            zip(Gen<Int>.int(in: 0...15), Gen<Bool>.bool, Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...4),
                Gen<Bool>.bool(0.4))
                .map { EligibilityMiscSpec(hiddenMask: $0, isNight: $1, homeA: $2, homeB: $3, bWithA: $4) }
        ).map { EligibilityScenario(windows: $0, a: $1, b: $2, decors: $3, book: $4, misc: $5) }
    }
}

// MARK: - 生成器（Property 18）

/// 一次世界更新：时钟前进 `dt` 秒；可能切换 Night；改变居民状态（下标 ≥ 状态数时不变）与 Walk_Distance
/// （0：0；1：Tired_Walk_Distance − 1；2：恰好 Tired_Walk_Distance；3：Tired_Walk_Distance + 500；4：不变）。
fileprivate struct WishCheckStepSpec: Sendable {
    var dt: Int, flipNight: Bool, stateA: Int, stateB: Int, walkA: Int, walkB: Int
}

/// 初始世界、更新序列、Wish_Spawn_Chance（0：取 0；1：取 1；2：取 `chanceValue`）和随机种子。
fileprivate struct WishSpawnScenario: Sendable {
    var world: EligibilityScenario
    var steps: [WishCheckStepSpec]
    var chanceKind: Int, chanceValue: Double
    var seed: UInt64
}

/// 一次生成的结果：Wisher、Wish_Type、Visit_Target。
fileprivate struct SpawnRecord: Hashable, CustomStringConvertible {
    var wisher: ResidentID, type: WishType, target: VisitTarget?
    var description: String { "\(wisher)/\(type)/\(target.map { "\($0.window)" } ?? "-")" }
}

fileprivate extension Gen where Value == WishSpawnScenario {
    static var wishCheckStep: Generator<WishCheckStepSpec, some SendableSequenceType> {
        let n = ResidentState.allCases.count
        return zip(
            Gen<Int>.int(in: 0...25), Gen<Bool>.bool(0.2),
            Gen<Int>.int(in: 0...(2 * n - 1)), Gen<Int>.int(in: 0...(2 * n - 1)),
            Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...4)
        ).map { WishCheckStepSpec(dt: $0, flipNight: $1, stateA: $2, stateB: $3, walkA: $4, walkB: $5) }
    }

    static var wishSpawnScenario: Generator<WishSpawnScenario, some SendableSequenceType> {
        zip(
            Gen<EligibilityScenario>.eligibilityScenario,
            wishCheckStep.array(of: 1...24),
            Gen<Int>.int(in: 0...2), Gen<Double>.double(in: 0.05...0.95),
            Gen<Int>.int(in: 0...Int.max)
        ).map { WishSpawnScenario(world: $0, steps: $1, chanceKind: $2, chanceValue: $3, seed: UInt64($4)) }
    }
}

// MARK: - Tests

struct WishDirectorTests {
    static let screen = ResidentTests.screen
    static let t0 = Date(timeIntervalSince1970: 80_000)
    static let windowIDs: [WindowID] = [1, 2, 3, 4]

    fileprivate static func build(_ s: EligibilityScenario) -> (WorldState, WishBook) {
        let k = Tunables()
        let snaps = s.windows.enumerated().map { i, w in
            WindowSnapshot(id: windowIDs[i], ownerName: "App\(i + 1)", ownerPID: 1,
                           frame: Rect(minX: Double(w.x), minY: Double(w.y), width: Double(w.width), height: 200),
                           zIndex: i + 1)
        }
        var table = WindowTable()
        let ids = Set(snaps.map(\.id))
        table.apply(.success(eligible: snaps, existingIDs: ids))
        let hidden = Set(windowIDs.indices.filter { s.misc.hiddenMask & (1 << $0) != 0 }.map { windowIDs[$0] })
        if !hidden.isEmpty {
            table.apply(.success(eligible: snaps.filter { !hidden.contains($0.id) }, existingIDs: ids))
        }
        let surfaces = SurfaceBuilder.build(windows: table.visibleSnapshots, screen: screen)
        var world = WorldState(screen: screen, windows: table, surfaces: surfaces,
                               nav: NavGraph.build(surfaces: surfaces, constants: k))
        world.isNight = s.misc.isNight

        func attachment(kind: Int, window: Int, frac: Double) -> CoreAttachment {
            switch kind {
            case 0: return .window(windowIDs[window], offset: frac * Double(s.windows[window].width))
            case 1: return .ground(x: frac * screen.frame.width)
            default: return .free(Point(x: frac * screen.frame.width, y: 200))
            }
        }
        func resident(_ id: ResidentID, _ r: EligibilityResidentSpec) -> Resident {
            let walk: Double
            switch r.walkPick {
            case 0: walk = 0
            case 1: walk = k.tiredWalkDistance - 1
            case 2: walk = k.tiredWalkDistance
            default: walk = r.walkRandom
            }
            return Resident(id: id, state: ResidentState.allCases[r.state],
                            attachment: attachment(kind: r.attach, window: r.window, frac: r.frac),
                            walkDistance: walk, seat: r.seat == 0 ? nil : DecorID(UInt64(r.seat)))
        }
        var bSpec = s.b
        if s.misc.bWithA { bSpec.attach = s.a.attach; bSpec.window = s.a.window }
        world.residents = [.a: resident(.a, s.a), .b: resident(.b, bSpec)]

        var decors: [DecorID: Decor] = [:]
        for (i, d) in s.decors.enumerated() {
            let id = DecorID(UInt64(i + 1))
            let placement: DecorPlacement = d.placement == 2
                ? .dragged(grabOffset: Point(x: 0, y: 0), fresh: false)
                : .attached(attachment(kind: d.placement, window: d.window, frac: d.frac))
            decors[id] = Decor(id: id, type: d.lamp ? .lamp : .chair, placement: placement, placedSeq: UInt64(i + 1))
        }
        world.decors = DecorStore(decors: decors)

        var homes: [ResidentID: WindowID] = [:]
        if s.misc.homeA > 0 { homes[.a] = windowIDs[s.misc.homeA - 1] }
        if s.misc.homeB > 0 { homes[.b] = windowIDs[s.misc.homeB - 1] }
        world.story.homes = homes

        let b = s.book
        let single: [WishType] = [.chair, .lamp, .visit]
        var book = WishBook()
        func wish(_ type: WishType, _ wisher: ResidentID, visit: Int) -> Wish {
            let target = type == .visit ? VisitTarget(window: windowIDs[visit], ownerName: "App\(visit + 1)") : nil
            return Wish(id: book.makeID(), type: type, wisher: wisher, createdAt: t0, visitTarget: target)
        }
        var active: [Wish] = []
        switch b.pattern {
        case 0: active = [wish(single[b.typeA], .a, visit: b.visitA)]
        case 1: active = [wish(single[b.typeB], .b, visit: b.visitB)]
        case 2: active = [wish(single[b.typeA], .a, visit: b.visitA), wish(single[b.typeB], .b, visit: b.visitB)]
        case 3: active = [wish(.flower, b.sharedWisherB ? .b : .a, visit: 0)]
        case 4: active = [wish(.chase, b.sharedWisherB ? .b : .a, visit: 0)]
        default: break
        }
        book.active = active
        if let e = b.endedA { book.lastEnded[.a] = t0.addingTimeInterval(-Double(e)) }
        if let e = b.endedB { book.lastEnded[.b] = t0.addingTimeInterval(-Double(e)) }
        book.flowerCount = b.flowerCount
        book.lastFlowerDoneAt = b.flowerDone.map { t0.addingTimeInterval(-Double($0)) }
        return (world, book)
    }

    /// Nav_Graph 中从 `from` 出发沿边可到达的 Surface（含 `from` 自身）。按边的 from → to 做广度优先搜索。
    static func reachableSurfaces(_ nav: NavGraph, from: SurfaceID) -> Set<SurfaceID> {
        guard nav.nodes[from] != nil else { return [] }
        let edges = nav.allEdges
        var seen: Set<SurfaceID> = [from]
        var queue = [from]
        while let s = queue.popLast() {
            for e in edges where e.from == s && !seen.contains(e.to) {
                seen.insert(e.to)
                queue.append(e.to)
            }
        }
        return seen
    }

    /// 参考谓词：按 Requirement 6.3、8.1、20.1 判定居民 `r` 满足生成条件的 Wish_Type（按 `WishType.allCases` 顺序）。
    static func referenceTypes(_ r: ResidentID, book: WishBook, world: WorldState, ctx: WishContext) -> [WishType] {
        let k = ctx.constants
        let now = ctx.now
        guard let me = world.residents[r] else { return [] }
        let other: ResidentID = r == .a ? .b : .a

        // Busy_Resident：active Wish 的参与者；flower、chase 两人都参与。
        var busy: Set<ResidentID> = []
        for w in book.active {
            if w.type == .flower || w.type == .chase { busy.formUnion([.a, .b]) } else { busy.insert(w.wisher) }
        }
        func cooled(_ id: ResidentID) -> Bool {
            guard let t = book.lastEnded[id] else { return true }
            return now.timeIntervalSince(t) >= k.wishCooldown
        }
        let reach = ctx.locations[r].map { reachableSurfaces(ctx.nav, from: $0.surface) } ?? []
        // 「场上」的 Decor：放在可见 Surface 上（在 decorLocations 中），且从 r 当前位置有路线。
        func onFieldReachable(_ id: DecorID) -> Bool {
            guard let loc = ctx.decorLocations[id] else { return false }
            return reach.contains(loc.surface)
        }
        let occupied = Set(world.residents.values.compactMap(\.seat))

        var out: [WishType] = []
        // Requirement 8.1：(a) 两人都不 Busy；(b) 第 1 次 Giver 为 A，之后与上一次 Receiver 相同，即交替；
        // (c) 距上次 Done 已满 Round_Interval，从未有过时跳过。
        let giver: ResidentID = book.flowerCount % 2 == 0 ? .a : .b
        let roundOK = book.lastFlowerDoneAt.map { now.timeIntervalSince($0) >= k.roundInterval } ?? true
        if busy.isEmpty, world.residents[other] != nil, giver == r, roundOK { out.append(.flower) }

        // Requirement 6.3 chair：累了，且不存在一把未被占用、有路线可达的 Chair。
        if me.walkDistance >= k.tiredWalkDistance {
            let freeChair = world.decors.decors.values.contains { d in
                guard d.type == .chair, case .attached = d.placement, !occupied.contains(d.id) else { return false }
                return onFieldReachable(d.id)
            }
            if !freeChair { out.append(.chair) }
        }

        // Requirement 6.3 lamp：Night，且不存在一盏有路线可达的 Lamp。
        if ctx.isNight {
            let lamp = world.decors.decors.values.contains { d in
                guard d.type == .lamp, case .attached = d.placement else { return false }
                return onFieldReachable(d.id)
            }
            if !lamp { out.append(.lamp) }
        }

        // Requirement 6.3 visit：可见 Eligible_Window，不是任何 Home_Window，至少一段 Window_Ledge，不是其他 Visit_Target。
        let homes = Set(ctx.homes.values)
        let taken = Set(book.active.filter { $0.type == .visit }.compactMap { $0.visitTarget?.window })
        let hasVisit = world.windows.visibleSnapshots.contains { w in
            !homes.contains(w.id) && !taken.contains(w.id) && world.surfaces.contains { $0.id.windowID == w.id }
        }
        if hasVisit { out.append(.visit) }

        // Requirement 20.1：(a) 非 Night；(b) 另一位不 Busy、不在 falling / hanging；(c) 另一位冷却已满；
        // (d) A 所在 Surface 到 B 所在 Surface 有路线（同一 Surface 视为有）。
        if !ctx.isNight, let o = world.residents[other], !busy.contains(other),
           o.state != .falling, o.state != .hanging, cooled(other),
           let la = ctx.locations[.a], let lb = ctx.locations[.b],
           la.surface == lb.surface || reachableSurfaces(ctx.nav, from: la.surface).contains(lb.surface) {
            out.append(.chase)
        }
        return out
    }

    // Feature: V2, Property 19: 生成条件判定
    /// **Validates: Requirements 6.3, 8.1, 20.1**
    @Test func eligibleTypesMatchReferencePredicate() async {
        await propertyCheck(count: 200, input: Gen.eligibilityScenario) { s in
            let (world, book) = Self.build(s)
            let ctx = WishContext(world: world, now: Self.t0)
            for r in ResidentID.allCases {
                let actual = WishDirector.eligibleTypes(r, book: book, world: world, ctx: ctx)
                let expected = Self.referenceTypes(r, book: book, world: world, ctx: ctx)
                #expect(actual == expected, "resident \(r)")
            }
        }
    }

    // MARK: Property 18

    /// 参考前置条件（Requirement 6.2）：不是 Busy_Resident，不在 `falling` / `hanging`，冷却已满。
    static func referencePasses(_ r: ResidentID, book: WishBook, world: WorldState, now: Date, k: Tunables) -> Bool {
        guard let me = world.residents[r] else { return false }
        let busy = book.active.reduce(into: Set<ResidentID>()) { acc, w in
            if w.type == .flower || w.type == .chase { acc.formUnion([.a, .b]) } else { acc.insert(w.wisher) }
        }
        guard !busy.contains(r), me.state != .falling, me.state != .hanging else { return false }
        guard let t = book.lastEnded[r] else { return true }
        return now.timeIntervalSince(t) >= k.wishCooldown
    }

    /// 参考 Visit_Target 候选（Requirement 6.3、9.1）：可见，不是 Home_Window，有 Window_Ledge，不是其他 active
    /// Visit_Wish 的目标；按窗口 ID 升序。
    static func referenceVisitCandidates(book: WishBook, world: WorldState, ctx: WishContext) -> [VisitTarget] {
        let homes = Set(ctx.homes.values)
        let taken = Set(book.active.filter { $0.type == .visit }.compactMap { $0.visitTarget?.window })
        return world.windows.visibleSnapshots
            .filter { w in
                !homes.contains(w.id) && !taken.contains(w.id) && world.surfaces.contains { $0.id.windowID == w.id }
            }
            .sorted { $0.id < $1.id }
            .map { VisitTarget(window: $0.id, ownerName: $0.ownerName) }
    }

    /// 用 1 次随机数在 `n` 个候选中等概率取下标。
    static func referencePick(_ n: Int, _ rng: inout RandomSource) -> Int {
        min(Int(rng.nextUnit() * Double(n)), n - 1)
    }

    static func startedWishes(_ events: [WishEvent]) -> [Wish] {
        events.compactMap { if case let .started(w) = $0 { w } else { nil } }
    }

    static func droppedWishes(_ events: [WishEvent]) -> [Wish] {
        events.compactMap { if case let .dropped(w) = $0 { w } else { nil } }
    }

    fileprivate static func checkSpawnLegality(_ s: WishSpawnScenario) {
        var k = Tunables()
        k.wishSpawnChance = [0, 1, s.chanceValue][s.chanceKind]
        var (world, book) = build(s.world)
        let seedRng = RandomSource(seed: s.seed)
        var rng = seedRng
        var now = t0

        // Home_Window 分配之前（nextCheckAt 为 nil）不检查、不生成、不用随机数。
        book.nextCheckAt = nil
        let before = WishDirector.plan(&book, world: &world, ctx: WishContext(world: world, now: now, constants: k),
                                       rng: &rng)
        #expect(startedWishes(before).isEmpty, "生成于 Home_Window 分配之前")
        #expect(rng == seedRng)

        // Home_Window 分配完成：第一次检查在满 1 个 Wish_Check_Interval 时（Requirement 6.1）。
        WishDirector.startScheduling(&book, now: now, constants: k)
        var refNext = now.addingTimeInterval(k.wishCheckInterval)
        #expect(book.nextCheckAt == refNext)

        var targets: [WishID: VisitTarget?] = [:]
        for w in book.active where w.type == .visit { targets[w.id] = w.visitTarget }

        func mutate(_ id: ResidentID, state: Int, walk: Int) {
            guard var r = world.residents[id] else { return }
            if state < ResidentState.allCases.count { r.state = ResidentState.allCases[state] }
            switch walk {
            case 0: r.walkDistance = 0
            case 1: r.walkDistance = k.tiredWalkDistance - 1
            case 2: r.walkDistance = k.tiredWalkDistance
            case 3: r.walkDistance = k.tiredWalkDistance + 500
            default: break
            }
            world.residents[id] = r
        }

        var elapsed = 0.0
        for (i, step) in s.steps.enumerated() {
            elapsed += Double(step.dt)
            now = t0.addingTimeInterval(elapsed)
            if step.flipNight { world.isNight.toggle() }
            mutate(.a, state: step.stateA, walk: step.walkA)
            mutate(.b, state: step.stateB, walk: step.walkB)

            let ctx = WishContext(world: world, now: now, constants: k)
            let worldBefore = world, bookBefore = book, rngBefore = rng
            let events = WishDirector.plan(&book, world: &world, ctx: ctx, rng: &rng)
            let spawned = startedWishes(events)

            // 检查节奏：now >= nextCheckAt 时检查，nextCheckAt += 间隔，落后太多时设为 now + 间隔。
            let isCheck = now >= refNext
            if isCheck {
                refNext = refNext.addingTimeInterval(k.wishCheckInterval)
                if refNext <= now { refNext = now.addingTimeInterval(k.wishCheckInterval) }
            }
            #expect(book.nextCheckAt == refNext, "step \(i)")

            // 参考：检查前先计入本帧的放弃（Wisher 冷却从此刻起算），再按 A、B 顺序检查；A 生成的 Wish 在
            // 检查 B 时已计入。随机数：每位通过者 1 次概率、抽中后 1 次类型、Visit 再 1 次窗口。
            var refBook = bookBefore
            for w in droppedWishes(events) {
                refBook.active.removeAll { $0.id == w.id }
                refBook.lastEnded[w.wisher] = now
            }
            var refRng = rngBefore
            var expected: [SpawnRecord] = []
            var qualified = 0
            if isCheck {
                for r in [ResidentID.a, .b] {
                    guard referencePasses(r, book: refBook, world: worldBefore, now: now, k: k) else { continue }
                    let types = referenceTypes(r, book: refBook, world: worldBefore, ctx: ctx)
                    guard !types.isEmpty else { continue }
                    qualified += 1
                    guard refRng.nextUnit() < k.wishSpawnChance else { continue }
                    let type = types[referencePick(types.count, &refRng)]
                    var target: VisitTarget?
                    if type == .visit {
                        let candidates = referenceVisitCandidates(book: refBook, world: worldBefore, ctx: ctx)
                        target = candidates[referencePick(candidates.count, &refRng)]
                    }
                    expected.append(SpawnRecord(wisher: r, type: type, target: target))
                    refBook.active.append(Wish(id: refBook.makeID(), type: type, wisher: r, createdAt: now,
                                               visitTarget: target))
                }
            }

            let actual = spawned.map { SpawnRecord(wisher: $0.wisher, type: $0.type, target: $0.visitTarget) }
            #expect(actual == expected, "step \(i) now+\(elapsed)s check=\(isCheck)")
            #expect(rng == refRng, "step \(i) 随机数用量")
            for w in spawned {
                #expect(w.createdAt == now && w.state == .active)
            }
            if !isCheck { #expect(spawned.isEmpty, "step \(i) 非检查时刻生成") }
            if k.wishSpawnChance == 0 { #expect(spawned.isEmpty) }
            if k.wishSpawnChance == 1 { #expect(spawned.count == qualified, "step \(i)") }

            // Visit_Target 直到 Wish 结束都不更换。
            for w in spawned where w.type == .visit { targets[w.id] = w.visitTarget }
            for w in book.active where w.type == .visit {
                #expect(targets[w.id] == .some(w.visitTarget), "step \(i) Visit_Target 更换")
            }
        }
    }

    // Feature: V2, Property 18: Wish 生成合法
    /// **Validates: Requirements 6.1, 6.2, 6.4, 6.5, 6.6, 9.1**
    @Test func spawnedWishesAreLegal() async {
        await propertyCheck(count: 200, input: Gen.wishSpawnScenario) { s in
            Self.checkSpawnLegality(s)
        }
    }
}
