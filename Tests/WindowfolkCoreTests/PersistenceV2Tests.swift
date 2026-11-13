import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// 存档 v2 的属性测试（V2 design.md Property 44 至 48 中的 44、45）。
// 世界状态直接构造：两个窗口（窗口 1 可见、窗口 2 隐藏且保留最后可见快照）、0 到 Max_Decor_Count 个 Decor
// （Ground、窗沿、下落中、至多一个拖动中）、两位居民（Walk_Distance、上一个 Wish 结束时间）、
// 满足结构不变量的 active Wish（无、Flower、Chase、一或两个单人 Wish）。时间带亚毫秒小数，检验取整规则。

/// 一个 Decor 的生成参数。
fileprivate struct DecorSpec: Sendable {
    var type: DecorType
    var kind: Int        // 0 Ground；1 窗沿；2 下落中；3 拖动中（只保留第一个，其余按 Ground）
    var x: Double
    var onHidden: Bool   // 窗沿：附着在隐藏的窗口 2 上
    var gap: UInt64      // 与上一个 DecorID 的间隔
}

/// 单人 Wish（chair、lamp、visit）的生成参数。
fileprivate struct SoloSpec: Sendable {
    var type: WishType
    var createdAt: Double
    var app: String
}

fileprivate struct WorldSpec: Sendable {
    var decors: [DecorSpec]
    var unlocked: [DecorType]
    var walk: (Double, Double)
    var lastEnded: (Double?, Double?)
    var flowerCount: Int
    var lastFlowerDoneAt: Double?
    var wishShape: Int   // 0 无；1 Flower；2 Chase；3 一个单人 Wish；4 两个单人 Wish
    var wisherIsA: Bool
    var chaseRunning: Bool
    var flowerCreatedAt: Double
    var solos: (SoloSpec, SoloSpec)
    var grab: Point
    var pointer: Point
    var now: Double
}

fileprivate let screen = ScreenInfo(
    frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
    visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 850))

fileprivate let window1 = WindowSnapshot(id: 1, ownerName: "Notes", ownerPID: 1,
                                         frame: Rect(minX: 120.5, minY: 300, width: 400, height: 300), zIndex: 0)
fileprivate let window2 = WindowSnapshot(id: 2, ownerName: "Safari", ownerPID: 2,
                                         frame: Rect(minX: 800.25, minY: 200, width: 500, height: 400), zIndex: 1)

/// 1990 到 2100 年之间、带亚毫秒小数的时间（秒）。
fileprivate let rawTime = zip(Gen<Int>.int(in: 631_152_000...4_102_444_800), Gen<Double>.double(in: 0..<1))
    .map { Double($0) + $1 }

fileprivate let decorSpec = zip(
    Gen<DecorType>.case, Gen<Int>.int(in: 0...3), Gen<Double>.double(in: -200...1700),
    Gen<Bool>.bool, Gen<UInt64>.value(in: 1...5)
).map { DecorSpec(type: $0, kind: $1, x: $2, onHidden: $3, gap: $4) }

fileprivate let soloSpec = zip(
    Gen<WishType?>.element(of: [WishType.chair, .lamp, .visit]).map { $0! },
    rawTime,
    Gen<String?>.element(of: ["Notes", "Safari", "备忘录", "Visual Studio Code", ""]).map { $0! }
).map { SoloSpec(type: $0, createdAt: $1, app: $2) }

fileprivate let point = zip(Gen<Double>.double(in: -100...1600), Gen<Double>.double(in: -100...1000))
    .map { Point(x: $0, y: $1) }

