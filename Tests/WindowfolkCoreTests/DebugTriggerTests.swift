import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 任务 7.18：Debug_Menu「触发心愿」（design.md Property 49，Requirements 17.2、17.3）。
// - 纯函数部分：任意世界状态（居民任意状态、任意 active Wish 组合、冷却、Night、Walk_Distance、Hidden_Window、
//   Home_Window）下直接调用 `WishDirector.trigger`，与参考前提比较。
// - 引擎部分：通过 `WorldEngine` 的 `Command.triggerWish`，检查同一次 step 内生成 Wish 和事件记录。

// MARK: - 生成器（纯函数部分）

/// 一扇窗口：左上角与宽度（高度固定 200）。
fileprivate struct TriggerWindowSpec: Sendable {
    var x: Int, y: Int, width: Int
}

/// 一位居民：附着方式（0 窗沿、1 Ground、2 free）、所在窗口下标与水平比例、状态、Walk_Distance。
fileprivate struct TriggerResidentSpec: Sendable {
    var attach: Int, window: Int, frac: Double
    var state: Int
    var walk: Double
}

/// WishBook 的取值参数。
fileprivate struct TriggerBookSpec: Sendable {
    /// 0 只有 A 的单人 Wish；1 只有 B 的；2 两人各一个；3 Flower_Wish；4 Chase_Wish；≥ 5 没有 active Wish。
    var pattern: Int
    /// 单人 Wish 的类型下标（chair、lamp、visit）与 Visit_Target 窗口下标；共享 Wish 的 Wisher 是否为 B。
    var typeA: Int, typeB: Int, visitA: Int, visitB: Int, sharedWisherB: Bool
    /// 距上一个 Wish 结束的秒数（多为冷却未满）；nil 为从未参与。
    var endedA: Int?, endedB: Int?
    var flowerCount: Int
    /// 距上一个 Flower_Wish 进入 Done 的秒数（多为未满 Round_Interval）。
    var flowerDone: Int?
}

fileprivate struct TriggerScenario: Sendable, CustomStringConvertible {
    var windows: [TriggerWindowSpec]
    var a: TriggerResidentSpec
    var b: TriggerResidentSpec
    var book: TriggerBookSpec
    /// Hidden_Window 掩码、Night、Home_Window 下标（0 为未分配，k 为窗口 k）。
    var hiddenMask: Int, isNight: Bool, homeA: Int, homeB: Int
    /// 「触发心愿」子项：类型与 Wisher（nil 表示调用方未给出）。
    var type: WishType
    var wisher: ResidentID?
    var seed: UInt64

    var description: String {
        "type=\(type) wisher=\(wisher.map { "\($0)" } ?? "nil") pattern=\(book.pattern) "
            + "states=(\(ResidentState.allCases[a.state]), \(ResidentState.allCases[b.state])) "
            + "hidden=\(hiddenMask) night=\(isNight) homes=(\(homeA), \(homeB)) flowerCount=\(book.flowerCount)"
    }
}

