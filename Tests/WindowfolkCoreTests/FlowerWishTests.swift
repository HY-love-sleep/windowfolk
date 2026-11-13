import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 送花心愿属性测试。
// - Property 24（任务 7.11）：快进。
// - Property 23（任务 7.10）：送花轮换（在本文件追加）。

// MARK: - 生成器（Property 24）

/// 一朵花：种下后已生长时长（以 Bloom_Duration 为单位，可为负表示时钟回拨到种下之前）、
/// `reached` 比按时长算出的阶段多出的级数（模拟时钟回拨后不倒退），是否已种下。
fileprivate struct FastForwardFlowerSpec: Sendable {
    var elapsedFraction: Double
    var reachedBump: Int
    var planted: Bool
}

/// 快进前的世界。
fileprivate struct FastForwardScenario: Sendable {
    /// Story_Clock 当前读数相对基准时间的秒数（含小数，模拟逐帧推进）。
    var nowOffset: Double
    var bloomDuration: Double
    var roundInterval: Double
    /// 0 无 active Wish；1 Flower_Wish；2 A 的 Chair_Wish；3 A 的 Lamp_Wish 与 B 的 Visit_Wish；4 Chase_Wish。
    var activePattern: Int
    /// `StoryStage.allCases` 下标；等于 `allCases.count` 时为 nil（未开局）。
    var stageIndex: Int
    /// 当前轮的 Story_Flower；nil 表示没有。
    var current: FastForwardFlowerSpec?
    /// 场上其余的花（往轮 Story_Flower）。
    var others: [FastForwardFlowerSpec]
    var flowerCount: Int
    /// 距上一个 Flower_Wish 进入 Done 的时长（以 Round_Interval 为单位，负值表示时钟回拨）；nil 为从未有过。
    var doneFraction: Double?
    /// 距下一次检查的秒数；nil 为未开始调度。
    var nextCheck: Double?
    /// 距 A、B 上一个 Wish 结束的秒数；nil 为从未参与。
    var endedA: Double?, endedB: Double?
}

fileprivate extension Gen where Value == FastForwardScenario {
    static var fastForwardFlower: Generator<FastForwardFlowerSpec, some SendableSequenceType> {
        zip(Gen<Double>.double(in: -0.3...1.5), Gen<Int>.int(in: 0...3), Gen<Bool>.bool(0.9))
            .map { FastForwardFlowerSpec(elapsedFraction: $0, reachedBump: $1 >= 2 ? $1 - 2 : 0, planted: $2) }
    }

    static var fastForwardScenario: Generator<FastForwardScenario, some SendableSequenceType> {
        zip(
            zip(Gen<Double>.double(in: 0...200_000), Gen<Double>.double(in: 1...600), Gen<Double>.double(in: 1...600)),
            // 让 Flower_Wish 和「没有 active Wish」各占较多比例，Growing 更常出现。
            zip(Gen<Int>.int(in: 0...7), Gen<Int>.int(in: 0...(StoryStage.allCases.count + 3))),
            zip(fastForwardFlower.optional(valueRate: 0.85), fastForwardFlower.array(of: 0...3)),
            zip(Gen<Int>.int(in: 0...7), Gen<Double>.double(in: -0.2...2).optional(valueRate: 0.75)),
            zip(Gen<Double>.double(in: -20...20).optional(valueRate: 0.8),
                Gen<Double>.double(in: 0...400).optional(valueRate: 0.6),
                Gen<Double>.double(in: 0...400).optional(valueRate: 0.6))
        ).map { time, wish, flowers, flower, misc in
            // 活动模式：0–2 Flower_Wish，3–4 无，5–7 其余。
            let pattern = wish.0 <= 2 ? 1 : (wish.0 <= 4 ? 0 : wish.0 - 3)
            // 阶段下标：多出的 3 个值都映射到 Growing。
            let growing = StoryStage.allCases.firstIndex(of: .growing)!
            let stage = wish.1 > StoryStage.allCases.count ? growing : wish.1
            return FastForwardScenario(
                nowOffset: time.0, bloomDuration: time.1, roundInterval: time.2,
                activePattern: pattern, stageIndex: stage,
                current: flowers.0, others: flowers.1,
                flowerCount: flower.0, doneFraction: flower.1,
                nextCheck: misc.0, endedA: misc.1, endedB: misc.2)
        }
    }
}