fileprivate let worldSpec = zip(
    decorSpec.array(of: 0...Tunables().maxDecorCount),
    Gen<DecorType>.case.array(of: 0...3),
    zip(Gen<Double>.double(in: 0...10_000), Gen<Double>.double(in: 0...10_000)),
    zip(rawTime.optional(), rawTime.optional()),
    zip(Gen<Int>.int(in: 0...1000), rawTime.optional()),
    zip(Gen<Int>.int(in: 0...4), Gen<Bool>.bool, Gen<Bool>.bool, rawTime),
    zip(soloSpec, soloSpec),
    zip(point, point, rawTime)
).map { decors, unlocked, walk, ended, flower, shape, solos, misc in
    WorldSpec(decors: decors, unlocked: unlocked, walk: walk, lastEnded: ended,
              flowerCount: flower.0, lastFlowerDoneAt: flower.1,
              wishShape: shape.0, wisherIsA: shape.1, chaseRunning: shape.2, flowerCreatedAt: shape.3,
              solos: solos, grab: misc.0, pointer: misc.1, now: misc.2)
}

/// 由生成参数构造的世界和按 design 规则独立算出的期望快照内容。
fileprivate struct Built {
    var world: WorldState
    var decorObjects: [SavedObject]
    var wishes: [SavedWish]
    var chase: Bool
}

fileprivate func date(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }

fileprivate func build(_ s: WorldSpec) -> Built {
    var world = WorldState(screen: screen, windows: WindowTable(records: [
        1: WindowRecord(snapshot: window1, visibility: .visible),
        2: WindowRecord(snapshot: window2, visibility: .hidden),
    ]))
    world.residents = [
        .a: Resident(id: .a, attachment: .ground(x: 300), walkDistance: s.walk.0),
        .b: Resident(id: .b, attachment: .ground(x: 900), walkDistance: s.walk.1),
    ]

    var decors: [DecorID: Decor] = [:]
    var expected: [SavedObject] = []
    var raw: UInt64 = 0
    var dragged = false
    for d in s.decors {
        raw += d.gap
        let id = DecorID(raw)
        let placement: DecorPlacement
        let x: Double
        switch d.kind {
        case 1:
            let w = d.onHidden ? window2 : window1
            let offset = min(max(d.x, 0), w.frame.width)
            placement = .attached(.window(w.id, offset: offset))
            x = w.frame.minX + offset
        case 2:
            placement = .falling(FallState(position: Point(x: d.x, y: 120), velocityY: 30), byPlayer: d.onHidden)
            x = d.x
        case 3 where !dragged:
            dragged = true
            placement = .dragged(grabOffset: s.grab, fresh: d.onHidden)
            world.gesture = .dragging(.decor(id), grabOffset: s.grab, pointer: s.pointer)
            x = s.pointer.x - s.grab.x
        default:
            placement = .attached(.ground(x: d.x))
            x = d.x
        }
        decors[id] = Decor(id: id, type: d.type, placement: placement)
        expected.append(SavedObject(id: "decor:\(raw)", kind: d.type == .chair ? .chair : .lamp, x: x))
    }
    world.decors = DecorStore(decors: decors, unlocked: Set(s.unlocked))

    let wisher: ResidentID = s.wisherIsA ? .a : .b
    var active: [Wish] = []
    var wishes: [SavedWish] = []
    func solo(_ spec: SoloSpec, _ r: ResidentID, id: UInt64) {
        let target = spec.type == .visit ? VisitTarget(window: 1, ownerName: spec.app) : nil
        active.append(Wish(id: WishID(id), type: spec.type, wisher: r, createdAt: date(spec.createdAt),
                           visitTarget: target))
        wishes.append(SavedWish(type: spec.type, wisher: r, createdAt: SaveTime.normalized(date(spec.createdAt)),
                                visitTargetApp: spec.app))
    }
    switch s.wishShape {
    case 1:
        active = [Wish(id: WishID(1), type: .flower, wisher: wisher, createdAt: date(s.flowerCreatedAt))]
        wishes = [SavedWish(type: .flower, wisher: wisher, createdAt: SaveTime.normalized(date(s.flowerCreatedAt)))]
    case 2:
        let ready = date(s.flowerCreatedAt)
        let chase = ChaseState(phase: s.chaseRunning ? .running : .ready, readyAt: ready,
                               runningAt: s.chaseRunning ? ready.addingTimeInterval(1.5) : nil)
        active = [Wish(id: WishID(1), type: .chase, wisher: wisher, createdAt: ready, chase: chase)]
    case 3:
        solo(s.solos.0, wisher, id: 1)
    case 4:
        solo(s.solos.0, .a, id: 1)
        solo(s.solos.1, .b, id: 2)
    default:
        break
    }
    // 追逐不改 `lastEnded`：这里的值就是追逐开始前的值。
    var lastEnded: [ResidentID: Date] = [:]
    lastEnded[.a] = s.lastEnded.0.map(date)
    lastEnded[.b] = s.lastEnded.1.map(date)
    let count = s.wishShape == 1 ? max(s.flowerCount, 1) : s.flowerCount
    world.wishes = WishBook(active: active, lastEnded: lastEnded, flowerCount: count,
                            lastFlowerDoneAt: s.lastFlowerDoneAt.map(date))
    return Built(world: world, decorObjects: expected, wishes: wishes, chase: s.wishShape == 2)
}