fileprivate extension Gen where Value == TriggerScenario {
    static var triggerWindow: Generator<TriggerWindowSpec, some SendableSequenceType> {
        zip(Gen<Int>.int(in: 0...1300), Gen<Int>.int(in: 100...700), Gen<Int>.int(in: 80...600))
            .map { TriggerWindowSpec(x: $0, y: $1, width: $2) }
    }

    static var triggerResident: Generator<TriggerResidentSpec, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...5), Gen<Int>.int(in: 0...3), Gen<Double>.double(in: 0...1),
            // 约三成落在 falling / hanging 上，其余在全部状态中均匀取。
            Gen<Int>.int(in: 0...(ResidentState.allCases.count + 5)), Gen<Double>.double(in: 0...4000)
        ).map { attach, window, frac, s, walk in
            let all = ResidentState.allCases
            let state: Int
            if s < all.count {
                state = s
            } else {
                let pick: ResidentState = s % 2 == 0 ? .falling : .hanging
                state = all.firstIndex(of: pick)!
            }
            return TriggerResidentSpec(attach: attach <= 2 ? 0 : (attach <= 4 ? 1 : 2), window: window,
                                       frac: frac, state: state, walk: walk)
        }
    }

    static var triggerBook: Generator<TriggerBookSpec, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...9),
            zip(Gen<Int>.int(in: 0...2), Gen<Int>.int(in: 0...2)),
            zip(Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...3), Gen<Bool>.bool),
            Gen<Int>.int(in: 0...60).optional(valueRate: 0.6),
            Gen<Int>.int(in: 0...60).optional(valueRate: 0.6),
            Gen<Int>.int(in: 0...5),
            Gen<Int>.int(in: 0...60).optional(valueRate: 0.6)
        ).map { pattern, types, visit, endedA, endedB, count, done in
            TriggerBookSpec(pattern: pattern, typeA: types.0, typeB: types.1, visitA: visit.0, visitB: visit.1,
                            sharedWisherB: visit.2, endedA: endedA, endedB: endedB, flowerCount: count,
                            flowerDone: done)
        }
    }

    static var triggerScenario: Generator<TriggerScenario, some SendableSequenceType> {
        zip(
            triggerWindow.array(of: 4),
            triggerResident,
            triggerResident,
            triggerBook,
            zip(Gen<Int>.int(in: 0...15), Gen<Bool>.bool, Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...4)),
            zip(Gen<Int>.int(in: 0...(WishType.allCases.count - 1)), Gen<Int>.int(in: 0...4)),
            Gen<Int>.int(in: 0...1_000_000)
        ).map { windows, a, b, book, misc, trigger, seed in
            // Wisher：0、1 为 A，2、3 为 B，4 为 nil。
            let wisher: ResidentID? = trigger.1 <= 1 ? .a : (trigger.1 <= 3 ? .b : nil)
            return TriggerScenario(windows: windows, a: a, b: b, book: book, hiddenMask: misc.0, isNight: misc.1,
                                   homeA: misc.2, homeB: misc.3, type: WishType.allCases[trigger.0],
                                   wisher: wisher, seed: UInt64(seed))
        }
    }
}

// MARK: - 生成器（引擎部分）

/// 引擎场景：若干窗口，先自由推进若干帧，可选地先触发一个 Wish（使居民成为 Busy_Resident），
/// 隔若干帧后再触发被检查的子项。
fileprivate struct EngineTriggerScenario: Sendable, CustomStringConvertible {
    /// 窗口数 2 至 4；居民的家占前两扇附近，窗口少时没有 Visit_Target 候选。
    var windowCount: Int
    var preFrames: Int
    /// 先触发的子项；nil 为不先触发。
    var first: (WishType, ResidentID?)?
    var gapFrames: Int
    var type: WishType
    var wisher: ResidentID?
    var night: Bool
    var seed: UInt64

    var description: String {
        let f = first.map { "\($0.0)/\($0.1.map { "\($0)" } ?? "nil")" } ?? "none"
        return "windows=\(windowCount) pre=\(preFrames) first=\(f) gap=\(gapFrames) "
            + "trigger=\(type)/\(wisher.map { "\($0)" } ?? "nil") night=\(night) seed=\(seed)"
    }
}

fileprivate extension Gen where Value == EngineTriggerScenario {
    static var engineTrigger: Generator<EngineTriggerScenario, some SendableSequenceType> {
        let item = zip(Gen<Int>.int(in: 0...(WishType.allCases.count - 1)), Gen<Int>.int(in: 0...4))
            .map { t, w -> (WishType, ResidentID?) in
                (WishType.allCases[t], w <= 1 ? .a : (w <= 3 ? .b : nil))
            }
        return zip(
            Gen<Int>.int(in: 2...4), Gen<Int>.int(in: 0...20),
            zip(Gen<Bool>.bool(0.6), item), Gen<Int>.int(in: 0...10),
            item, Gen<Bool>.bool, Gen<Int>.int(in: 0...1_000_000)
        ).map { count, pre, first, gap, trigger, night, seed in
            EngineTriggerScenario(windowCount: count, preFrames: pre, first: first.0 ? first.1 : nil,
                                  gapFrames: gap, type: trigger.0, wisher: trigger.1, night: night,
                                  seed: UInt64(seed))
        }
    }
}

/// 统计前提满足与不满足各出现多少次，确认两条分支都被覆盖。
fileprivate final class TriggerCoverage: @unchecked Sendable {
    private let lock = NSLock()
    private var ok: [WishType: Int] = [:], rejected: [WishType: Int] = [:]
    func add(_ type: WishType, ok passed: Bool) {
        lock.lock()
        if passed { ok[type, default: 0] += 1 } else { rejected[type, default: 0] += 1 }
        lock.unlock()
    }
    var counts: (ok: [WishType: Int], rejected: [WishType: Int]) {
        lock.lock(); defer { lock.unlock() }
        return (ok, rejected)
    }
}

// MARK: - Tests