// MARK: - Property 24

struct FlowerWishTests {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// 由场景构造的快进前状态。
    fileprivate struct Built {
        var book: WishBook
        var world: WorldState
        var constants: Tunables
        var now: Date
        var currentID: ItemID?
        var stage: StoryStage?
    }

    fileprivate static func build(_ s: FastForwardScenario) -> Built {
        var c = Tunables()
        c.bloomDuration = s.bloomDuration
        c.roundInterval = s.roundInterval
        let now = base.addingTimeInterval(s.nowOffset)

        func flower(_ f: FastForwardFlowerSpec, round: Int) -> Item {
            var g = FlowerGrowth()
            if f.planted {
                let planted = now.addingTimeInterval(-f.elapsedFraction * s.bloomDuration)
                let computed = Growth.stage(elapsed: now.timeIntervalSince(planted), bloomDuration: s.bloomDuration)
                let reached = GrowthStage(rawValue: min(computed.rawValue + f.reachedBump, 2))!
                g = FlowerGrowth(plantedAt: planted, reached: reached)
            }
            return Item(kind: .flower(storyRound: round), placement: .dragged(grabOffset: Point(x: 0, y: 0)),
                        growth: g)
        }

        let flowerActive = s.activePattern == 1
        // 有 active Flower_Wish 时至少开始过 1 次；有过 Done 时也至少开始过 1 次（数据自洽）。
        var count = s.flowerCount
        if flowerActive || s.doneFraction != nil { count = max(count, 1) }
        let doneAt = s.doneFraction.map { now.addingTimeInterval(-$0 * s.roundInterval) }

        var items: [ItemID: Item] = [:]
        var currentID: ItemID?
        if let cur = s.current {
            let item = flower(cur, round: max(count, 1))
            items[item.id] = item
            currentID = item.id
        }
        for (i, o) in s.others.enumerated() {
            let item = flower(o, round: i + 1)
            items[item.id] = item
        }

        let created = now.addingTimeInterval(-5)
        var active: [Wish] = []
        switch s.activePattern {
        case 1:
            active = [Wish(id: WishID(1), type: .flower, wisher: StoryDirector.giver(round: count), createdAt: created)]
        case 2:
            active = [Wish(id: WishID(1), type: .chair, wisher: .a, createdAt: created)]
        case 3:
            active = [
                Wish(id: WishID(1), type: .lamp, wisher: .a, createdAt: created),
                Wish(id: WishID(2), type: .visit, wisher: .b, createdAt: created,
                     visitTarget: VisitTarget(window: 2, ownerName: "App2")),
            ]
        case 4:
            active = [Wish(id: WishID(1), type: .chase, wisher: .a, createdAt: created,
                           chase: ChaseState(readyAt: created))]
        default:
            break
        }
        var ended: [ResidentID: Date] = [:]
        if let e = s.endedA { ended[.a] = now.addingTimeInterval(-e) }
        if let e = s.endedB { ended[.b] = now.addingTimeInterval(-e) }
        let book = WishBook(active: active, lastEnded: ended, flowerCount: count, lastFlowerDoneAt: doneAt,
                            nextCheckAt: s.nextCheck.map { now.addingTimeInterval($0) })

        let stage: StoryStage? = s.stageIndex < StoryStage.allCases.count ? StoryStage.allCases[s.stageIndex] : nil
        let story = StoryState(stage: stage, round: max(count, 1), currentFlower: currentID, doneAt: doneAt)
        let world = WorldState(screen: WorldState.emptyScreen, items: ItemStore(items: items), story: story)
        return Built(book: book, world: world, constants: c, now: now, currentID: currentID, stage: stage)
    }