// MARK: - Property 45 的生成器
//
// 恢复场景直接构造：0 到 4 个窗口（应用名称来自小名称池，可见或隐藏，zIndex 可重复），两位居民可能有 Home_Window，
// 存档的 Story_Stage 为未开局、进行中（任一非 done 阶段）或 done（旧存档），存档中的 active Wish 形状为
// 无、Flower、Chase（直接写入存档模拟异常文件，正常保存不会写）、一或两个单人 Wish（chair、lamp、visit）。
// 进行中的 Story_Stage 只与「无」或「Flower」搭配（合法存档里 Flower_Wish 进行中两人都是 Busy_Resident）。
// 单人 Wish 的年龄落在 Wish_Timeout 之内、恰好等于、或之外；Visit_Wish 的应用名称可能匹配不到窗口（"Mail"）。

fileprivate struct RWindowSpec: Sendable {
    var name: String
    var zIndex: Int
    var visible: Bool
}

fileprivate struct RSoloSpec: Sendable {
    var type: WishType
    var age: Double
    var app: String
}

fileprivate struct WishRestoreSpec: Sendable {
    var windows: [RWindowSpec]
    var homes: (Int?, Int?)
    var stageKind: Int        // 0 未开局；1 进行中；2 done
    var stage: StoryStage     // stageKind == 1 时的阶段
    var round: Int
    var flowerCount: Int
    var lastFlowerDoneAge: Double?
    var doneAge: Double?
    var shape: Int            // 0 无；1 Flower；2 Chase；3 一个单人 Wish；4 两个单人 Wish
    var wisherIsA: Bool
    var flowerAge: Double
    var solos: (RSoloSpec, RSoloSpec)
    var lastEndedAge: (Double?, Double?)
    var unlocked: [DecorType]
    var now: Int
}

fileprivate let rNames = ["Notes", "Safari", "备忘录"]
fileprivate let rWindowSpec = zip(
    Gen<String?>.element(of: rNames).map { $0! }, Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...3)
).map { RWindowSpec(name: $0, zIndex: $1, visible: $2 != 0) }

/// 单人 Wish 的年龄：Wish_Timeout 之内、恰好等于 Wish_Timeout、或超过。
fileprivate let rAge = zip(
    Gen<Int>.int(in: 0...2), Gen<Double>.double(in: 0..<Tunables().wishTimeout),
    Gen<Double>.double(in: (Tunables().wishTimeout + 0.001)...(Tunables().wishTimeout * 4))
).map { k, fresh, stale in k == 0 ? fresh : (k == 1 ? Tunables().wishTimeout : stale) }

fileprivate let rSoloSpec = zip(
    Gen<WishType?>.element(of: [WishType.chair, .lamp, .visit]).map { $0! }, rAge,
    Gen<String?>.element(of: rNames + ["Mail"]).map { $0! }
).map { RSoloSpec(type: $0, age: $1, app: $2) }

fileprivate let rPastAge = Gen<Double>.double(in: 0...20_000).optional()