struct DebugTriggerTests {
    static let screen = ResidentTests.screen
    static let t0 = Date(timeIntervalSince1970: 80_000)
    static let windowIDs: [WindowID] = [1, 2, 3, 4]
    static let utc = TimeZone(secondsFromGMT: 0)!

    fileprivate static func build(_ s: TriggerScenario) -> (WorldState, WishBook) {
        let snaps = s.windows.enumerated().map { i, w in
            WindowSnapshot(id: windowIDs[i], ownerName: "App\(i + 1)", ownerPID: 1,
                           frame: Rect(minX: Double(w.x), minY: Double(w.y), width: Double(w.width), height: 200),
                           zIndex: i + 1)
        }
        var table = WindowTable()
        let ids = Set(snaps.map(\.id))
        table.apply(.success(eligible: snaps, existingIDs: ids))
        let hidden = Set(windowIDs.indices.filter { s.hiddenMask & (1 << $0) != 0 }.map { windowIDs[$0] })
        if !hidden.isEmpty {
            table.apply(.success(eligible: snaps.filter { !hidden.contains($0.id) }, existingIDs: ids))
        }
        let surfaces = SurfaceBuilder.build(windows: table.visibleSnapshots, screen: screen)
        var world = WorldState(screen: screen, windows: table, surfaces: surfaces,
                               nav: NavGraph.build(surfaces: surfaces, constants: Tunables()))
        world.isNight = s.isNight

        func resident(_ id: ResidentID, _ r: TriggerResidentSpec) -> Resident {
            let attachment: CoreAttachment
            switch r.attach {
            case 0: attachment = .window(windowIDs[r.window], offset: r.frac * Double(s.windows[r.window].width))
            case 1: attachment = .ground(x: r.frac * screen.frame.width)
            default: attachment = .free(Point(x: r.frac * screen.frame.width, y: 200))
            }
            return Resident(id: id, state: ResidentState.allCases[r.state], attachment: attachment,
                            walkDistance: r.walk)
        }
        world.residents = [.a: resident(.a, s.a), .b: resident(.b, s.b)]

        var homes: [ResidentID: WindowID] = [:]
        if s.homeA > 0 { homes[.a] = windowIDs[s.homeA - 1] }
        if s.homeB > 0 { homes[.b] = windowIDs[s.homeB - 1] }
        world.story.homes = homes

        let b = s.book
        let single: [WishType] = [.chair, .lamp, .visit]
        var book = WishBook()
        func wish(_ type: WishType, _ wisher: ResidentID, visit: Int) -> Wish {
            let target = type == .visit ? VisitTarget(window: windowIDs[visit], ownerName: "App\(visit + 1)") : nil
            return Wish(id: book.makeID(), type: type, wisher: wisher, createdAt: t0, visitTarget: target,
                        chase: type == .chase ? ChaseState(readyAt: t0) : nil)
        }
        switch b.pattern {
        case 0: book.active = [wish(single[b.typeA], .a, visit: b.visitA)]
        case 1: book.active = [wish(single[b.typeB], .b, visit: b.visitB)]
        case 2: book.active = [wish(single[b.typeA], .a, visit: b.visitA), wish(single[b.typeB], .b, visit: b.visitB)]
        case 3: book.active = [wish(.flower, b.sharedWisherB ? .b : .a, visit: 0)]
        case 4: book.active = [wish(.chase, b.sharedWisherB ? .b : .a, visit: 0)]
        default: break
        }
        if let e = b.endedA { book.lastEnded[.a] = t0.addingTimeInterval(-Double(e)) }
        if let e = b.endedB { book.lastEnded[.b] = t0.addingTimeInterval(-Double(e)) }
        book.flowerCount = b.flowerCount
        book.lastFlowerDoneAt = b.flowerDone.map { t0.addingTimeInterval(-Double($0)) }
        return (world, book)
    }

    /// 参考：可作为 Visit_Target 的窗口（Requirement 6.3）——可见的 Eligible_Window，不是任何 Home_Window，
    /// 至少有一段 Window_Ledge，且不是另一个 active Visit_Wish 的目标。
    static func referenceVisitTargets(book: WishBook, world: WorldState, homes: [ResidentID: WindowID]) -> Set<WindowID> {
        let homeSet = Set(homes.values)
        let taken = Set(book.active.filter { $0.type == .visit }.compactMap { $0.visitTarget?.window })
        return Set(world.windows.visibleSnapshots.map(\.id).filter { id in
            !homeSet.contains(id) && !taken.contains(id) && world.surfaces.contains { $0.id.windowID == id }
        })
    }