    /// 全部花的 Growth_Stage。
    static func stages(_ w: WorldState) -> [ItemID: GrowthStage?] {
        w.items.items.mapValues { $0.stage }
    }

    // Feature: V2, Property 24: 快进
    /// **Validates: Requirements 8.8, 8.9, 8.10**
    @Test func fastForward() async {
        await propertyCheck(count: 200, input: Gen.fastForwardScenario) { s in
            let b = Self.build(s)
            var book = b.book
            var world = b.world
            let c = b.constants
            let now = b.now
            let events = WishDirector.fastForward(&book, world: &world, constants: c, now: now)

            let flowerActive = b.book.active.contains { $0.type == .flower }
            let waiting = b.book.lastFlowerDoneAt.map { now.timeIntervalSince($0) < c.roundInterval } ?? false

            // 不论哪种情况：Story_Stage、Wish_State、下一次 Giver、已开始次数都不变。
            #expect(world.story.stage == b.stage)
            #expect(book.active == b.book.active)
            #expect(WishDirector.nextFlowerGiver(book) == WishDirector.nextFlowerGiver(b.book))
            #expect(book.flowerCount == b.book.flowerCount)

            if flowerActive && b.stage == .growing {
                // Requirement 8.8：Story_Flower 恰好进入下一个 Growth_Stage，从该阶段起始时长继续计时。
                #expect(book == b.book)
                guard let id = b.currentID, let before = b.world.items[id]?.growth,
                      before.plantedAt != nil, before.reached < .bloom else {
                    // 已是 bloom（下一次更新才进入 Bloomed）：没有下一个阶段，不变。
                    #expect(Self.stages(world) == Self.stages(b.world))
                    #expect(events.isEmpty)
                    return
                }
                let next = GrowthStage(rawValue: before.reached.rawValue + 1)!
                let after = world.items[id]?.growth
                #expect(after?.reached == next)
                if let planted = after?.plantedAt {
                    let start = next == .bloom ? c.bloomDuration : c.bloomDuration * 0.5
                    #expect(abs(now.timeIntervalSince(planted) - start) < 1e-6)
                } else {
                    Issue.record("快进后 Story_Flower 没有种下时间")
                }
                #expect(events == [next == .bloom ? .bloomed(flower: id) : .sprouted(flower: id)])
                // 其余的花不变。
                for (oid, item) in b.world.items.items where oid != id {
                    #expect(world.items[oid] == item)
                }
            } else if !flowerActive, b.book.lastFlowerDoneAt != nil, waiting {
                // Requirement 8.9：条件 (c) 立即成立；检查间隔、冷却、概率的判定不变；花不变。
                let done = book.lastFlowerDoneAt
                #expect(done.map { now.timeIntervalSince($0) >= c.roundInterval } == true)
                #expect(book.nextCheckAt == b.book.nextCheckAt)
                #expect(book.lastEnded == b.book.lastEnded)
                for r in ResidentID.allCases {
                    #expect(WishDirector.cooledDown(r, book: book, now: now, constants: c)
                        == WishDirector.cooledDown(r, book: b.book, now: now, constants: c))
                }
                #expect(Self.stages(world) == Self.stages(b.world))
                #expect(events.isEmpty)
            } else {
                // Requirement 8.10：全部 Growth_Stage 不变。
                #expect(Self.stages(world) == Self.stages(b.world))
                #expect(book.lastFlowerDoneAt == b.book.lastFlowerDoneAt)
                #expect(events.isEmpty)
            }
        }
    }
}

// MARK: - Property 24 回归