fileprivate let wishRestoreSpec = zip(
    rWindowSpec.array(of: 0...4),
    zip(Gen<Int>.int(in: 0...3).optional(), Gen<Int>.int(in: 0...3).optional()),
    zip(Gen<Int>.int(in: 0...2), Gen<StoryStage?>.element(of: StoryStage.allCases.filter { $0 != .done })
        .map { $0! }, Gen<Int>.int(in: 1...6), Gen<Int>.int(in: 0...8)),
    zip(rPastAge, rPastAge),
    zip(Gen<Int>.int(in: 0...4), Gen<Bool>.bool, Gen<Double>.double(in: 0...(Tunables().wishTimeout * 10))),
    zip(rSoloSpec, rSoloSpec),
    zip(rPastAge, rPastAge, Gen<DecorType>.case.array(of: 0...3)),
    Gen<Int>.int(in: 1_000_000_000...4_000_000_000)
).map { windows, homes, story, flowerTimes, shape, solos, misc, now in
    // 进行中的 Story_Stage 只与「无」或「Flower」搭配。
    let stageKind = story.0 == 1 && shape.0 >= 2 ? 0 : story.0
    return WishRestoreSpec(
        windows: windows, homes: homes, stageKind: stageKind, stage: story.1, round: story.2,
        flowerCount: story.3, lastFlowerDoneAge: flowerTimes.0, doneAge: flowerTimes.1,
        shape: shape.0, wisherIsA: shape.1, flowerAge: shape.2, solos: solos,
        lastEndedAge: (misc.0, misc.1), unlocked: misc.2, now: now)
}