    /// 参考：子项对应的居民（送花为下一次 Giver：第 1 次 A，之后交替；其余为给定的 Wisher）与 Requirement 17.2
    /// 的生成前提是否满足。不检查 Wish_Cooldown、Wish_Spawn_Chance、Walk_Distance、Night、Round_Interval。
    static func reference(
        _ type: WishType, wisher: ResidentID?, book: WishBook, world: WorldState, homes: [ResidentID: WindowID]
    ) -> (resident: ResidentID?, ok: Bool) {
        var busy: Set<ResidentID> = []
        for w in book.active {
            if w.type == .flower || w.type == .chase { busy.formUnion([.a, .b]) } else { busy.insert(w.wisher) }
        }
        let bothPresent = world.residents[.a] != nil && world.residents[.b] != nil
        switch type {
        case .flower:
            let giver: ResidentID = book.flowerCount % 2 == 0 ? .a : .b
            return (giver, bothPresent && busy.isEmpty)
        case .chair, .lamp:
            guard let r = wisher else { return (nil, false) }
            return (r, world.residents[r] != nil && !busy.contains(r))
        case .visit:
            guard let r = wisher else { return (nil, false) }
            let ok = world.residents[r] != nil && !busy.contains(r)
                && !referenceVisitTargets(book: book, world: world, homes: homes).isEmpty
            return (r, ok)
        case .chase:
            guard let r = wisher else { return (nil, false) }
            let air: Set<ResidentState> = [.falling, .hanging]
            let ok = bothPresent && busy.isEmpty
                && world.residents.values.allSatisfy { !air.contains($0.state) }
            return (r, ok)
        }
    }

    // Feature: V2, Property 49: Debug 触发心愿
    /// **Validates: Requirements 17.2, 17.3**
    ///
    /// 直接调用 `WishDirector.trigger`：前提满足时生成恰好一个以该子项居民为 Wisher（送花为下一次 Giver）的该类型
    /// active Wish，其余 Wish 不变；前提不满足时 WishBook、Unlocked_Decor、全部居民（含 Resident_State）
    /// 都不变，且不返回任何事件。
    @Test func triggerMatchesReferencePremise() async {
        let coverage = TriggerCoverage()
        await propertyCheck(count: 300, input: Gen.triggerScenario) { s in
            var (world, book) = Self.build(s)
            let ctx = WishContext(world: world, now: Self.t0)
            let homes = world.story.homes
            let (expectedWisher, ok) = Self.reference(s.type, wisher: s.wisher, book: book, world: world, homes: homes)
            let expectedTargets = Self.referenceVisitTargets(book: book, world: world, homes: homes)
            let bookBefore = book
            let residentsBefore = world.residents
            let unlockedBefore = world.decors.unlocked
            var rng = RandomSource(seed: s.seed)

            let events = WishDirector.trigger(s.type, wisher: s.wisher, book: &book, world: &world, ctx: ctx, rng: &rng)
            coverage.add(s.type, ok: ok)

            if ok {
                let added = book.active.filter { w in !bookBefore.active.contains { $0.id == w.id } }
                #expect(added.count == 1, "\(s)")
                guard let w = added.first else { return }
                #expect(w.type == s.type && w.state == .active, "\(s)")
                #expect(w.wisher == expectedWisher, "\(s)")
                #expect(w.createdAt == Self.t0, "\(s)")
                // 原有 Wish 原样保留。
                #expect(book.active.filter { $0.id != w.id } == bookBefore.active, "\(s)")
                #expect(events.first == .started(w), "\(s)")
                if s.type == .visit {
                    #expect(w.visitTarget.map { expectedTargets.contains($0.window) } == true, "\(s)")
                }
                if s.type == .chair || s.type == .lamp {
                    #expect(world.decors.unlocked.contains(s.type == .chair ? .chair : .lamp), "\(s)")
                }
                if s.type == .chase {
                    #expect(w.chase?.phase == .ready, "\(s)")
                    #expect(book.busy == [.a, .b], "\(s)")
                }
                if s.type == .flower {
                    #expect(book.flowerCount == bookBefore.flowerCount + 1, "\(s)")
                }
            } else {
                #expect(events.isEmpty, "\(s)")
                #expect(book == bookBefore, "\(s)")
                #expect(book.busy == bookBefore.busy, "\(s)")
                #expect(world.decors.unlocked == unlockedBefore, "\(s)")
                #expect(world.residents == residentsBefore, "\(s)")
            }
        }
        let counts = coverage.counts
        for t in WishType.allCases {
            #expect(counts.ok[t, default: 0] > 0, "\(t) never passed")
            #expect(counts.rejected[t, default: 0] > 0, "\(t) never rejected")
        }
    }