extension FlowerWishTests {
    /// Property 24 反例（seed `WTu+4Fgtjer5wDlzwHqh0dkxg5TOiMi+Mn9SQtlt98U=`）：
    /// `plantedAt = now - 0.5B` 后重新计算的时长因 Date 浮点舍入比 0.5B 小，旧实现判回 pot 且不发事件。
    @Test(arguments: [1.0000000000000002, 369.83])
    func fastForwardFromPotSurvivesRounding(bloomDuration: Double) throws {
        let pot = FastForwardFlowerSpec(elapsedFraction: 0, reachedBump: 0, planted: true)
        let s = FastForwardScenario(
            nowOffset: 0, bloomDuration: bloomDuration, roundInterval: 60,
            activePattern: 1, stageIndex: StoryStage.allCases.firstIndex(of: .growing)!,
            current: pot, others: [], flowerCount: 1, doneFraction: nil,
            nextCheck: nil, endedA: nil, endedB: nil)
        let b = Self.build(s)
        var book = b.book
        var world = b.world
        let id = try #require(b.currentID)

        let e1 = WishDirector.fastForward(&book, world: &world, constants: b.constants, now: b.now)
        #expect(world.items[id]?.stage == .sprout)
        #expect(e1 == [.sprouted(flower: id)])

        let e2 = WishDirector.fastForward(&book, world: &world, constants: b.constants, now: b.now)
        #expect(world.items[id]?.stage == .bloom)
        #expect(e2 == [.bloomed(flower: id)])
    }

    /// Property 24 反例（seed `VXLCScm2xp4LuHop8focIr0MEoEzs+RsQ2UzvmXw70Y=`）：
    /// `lastFlowerDoneAt = now - R` 后 `now - lastFlowerDoneAt` 因浮点舍入比 R 小，旧实现条件 (c) 仍不成立。
    @Test(arguments: [1.0000000000000002, 369.83])
    func fastForwardEndsRoundIntervalDespiteRounding(roundInterval: Double) {
        let s = FastForwardScenario(
            nowOffset: 0, bloomDuration: 1, roundInterval: roundInterval,
            activePattern: 0, stageIndex: 0, current: nil, others: [], flowerCount: 0, doneFraction: 0,
            nextCheck: nil, endedA: nil, endedB: nil)
        let b = Self.build(s)
        var book = b.book
        var world = b.world
        let events = WishDirector.fastForward(&book, world: &world, constants: b.constants, now: b.now)
        #expect(book.lastFlowerDoneAt.map { b.now.timeIntervalSince($0) >= roundInterval } == true)
        #expect(events.isEmpty)
    }
}

// MARK: - 生成器（Property 23）

/// 送花轮换序列中的一步操作：
/// - `kind` 0：送花。先把进行中的 Flower_Wish 跑到 `fulfilled`（Growing 时用「快进」加速生长），再用跳时让其他
///   Wish 超时 `dropped`、等追逐结束，然后 `triggerWish(.flower, nil)`；
/// - `kind` 1：触发一个其他类型的 Wish（`otherType` 0 chair、1 lamp、2 visit、3 chase；`wisherB` 决定 Wisher），
///   前提不满足时不生成；
/// - `kind` 2：跳过 Wish_Timeout，让非送花 Wish 变为 `dropped`；
/// - `kind` 3：存档往返（`makeSave` → `SaveCodec` 编码、解码 → 恢复到新的 WorldEngine）；
/// - `kind` 4：「快进」；
/// - `kind` 5：空跑 `frames` 帧。
fileprivate struct FlowerRotationOp: Sendable, CustomStringConvertible {
    var kind: Int
    var otherType: Int
    var wisherB: Bool
    var frames: Int

    var description: String {
        switch kind {
        case 0: return "flower"
        case 1: return "wish(\(["chair", "lamp", "visit", "chase"][otherType]), \(wisherB ? "b" : "a"))"
        case 2: return "timeout"
        case 3: return "saveRestore"
        case 4: return "fastForward"
        default: return "idle(\(frames))"
        }
    }
}

fileprivate struct FlowerRotationCase: Sendable, CustomStringConvertible {
    var ops: [FlowerRotationOp]
    var description: String { "\(ops)" }
}