struct PersistenceV2Tests {
    // Feature: V2, Property 45: Wish 恢复规则
    // **Validates: Requirements 15.3, 15.8, 15.9, 15.11**
    //
    // 走 WorldEngine 恢复时的同一条路径：`SaveSnapshot.restore` → 设置 Home_Window → `restoreWishes`。
    // WorldEngine 只为 `restoreWishes` 返回的 Wish 写 `wish_dropped`，因此这里检查返回值即检查写入的记录。
    @Test func wishRestoreRules() async {
        await propertyCheck(count: 200, input: wishRestoreSpec) { spec in
            let c = Tunables()
            let now = Date(timeIntervalSince1970: Double(spec.now))
            func ago(_ age: Double) -> Date { Date(timeIntervalSince1970: Double(spec.now) - age) }

            // 当前窗口。
            var records: [WindowID: WindowRecord] = [:]
            var snapshots: [WindowSnapshot] = []
            for (i, w) in spec.windows.enumerated() {
                let snap = WindowSnapshot(
                    id: WindowID(i + 1), ownerName: w.name, ownerPID: Int32(i + 1),
                    frame: Rect(minX: Double(i) * 300 + 50, minY: 300, width: 250, height: 200), zIndex: w.zIndex)
                records[snap.id] = WindowRecord(snapshot: snap, visibility: w.visible ? .visible : .hidden)
                snapshots.append(snap)
            }
            var world = WorldState(screen: screen, windows: WindowTable(records: records))

            // 存档。
            let stage: StoryStage? = [nil, spec.stage, .done][spec.stageKind]
            let giver = StoryDirector.giver(round: spec.round)
            let flowerWisher: ResidentID = spec.stageKind == 1 ? giver : (spec.wisherIsA ? .a : .b)
            var saved: [SavedWish] = []
            switch spec.shape {
            case 1:
                saved = [SavedWish(type: .flower, wisher: flowerWisher, createdAt: ago(spec.flowerAge))]
            case 3:
                let s = spec.solos.0
                saved = [SavedWish(type: s.type, wisher: spec.wisherIsA ? .a : .b, createdAt: ago(s.age),
                                   visitTargetApp: s.app)]
            case 4:
                saved = [(ResidentID.a, spec.solos.0), (.b, spec.solos.1)].map { r, s in
                    SavedWish(type: s.type, wisher: r, createdAt: ago(s.age), visitTargetApp: s.app)
                }
            default:
                break
            }
            let lastEnded: [ResidentID: Date] = [
                .a: spec.lastEndedAge.0.map(ago), .b: spec.lastEndedAge.1.map(ago),
            ].compactMapValues { $0 }
            var save = SaveFile(
                savedAt: now,
                story: SavedStory(stage: stage, round: spec.round, doneAt: spec.doneAge.map(ago)),
                residents: [SavedResident(id: .a, x: 300, lastWishEndedAt: lastEnded[.a]),
                            SavedResident(id: .b, x: 900, lastWishEndedAt: lastEnded[.b])],
                groundObjects: [],
                wishBook: SavedWishBook(unlockedDecor: spec.unlocked, flowerCount: spec.flowerCount,
                                        lastFlowerDoneAt: spec.lastFlowerDoneAge.map(ago), activeWishes: saved))
            if spec.shape == 2 {
                // 正常保存不会写 Chase_Wish；直接写入模拟异常存档，恢复时也不得出现。
                save.wishBook.activeWishes.append(
                    SavedWish(type: .chase, wisher: spec.wisherIsA ? .a : .b, createdAt: now))
            }

            // 恢复（与 WorldEngine.applyPendingRestore 的顺序相同）。
            SaveSnapshot.restore(save, into: &world, now: now, constants: c)
            var homes: [ResidentID: WindowID] = [:]
            if !snapshots.isEmpty {
                if let h = spec.homes.0 { homes[.a] = WindowID(h % snapshots.count + 1) }
                if let h = spec.homes.1 { homes[.b] = WindowID(h % snapshots.count + 1) }
            }
            world.story.homes = homes
            let dropped = SaveSnapshot.restoreWishes(save, into: &world, now: now, constants: c)
            let book = world.wishes

            // 期望值（按 Requirement 15.3、15.4、15.8、15.11 独立计算）。
            let storyActive = spec.stageKind == 1
            var expectedActive: [ResidentID: (WishType, Date)] = [:]
            var expectedDropped: [SavedWish] = []
            var expectedLastEnded = lastEnded
            if storyActive {
                // Flower_Wish 无条件恢复（存档里没有时补一个，创建时间取恢复时刻），Wisher 为本轮 Giver。
                let created = save.wishBook.activeWishes.first { $0.type == .flower }?.createdAt ?? now
                expectedActive[giver] = (.flower, created)
            }
            let homeSet = Set(homes.values)
            for s in save.wishBook.activeWishes where s.type != .flower && s.type != .chase {
                let fresh = now.timeIntervalSince(s.createdAt) < c.wishTimeout
                let matched = s.type != .visit || snapshots.contains {
                    records[$0.id]?.visibility == .visible && $0.ownerName == s.visitTargetApp
                        && !homeSet.contains($0.id)
                }
                if fresh && matched {
                    expectedActive[s.wisher] = (s.type, s.createdAt)
                } else {
                    expectedDropped.append(s)
                    expectedLastEnded[s.wisher] = now
                }
            }

            // 恢复后的 active Wish：类型、Wisher、创建时间与期望一致；Flower_Wish 以外的 dropped Wish 按存档顺序返回
            // （即写入的 `wish_dropped` 记录）；无 Story_Stage 的 Flower_Wish 和 Chase_Wish 都不写记录。
            #expect(dropped == expectedDropped)
            #expect(book.active.count == expectedActive.count)
            for w in book.active {
                #expect(w.state == .active)
                let e = expectedActive[w.wisher]
                #expect(e?.0 == w.type, "wisher \(w.wisher): got \(w.type), expected \(String(describing: e?.0))")
                #expect(e?.1 == w.createdAt)
            }
            #expect(Set(book.active.map(\.id)).count == book.active.count)
            // 恢复后不存在 Chase_Wish。
            #expect(!book.active.contains { $0.type == .chase })

            // 每位居民至多参与 1 个 active Wish。
            for r in ResidentID.allCases {
                #expect(book.active.filter { $0.participants.contains(r) }.count <= 1)
            }

            // dropped 的 Wish 不显示 Wish_Bubble 和 Visit_Flag：两者只由 active Wish 产生（`applyWishBubbles`、
            // `visitFlags`），因此检查 dropped 的 Wisher 不参与任何 active Wish，且 active Visit_Wish 只有恢复成功的那些。
            for s in expectedDropped {
                #expect(book.wish(of: s.wisher) == nil)
            }
            let activeVisits = book.active.filter { $0.type == .visit }
            #expect(activeVisits.allSatisfy { $0.visitTarget != nil })
            #expect(activeVisits.count == expectedActive.values.filter { $0.0 == .visit }.count)

            // 冷却：dropped 的 Wisher 从恢复时刻起算，其他居民为保存的结束时间（Requirement 15.8、15.9）。
            #expect(book.lastEnded == expectedLastEnded)
            var idle = book
            idle.active = []
            for (r, t) in expectedLastEnded {
                #expect(!WishDirector.cooledDown(r, book: idle, now: t.addingTimeInterval(c.wishCooldown - 1),
                                                 constants: c))
                #expect(WishDirector.cooledDown(r, book: idle, now: t.addingTimeInterval(c.wishCooldown),
                                                constants: c))
            }

            // Story_Stage：done 的旧存档视为已完成；Flower_Wish 次数至少为 Story_Round（Requirement 15.3、15.11）。
            switch spec.stageKind {
            case 1:
                #expect(world.story.stage != nil && world.story.stage != .done)
                #expect(world.story.round == spec.round)
                #expect(book.flowerCount == max(spec.flowerCount, spec.round))
                #expect(book.lastFlowerDoneAt == spec.lastFlowerDoneAge.map(ago))
            case 2:
                #expect(world.story.stage == nil)
                #expect(book.flowerCount == max(spec.flowerCount, spec.round))
                #expect(book.lastFlowerDoneAt == (spec.lastFlowerDoneAge ?? spec.doneAge).map(ago))
            default:
                #expect(world.story.stage == nil)
                #expect(book.flowerCount == spec.flowerCount)
                #expect(book.lastFlowerDoneAt == spec.lastFlowerDoneAge.map(ago))
            }

            // 恢复不改 Unlocked_Decor（不会因恢复 Chair_Wish 或 Lamp_Wish 而解锁，即不写 `decor_unlocked`）。
            #expect(world.decors.unlocked == Set(spec.unlocked))
        }
    }

    // Feature: V2, Property 44: 存档 v2 往返
    // **Validates: Requirements 1.8, 15.1, 15.6, 15.11**
    @Test func saveV2RoundTrip() async {
        await propertyCheck(count: 100, input: worldSpec) { spec in
            let b = build(spec)
            let world = b.world
            let s = SaveSnapshot.snapshot(world: world, now: date(spec.now))

            // 往返：decode(encode(snapshot)) == snapshot。
            guard let data = try? SaveCodec.encode(s) else {
                Issue.record("encode failed")
                return
            }
            #expect((try? SaveCodec.decode(data)) == s)
            #expect(s.version == 2)

            // Unlocked_Decor。
            #expect(s.wishBook.unlockedDecor == world.decors.unlocked.sorted())

            // 每个 Decor 的类型和 x（SaveFile 按 id 字符串排序 Ground_Object）。
            let decorObjects = s.groundObjects.filter { $0.kind == .chair || $0.kind == .lamp }
            #expect(decorObjects == b.decorObjects.sorted { $0.id < $1.id })
            #expect(s.groundObjects.count == decorObjects.count)

            // 每位居民的 Walk_Distance 和上一个 Wish 结束时间（追逐中保存时即追逐开始前的值）。
            #expect(s.residents.map(\.id) == [.a, .b])
            for r in s.residents {
                #expect(r.walkDistance == world.residents[r.id]?.walkDistance)
                #expect(r.lastWishEndedAt == world.wishes.lastEnded[r.id].map(SaveTime.normalized))
            }

            // 非 chase 的 active Wish；快照中没有 Chase_Wish。
            #expect(s.wishBook.activeWishes == b.wishes.sorted(by: SavedWish.ordered))
            #expect(!s.wishBook.activeWishes.contains { $0.type == .chase })
            if b.chase { #expect(s.wishBook.activeWishes.isEmpty) }

            // Flower_Wish 次数和上一个 Flower_Wish 进入 Done 的时间。
            #expect(s.wishBook.flowerCount == world.wishes.flowerCount)
            #expect(s.wishBook.lastFlowerDoneAt == world.wishes.lastFlowerDoneAt.map(SaveTime.normalized))
        }
    }
}