    fileprivate final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now = Date(timeIntervalSince1970: 1_800_000_000)   // UTC 08:00

        init(windows: Int, seed: UInt64) {
            let all = [
                StoryEngineTests.win(1, x: 100, y: 400),
                StoryEngineTests.win(2, x: 900, y: 400),
                StoryEngineTests.win(3, x: 400, y: 300),
                StoryEngineTests.win(4, x: 1150, y: 200),
            ]
            source = FakeWindowSource(snapshots: Array(all.prefix(windows)))
            engine = WorldEngine(clockStart: now, screen: DebugTriggerTests.screen, rng: RandomSource(seed: seed))
        }

        /// 推进一帧。推迟 WishDirector 的自动检查，使本帧的 Wish 只来自 Debug 触发。
        @discardableResult
        func step(_ commands: [Command] = []) -> StepOutput {
            if engine.state.wishes.nextCheckAt != nil {
                engine.state.wishes.nextCheckAt = now.addingTimeInterval(1_000_000)
            }
            now = now.addingTimeInterval(1.0 / 30)
            return engine.step(FrameInput(poll: source.poll(), screen: DebugTriggerTests.screen,
                                          commands: commands, now: now, timeZone: DebugTriggerTests.utc))
        }
    }

    // Feature: V2, Property 49: Debug 触发心愿
    /// **Validates: Requirements 17.2, 17.3**
    ///
    /// 通过 `WorldEngine` 的 `Command.triggerWish`：前提满足时同一次 step（远小于 1 秒）结束时存在以该子项居民为
    /// Wisher（送花为下一次 Giver）的该类型 active Wish，并写入对应的 `wish_started` 记录；前提不满足时 active
    /// Wish、Busy_Resident 身份、Unlocked_Decor 不变，且不写 `wish_*` 或 `decor_unlocked` 记录。Night 不影响结果。
    @Test func engineTriggerCommand() async {
        let coverage = TriggerCoverage()
        await propertyCheck(count: 100, input: Gen.engineTrigger) { s in
            let h = Harness(windows: s.windowCount, seed: s.seed)
            h.step(s.night ? [.setDayNight(.night)] : [])            // 首帧：分配家并放置两位居民
            for _ in 0 ..< s.preFrames { h.step() }
            if let (t, w) = s.first { h.step([.triggerWish(t, w)]) }
            for _ in 0 ..< s.gapFrames { h.step() }

            let state = h.engine.state
            let bookBefore = state.wishes
            let unlockedBefore = state.decors.unlocked
            let (expectedWisher, ok) = Self.reference(
                s.type, wisher: s.wisher, book: bookBefore, world: state, homes: state.story.homes)
            coverage.add(s.type, ok: ok)

            let out = h.step([.triggerWish(s.type, s.wisher)])
            let after = h.engine.state.wishes
            let wishRecords = out.events.filter {
                [.wishStarted, .wishFulfilled, .wishDropped, .decorUnlocked].contains($0.type)
            }
            if ok {
                let added = after.active.filter { w in !bookBefore.active.contains { $0.id == w.id } }
                #expect(added.count == 1, "\(s)")
                guard let w = added.first else { return }
                #expect(w.type == s.type && w.wisher == expectedWisher, "\(s)")
                let started = out.events.filter { $0.type == .wishStarted }
                #expect(started.count == 1, "\(s)")
                #expect(started.first?.actor == expectedWisher.map { EventRecord.residentRef($0) }, "\(s)")
                #expect(started.first?.detail["wish_type"] == s.type.rawValue, "\(s)")
            } else {
                #expect(after.active.map(\.id) == bookBefore.active.map(\.id), "\(s)")
                #expect(after.busy == bookBefore.busy, "\(s)")
                #expect(h.engine.state.decors.unlocked == unlockedBefore, "\(s)")
                #expect(wishRecords.isEmpty, "\(wishRecords.map(\.type)); \(s)")
            }
        }
        let counts = coverage.counts
        for t in WishType.allCases {
            #expect(counts.ok[t, default: 0] > 0, "\(t) never passed in engine")
            #expect(counts.rejected[t, default: 0] > 0, "\(t) never rejected in engine")
        }
    }
}