fileprivate extension Gen where Value == FlowerRotationCase {
    static var flowerRotationCase: Generator<FlowerRotationCase, some SendableSequenceType> {
        // 送花占 3/9，其余操作各 1/9 至 2/9。
        let op = zip(Gen<Int>.int(in: 0...8), Gen<Int>.int(in: 0...3), Gen<Bool>.bool(), Gen<Int>.int(in: 1...20))
            .map { k, t, b, f in
                let kind = k <= 2 ? 0 : (k <= 4 ? 1 : k - 3)
                return FlowerRotationOp(kind: kind, otherType: t, wisherB: b, frames: f)
            }
        return op.array(of: 1...8).map { FlowerRotationCase(ops: $0) }
    }
}

// MARK: - Property 23

extension FlowerWishTests {
    /// 三个首尾相接的窗口：窗口 1、3 是两人的家，窗口 2 是 Visit_Target 候选。
    static let rotationWindows = [
        StoryEngineTests.win(1, x: 100, y: 400),
        StoryEngineTests.win(2, x: 300, y: 400),
        StoryEngineTests.win(3, x: 500, y: 400),
    ]
    static let rotationUTC = TimeZone(secondsFromGMT: 0)!
    /// 每帧 0.1 秒（低于 `maxDeltaTime`），比 30 Hz 少跑帧数。
    static let rotationDT = 0.1

    static var rotationConstants: Tunables {
        var c = Tunables()
        c.wishSpawnChance = 0
        c.wishTimeout = 5
        c.chaseReadyDuration = 0.5
        c.chaseDuration = 3
        return c
    }

    /// 参考规则：第 n 次 Flower_Wish 的 Giver 在 n 奇数时为 A、偶数时为 B（Requirement 8.6）。
    static func rotationGiver(_ n: Int) -> ResidentID { n % 2 == 1 ? .a : .b }

    /// 经过 WorldEngine 的世界，记录观察到的每一次 Flower_Wish 开始并逐次检查轮换。
    fileprivate final class RotationWorld {
        var engine: WorldEngine
        var source = FakeWindowSource(snapshots: FlowerWishTests.rotationWindows)
        var now = FlowerWishTests.base
        /// 已观察到的 Flower_Wish 开始次数。
        var started = 0
        let label: String

        init(label: String) {
            self.label = label
            engine = WorldEngine(constants: FlowerWishTests.rotationConstants, clockStart: now,
                                 screen: StoryEngineTests.screen, rng: RandomSource(seed: 11), story: true)
        }

        var wishes: WishBook { engine.state.wishes }
        var flowerActive: Bool { wishes.active.contains { $0.type == .flower } }

        @discardableResult
        func step(_ commands: [Command] = [], dt: Double = FlowerWishTests.rotationDT) -> StepOutput {
            now = now.addingTimeInterval(dt)
            let out = engine.step(FrameInput(poll: source.poll(), screen: StoryEngineTests.screen,
                                             commands: commands, now: now, timeZone: FlowerWishTests.rotationUTC))
            check(out)
            return out
        }

        /// 本帧每个 `wish_started(flower)` 都是第 `started + 1` 次：Giver、Receiver、Story_Round 编号符合轮换。
        func check(_ out: StepOutput) {
            for e in out.events where e.type == .wishStarted && e.detail["wish_type"] == "flower" {
                started += 1
                let n = started
                let giver = FlowerWishTests.rotationGiver(n)
                let l = "\(label) flower #\(n)"
                #expect(e.actor == EventRecord.residentRef(giver), "\(l): actor \(String(describing: e.actor))")
                #expect(out.storyEvents.contains(.roundStarted(round: n, giver: giver, receiver: giver.other)),
                        "\(l): \(out.storyEvents)")
                #expect(wishes.flowerCount == n, "\(l): flowerCount \(wishes.flowerCount)")
                #expect(wishes.active.first { $0.type == .flower }?.wisher == giver, "\(l)")
                let story = engine.state.story
                #expect(story.round == n && story.giver == giver && story.receiver == giver.other,
                        "\(l): round \(story.round)")
            }
        }

        /// 把进行中的 Flower_Wish 跑到 `fulfilled`。
        func completeFlower() -> Bool {
            for _ in 0..<4_000 where flowerActive {
                step(engine.state.story.stage == .growing ? [.fastForward] : [])
            }
            return !flowerActive
        }

        /// 让非送花 Wish 结束：跳过 Wish_Timeout（chair、lamp、visit 超时 `dropped`），再等追逐结束。
        func clearOtherWishes() -> Bool {
            if wishes.active.contains(where: { $0.type != .flower && $0.type != .chase }) {
                step(dt: FlowerWishTests.rotationConstants.wishTimeout + 1)
            }
            for _ in 0..<600 where wishes.active.contains(where: { $0.type == .chase }) {
                step()
            }
            return wishes.busy.isEmpty
        }

        /// 存档往返：保存 → 编码 → 解码 → 恢复到新的 WorldEngine，并跑恢复那一帧。
        func saveRestore() {
            let before = wishes
            let save = engine.makeSave(now: now)
            guard let data = try? SaveCodec.encode(save), let decoded = try? SaveCodec.decode(data) else {
                Issue.record("\(label): encode/decode failed")
                return
            }
            #expect(decoded == save, "\(label): codec round trip")
            engine = WorldEngine(constants: FlowerWishTests.rotationConstants, clockStart: now,
                                 screen: StoryEngineTests.screen, rng: RandomSource(seed: 13), story: true,
                                 restored: decoded)
            source = FakeWindowSource(snapshots: FlowerWishTests.rotationWindows)
            step()
            // 已开始次数与下一次 Giver 原样恢复；进行中的 Flower_Wish 原样恢复（不受 Wish_Timeout 约束）。
            #expect(wishes.flowerCount == before.flowerCount, "\(label): restored flowerCount \(wishes.flowerCount)")
            #expect(WishDirector.nextFlowerGiver(wishes) == WishDirector.nextFlowerGiver(before), "\(label)")
            let flower = before.active.first { $0.type == .flower }
            #expect(wishes.active.first { $0.type == .flower }?.wisher == flower?.wisher, "\(label)")
            if flower != nil {
                #expect(engine.state.story.round == before.flowerCount, "\(label): restored round")
            }
        }
    }

    // Feature: V2, Property 23: 送花轮换
    /// **Validates: Requirements 8.2, 8.6**
    @Test func flowerGiverRotation() async {
        let types: [WishType] = [.chair, .lamp, .visit, .chase]
        await propertyCheck(count: 100, input: Gen.flowerRotationCase) { c in
            let w = RotationWorld(label: "\(c)")
            w.step()
            var triggered = 0
            for (i, op) in c.ops.enumerated() {
                let label = "\(c) op \(i) \(op)"
                switch op.kind {
                case 0:
                    guard w.completeFlower() else {
                        Issue.record("\(label): Flower_Wish not fulfilled, stage \(String(describing: w.engine.state.story.stage))")
                        return
                    }
                    guard w.clearOtherWishes() else {
                        Issue.record("\(label): residents still busy \(w.wishes.active.map(\.type))")
                        return
                    }
                    let before = w.started
                    w.step([.triggerWish(.flower, nil)])
                    triggered += 1
                    #expect(w.started == before + 1, "\(label): Flower_Wish not started")
                case 1:
                    w.step([.triggerWish(types[op.otherType], op.wisherB ? .b : .a)])
                case 2:
                    let flower = w.wishes.active.first { $0.type == .flower }
                    w.step(dt: Self.rotationConstants.wishTimeout + 1)
                    // Flower_Wish 不因 Wish_Timeout 被放弃（Requirement 8.5），轮换不受影响。
                    if let flower {
                        #expect(w.wishes.active.contains { $0.id == flower.id } || w.engine.state.story.stage == nil,
                                "\(label): Flower_Wish dropped")
                    }
                case 3:
                    w.saveRestore()
                case 4:
                    w.step([.fastForward])
                default:
                    for _ in 0..<op.frames { w.step() }
                }
            }
            #expect(w.started == triggered, "\(c): started \(w.started) of \(triggered)")
        }
    }
}
