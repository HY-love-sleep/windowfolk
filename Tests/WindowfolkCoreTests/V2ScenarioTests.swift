import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 16.6：V2 完整场景测试（Requirements 1.2、5.4、5.7、7.3、7.6、9.6、8.4、22.3、13.5、19.5）。
///
/// 用 `FakeWindowSource`、`ManualLocalClock`（时区 UTC）和固定种子驱动完整的 V2 `WorldEngine`（剧情与自主活动启用），
/// 只用玩家操作（从 Toolbox 拖出椅子、台灯、木板）和调试命令（触发心愿、快进、重置世界）串起一段演示：
/// 开局分配家 → 散步 → Chair_Wish 解锁椅子、摆椅子、坐下 → 19:00 Lamp_Wish 解锁台灯、摆灯、入睡 →
/// 次日 06:00 醒来 → Visit_Wish 搭木板到达 → Chase_Wish 搭第二块木板改变路线、`caught` → 送花一轮（快进生长、
/// 回赠果子、Giver 轮换）→ 存档往返后继续送花第二轮（Giver 为嘟嘟）→ 重置世界。最后检查事件序列与模板日记。
///
/// 自然生成 Wish 的概率设为 0，Wish 只由 `triggerWish` 触发；Sit_Duration 缩短为 2 秒以缩短测试。
/// 每帧 0.125 秒（二进制可精确表示）。全程每帧断言 `invariantViolations()` 为空、不发 Thought 请求。
///
/// 布局：屏幕 1440×900，Ground y 825。三个窗口 200×200，上沿 y 400（离 Ground 425pt，不能跳下，梯子也不够长）：
/// 窗口 1 x 100…300（都都的家）、窗口 2 x 400…600（唯一的 Visit_Target 候选）、窗口 3 x 700…900（嘟嘟的家），
/// 相邻窗口相距 100pt（不超过 Plank_Max_Span）。开局时三个窗口互不连通。
struct V2ScenarioTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let dt = 0.125
    static let ledgeY = 400.0
    static let windows = [
        StoryEngineTests.win(1, x: 100, y: ledgeY),
        StoryEngineTests.win(2, x: 400, y: ledgeY),
        StoryEngineTests.win(3, x: 700, y: ledgeY),
    ]
    static var constants: Tunables {
        var c = Tunables()
        c.wishSpawnChance = 0
        c.sitDuration = 2
        return c
    }

    final class Scenario {
        var engine: WorldEngine
        var source: FakeWindowSource
        let clock: ManualLocalClock
        var last: StepOutput?
        /// 至今全部事件记录（含存档恢复之后）。
        var events: [EventRecord] = []

        init() {
            // UTC 2027-01-15 08:00:00，不是 Night。
            clock = ManualLocalClock(year: 2027, month: 1, day: 15, hour: 8, minute: 0, second: 0)
            engine = WorldEngine(constants: V2ScenarioTests.constants, clockStart: clock.now,
                                 screen: V2ScenarioTests.screen, rng: RandomSource(seed: 7), story: true)
            source = FakeWindowSource(snapshots: V2ScenarioTests.windows)
        }

        @discardableResult
        func step(_ commands: [Command] = [], pointer: [PointerEvent] = [],
                  sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            clock.advance(by: V2ScenarioTests.dt)
            let out = engine.step(FrameInput(poll: source.poll(), screen: V2ScenarioTests.screen, pointer: pointer,
                                             commands: commands, now: clock.now, timeZone: clock.timeZone))
            let violations = engine.invariantViolations()
            #expect(violations.isEmpty, "\(violations)", sourceLocation: sourceLocation)
            // 「小心思」关闭：不发 Thought 请求，也不显示 Thought。
            #expect(out.thoughtRequests.isEmpty, sourceLocation: sourceLocation)
            #expect(out.view.residents.allSatisfy { $0.thought == nil }, sourceLocation: sourceLocation)
            events += out.events
            last = out
            return out
        }

        /// 逐帧推进直到条件成立，最多 `limit` 帧；返回条件是否成立。
        @discardableResult
        func run(limit: Int, until cond: () -> Bool) -> Bool {
            var n = 0
            while !cond(), n < limit { step(); n += 1 }
            return cond()
        }

        /// 逐帧推进直到本帧出现满足条件的事件记录，返回该记录。
        func runUntilEvent(limit: Int, _ match: (EventRecord) -> Bool) -> EventRecord? {
            for _ in 0 ..< limit {
                if let e = step().events.first(where: match) { return e }
            }
            return nil
        }

        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }
        var wishes: WishBook { engine.state.wishes }
        func x(_ id: ResidentID) -> Double? {
            ResidentController.currentSurface(of: resident(id), world: engine.movementContext())?.position.x
        }
        func window(_ id: ResidentID) -> WindowID? {
            if case let .window(w, _) = resident(id).attachment { return w }
            return nil
        }

        /// 从 Toolbox 的取物区拖到 `target` 松开。
        func drag(from zone: ToolboxZone, to target: Point, sourceLocation: SourceLocation = #_sourceLocation) {
            guard let z = ToolboxLayout.zoneFrame(zone, screen: V2ScenarioTests.screen,
                                                  unlocked: engine.state.decors.unlocked) else {
                Issue.record("Toolbox 中没有取物区 \(zone)", sourceLocation: sourceLocation)
                return
            }
            let start = Point(x: z.midX, y: z.midY)
            step(pointer: [.down(start)], sourceLocation: sourceLocation)
            for i in 1 ... 6 {
                let t = Double(i) / 6
                step(pointer: [.moved(Point(x: start.x + (target.x - start.x) * t,
                                            y: start.y + (target.y - start.y) * t))],
                     sourceLocation: sourceLocation)
            }
            step(pointer: [.up(target)], sourceLocation: sourceLocation)
        }

        /// 附着在窗口 1 窗沿上的 Decor 数量。
        var decorsOnWindow1: Int {
            engine.state.decors.decors.values.filter {
                if case .attached(.window(1, _)) = $0.placement { return true }
                return false
            }.count
        }

        /// 两人都不在庆祝、不在下落，且没有 active Wish。
        var settled: Bool {
            wishes.active.isEmpty && ResidentID.allCases.allSatisfy {
                let s = resident($0).state
                return s != .celebrating && s != .falling && s != .hanging
            }
        }

        /// 存档往返：保存 → 编码 → 解码 → 恢复到新的 WorldEngine，并跑恢复那一帧。
        func saveAndRestore(sourceLocation: SourceLocation = #_sourceLocation) throws -> StepOutput {
            let save = engine.makeSave(now: clock.now)
            let decoded = try SaveCodec.decode(try SaveCodec.encode(save))
            #expect(decoded == save, sourceLocation: sourceLocation)
            engine = WorldEngine(constants: V2ScenarioTests.constants, clockStart: clock.now,
                                 screen: V2ScenarioTests.screen, rng: RandomSource(seed: 13), story: true,
                                 restored: decoded)
            source = FakeWindowSource(snapshots: V2ScenarioTests.windows)
            return step(sourceLocation: sourceLocation)
        }
    }

    /// 事件的比较键：类型，Wish 事件附上 Wish_Type，追逐结局附上 Chase_Outcome。
    static func key(_ e: EventRecord) -> String {
        var k = e.type.rawValue
        if let w = e.detail["wish_type"] { k += ":\(w)" }
        if let o = e.detail["chase_outcome"] { k += ":\(o)" }
        return k
    }

    static func isSubsequence(_ needle: [String], of hay: [String]) -> Bool {
        var i = needle.startIndex
        for t in hay where i < needle.endIndex && t == needle[i] { i += 1 }
        return i == needle.endIndex
    }

    /// 新拖出的 Decor 松手时的指针位置：Decor 底边中点（指针减去抓取偏移）在窗沿上方 4pt，按 Requirement 3.2 附着到该窗沿。
    static func decorDrop(_ type: DecorType, x: Double) -> Point {
        let grab = InteractionController.freshDecorGrabOffset(type)
        return Point(x: x + grab.x, y: ledgeY - 4 + grab.y)
    }

    static func hasWishIcon(_ b: Bubble?) -> Bool {
        if case .wishIcon? = b { return true }
        return false
    }

    @Test func fullV2Scenario() async throws {
        let s = Scenario()
        let c = Self.constants
        let day1 = LocalDate.of(s.clock.now, timeZone: Self.utc)

        // MARK: 1. 开局分配家，两人在自己窗沿上散步（Requirement 1.1、4.6）

        var out = s.step()
        #expect(s.engine.state.story.homes == [.a: 1, .b: 3])
        #expect(s.window(.a) == 1 && s.window(.b) == 3)
        #expect(s.engine.state.decors.unlocked.isEmpty && out.view.unlockedDecor.isEmpty)
        #expect(s.wishes.active.isEmpty)
        let startX = try #require(s.x(.a))
        #expect(s.run(limit: 16) {
            s.engine.state.activities[.a]?.kind == .wander && s.engine.state.activities[.b]?.kind == .wander
        })
        var walked = false
        for _ in 0 ..< 80 {
            s.step()
            if let x = s.x(.a), abs(x - startX) > 1 { walked = true }
        }
        #expect(walked, "都都应在窗沿上散步")
        #expect(s.window(.a) == 1 && s.window(.b) == 3)

        // MARK: 2. Chair_Wish：解锁椅子，玩家摆椅子，都都去坐下（Requirement 1.2、7.3）

        out = s.step([.triggerWish(.chair, .a)])
        #expect(s.wishes.active.map(\.type) == [.chair])
        #expect(s.engine.state.decors.unlocked == [.chair])
        #expect(out.view.unlockedDecor == [.chair])
        #expect(out.events.filter { $0.type == .decorUnlocked }.map { $0.detail["decor_type"] } == ["chair"])
        s.step()
        #expect(s.last?.view.residents.first { $0.id == .a }?.bubble == .wishIcon(.chair))
        let ax = try #require(s.x(.a))
        let chairX = min(max(ax <= 200 ? ax + 60 : ax - 60, 110), 290)
        s.drag(from: .decor(.chair), to: Self.decorDrop(.chair, x: chairX))
        #expect(s.engine.state.decors.decors.count == 1)
        #expect(s.decorsOnWindow1 == 1, "椅子应放在都都的窗沿上：\(s.engine.state.decors.decors)")
        let sat = try #require(s.runUntilEvent(limit: 160) { $0.type == .wishFulfilled })
        #expect(sat.detail == ["wish_type": "chair", "wish_state": "fulfilled"])
        #expect(s.resident(.a).state == .sitting)
        #expect(s.resident(.a).seat != nil)
        #expect(s.wishes.active.isEmpty && s.wishes.celebrations[.a] == nil)
        // Sit_Duration 后站起来。
        #expect(s.run(limit: Int(c.sitDuration / Self.dt) + 8) { s.resident(.a).state != .sitting })
        #expect(s.resident(.a).seat == nil)

        // MARK: 3. 19:00 夜晚：Lamp_Wish 解锁台灯，摆灯，都都在灯旁入睡（Requirement 1.3、5.4、7.6）

        s.clock.set(year: 2027, month: 1, day: 15, hour: 19, minute: 0, second: 0)
        s.step()
        #expect(s.engine.state.isNight && s.last?.view.isNight == true)
        out = s.step([.triggerWish(.lamp, .a)])
        #expect(s.wishes.active.map(\.type) == [.lamp])
        #expect(s.engine.state.decors.unlocked == [.chair, .lamp])
        #expect(out.events.filter { $0.type == .decorUnlocked }.map { $0.detail["decor_type"] } == ["lamp"])
        s.step()
        let ax2 = try #require(s.x(.a))
        let lampX = min(max(ax2 <= 200 ? ax2 + 100 : ax2 - 100, 110), 290)
        s.drag(from: .decor(.lamp), to: Self.decorDrop(.lamp, x: lampX))
        #expect(s.engine.state.decors.decors.count == 2)
        #expect(s.decorsOnWindow1 == 2, "台灯应放在都都的窗沿上：\(s.engine.state.decors.decors)")
        let lampDone = try #require(s.runUntilEvent(limit: 160) { $0.type == .wishFulfilled })
        #expect(lampDone.detail == ["wish_type": "lamp", "wish_state": "fulfilled"])
        #expect(s.resident(.a).state == .sleeping)
        #expect(s.last?.view.residents.first { $0.id == .a }?.bubble == .zzz)
        for _ in 0 ..< 16 { s.step() }
        #expect(s.resident(.a).state == .sleeping)

        // MARK: 4. 次日 06:00 天亮，都都醒来（Requirement 5.7）

        s.clock.set(year: 2027, month: 1, day: 16, hour: 6, minute: 0, second: 0)
        let day2 = LocalDate.of(s.clock.now, timeZone: Self.utc)
        let woke = s.runUntilEvent(limit: Int(1 / Self.dt)) { $0.type == .woke && $0.actor == "resident_a" }
        #expect(woke != nil, "天亮后 1 秒内应醒来")
        #expect(!s.engine.state.isNight)
        #expect(s.resident(.a).state != .sleeping)

        // MARK: 5. Visit_Wish：搭木板连通窗口 1 和 2，都都走到窗口 2（Requirement 9.6）

        #expect(s.run(limit: 40) { s.settled })
        out = s.step([.triggerWish(.visit, .a)])
        let visit = try #require(s.wishes.active.first)
        #expect(visit.type == .visit && visit.visitTarget?.window == 2)
        #expect(out.view.visitFlags.count == 1)
        for _ in 0 ..< 8 { s.step() }
        #expect(s.resident(.a).state == .waiting, "没有路线时应等待：\(s.resident(.a).state)")
        s.drag(from: .plank, to: Point(x: 350, y: Self.ledgeY - 10))
        #expect(s.engine.state.planks.placedPlanks.count == 1)
        let visited = try #require(s.runUntilEvent(limit: 300) { $0.type == .wishFulfilled })
        #expect(visited.detail == ["wish_type": "visit", "wish_state": "fulfilled"])
        #expect(s.window(.a) == 2)
        #expect(s.last?.view.visitFlags.isEmpty == true)
        #expect(s.events.contains { $0.type == .visited && $0.target == "app:App2" })

        // MARK: 6. Chase_Wish：起初不可达，搭第二块木板改变路线后都都抓到嘟嘟（Requirement 21、22.3）

        #expect(s.run(limit: 40) { s.settled })
        s.step([.triggerWish(.chase, .b)])
        let chase = { s.wishes.active.first { $0.type == .chase }?.chase }
        #expect(chase()?.phase == .ready)
        #expect(s.run(limit: Int(c.chaseReadyDuration / Self.dt) + 2) { chase()?.phase == .running })
        #expect(s.run(limit: 8) { s.resident(.a).state == .waiting }, "Chaser 不可达时应等待")
        s.drag(from: .plank, to: Point(x: 650, y: Self.ledgeY - 10))
        #expect(s.engine.state.planks.placedPlanks.count == 2)
        var ran = false
        let caught = try #require(s.runUntilEvent(limit: Int(c.chaseDuration / Self.dt)) {
            if s.resident(.a).state == .running { ran = true }
            return $0.type == .wishFulfilled
        })
        #expect(ran)
        #expect(caught.detail["wish_type"] == "chase" && caught.detail["chase_outcome"] == "caught")
        #expect(s.resident(.a).state == .celebrating && s.resident(.b).state == .celebrating)
        #expect(s.resident(.a).speedFactor == 1 && s.resident(.b).speedFactor == 1)

        // MARK: 7. 送花一轮：都都送花，快进生长，嘟嘟回赠果子，下一次 Giver 轮到嘟嘟（Requirement 8.4、8.6）

        #expect(s.run(limit: 40) { s.settled })
        s.step([.triggerWish(.flower, nil)])
        #expect(s.wishes.active.first?.type == .flower && s.wishes.active.first?.wisher == .a)
        #expect(s.engine.state.story.round == 1)
        #expect(s.run(limit: 600) { s.engine.state.story.stage == .growing })
        s.step([.fastForward])
        s.step([.fastForward])
        #expect(s.engine.state.story.stage == .returnGift)
        let flower1 = try #require(s.runUntilEvent(limit: 600) { $0.type == .wishFulfilled })
        #expect(flower1.detail == ["wish_type": "flower", "wish_state": "fulfilled"])
        #expect(s.engine.state.story.stage == nil && s.wishes.active.isEmpty)
        #expect(s.wishes.flowerCount == 1)
        #expect(WishDirector.nextFlowerGiver(s.wishes) == .b)
        #expect(s.run(limit: 40) { s.settled })

        let beforeRestore = s.events.map(Self.key)
        let expected = [
            "wish_started:chair", "decor_unlocked", "decor_placed", "sat", "wish_fulfilled:chair",
            "wish_started:lamp", "decor_unlocked", "decor_placed", "slept", "wish_fulfilled:lamp", "woke",
            "wish_started:visit", "plank_placed", "crossed_bridge", "visited", "wish_fulfilled:visit",
            "wish_started:chase", "plank_placed", "wish_fulfilled:chase:caught",
            "wish_started:flower", "round_started", "planted", "sprouted", "bloomed", "gift_delivered",
            "wish_fulfilled:flower",
        ]
        #expect(Self.isSubsequence(expected, of: beforeRestore), "\(beforeRestore)")
        #expect(s.events.filter { $0.type == .decorUnlocked }.count == 2)
        #expect(!s.events.contains { $0.type == .wishDropped })

        // MARK: 8. 存档往返后继续：Unlocked_Decor、送花次数保留，第二轮由嘟嘟送花（Requirement 15、8.6）

        let restoreFrame = try s.saveAndRestore()
        #expect(!restoreFrame.events.contains { $0.type == .decorUnlocked || $0.type == .decorPlaced })
        #expect(s.engine.state.decors.unlocked == [.chair, .lamp])
        #expect(s.engine.state.decors.decors.count == 2)
        #expect(s.wishes.flowerCount == 1 && s.wishes.active.isEmpty)
        #expect(s.engine.state.story.homes == [.a: 1, .b: 3])
        #expect(s.run(limit: 120) { s.settled })
        let restoredEvents = s.events.count
        s.step([.triggerWish(.flower, nil)])
        #expect(s.wishes.active.first?.type == .flower && s.wishes.active.first?.wisher == .b)
        #expect(s.engine.state.story.round == 2)
        #expect(s.run(limit: 900) { s.engine.state.story.stage == .growing })
        s.step([.fastForward])
        s.step([.fastForward])
        let flower2 = try #require(s.runUntilEvent(limit: 900) { $0.type == .wishFulfilled })
        #expect(flower2.detail == ["wish_type": "flower", "wish_state": "fulfilled"])
        #expect(flower2.actor == "resident_b")
        #expect(WishDirector.nextFlowerGiver(s.wishes) == .a)
        let afterRestore = s.events[restoredEvents...].map(Self.key)
        #expect(Self.isSubsequence(["wish_started:flower", "round_started", "planted", "sprouted", "bloomed",
                                    "gift_delivered", "wish_fulfilled:flower"], of: afterRestore), "\(afterRestore)")

        // MARK: 9. 重置世界：清空 Unlocked_Decor、Decor、Wish 和送花次数，同一帧重新分配家（Requirement 1.6、17.6）

        out = s.step([.resetWorld])
        #expect(s.engine.state.decors.unlocked.isEmpty && out.view.unlockedDecor.isEmpty)
        #expect(s.engine.state.decors.decors.isEmpty && out.view.decors.isEmpty)
        #expect(s.wishes.active.isEmpty && s.wishes.flowerCount == 0)
        #expect(WishDirector.nextFlowerGiver(s.wishes) == .a)
        #expect(s.engine.state.story.homes == [.a: 1, .b: 3])
        for _ in 0 ..< 16 { s.step() }

        // MARK: 10. 没有分数、倒计时类输出（Requirement 10.4、22.3）

        let banned = ["score", "countdown", "remaining", "timer", "progress", "elapsed", "winner", "loser"]
        for e in s.events {
            for (k, v) in e.detail {
                #expect(!banned.contains { k.contains($0) || v.contains($0) }, "\(e)")
            }
        }
        let view = try #require(s.last?.view)
        let labels = Mirror(reflecting: view).children.compactMap(\.label)
            + Mirror(reflecting: view.residents[0]).children.compactMap(\.label)
        #expect(!labels.contains { l in banned.contains { l.lowercased().contains($0) } }, "\(labels)")

        // MARK: 11. 事件记录编解码往返，并生成模板日记（Requirement 13.5、19.5、22.8）

        let data = s.events.reduce(Data()) { $0 + EventCodec.encodeLine($1, timeZone: Self.utc) }
        #expect(EventLogReader.parse(data) == s.events)

        let fake = FakeLLMClient([.text("不该用到")])
        let writer = DiaryWriter(client: fake, maxLength: c.diaryMaxLength)
        func diary(_ id: ResidentID, _ date: LocalDate) async -> (DiaryEntry, String) {
            let mine = DiaryWriter.relevant(s.events, resident: id, date: date, timeZone: Self.utc)
            let e = await writer.write(DiaryKey(date: date, resident: id), events: mine, config: nil,
                                       timeZone: Self.utc)
            return (e, DiaryTemplates.text(writer: id, events: mine))
        }
        let (a1, a1Full) = await diary(.a, day1)
        let (a2, a2Full) = await diary(.a, day2)
        let (b2, b2Full) = await diary(.b, day2)
        for (entry, full) in [(a1, a1Full), (a2, a2Full), (b2, b2Full)] {
            #expect(entry.method == .template)
            #expect(entry.text == DiaryWriter.truncate(full, maxLength: c.diaryMaxLength))
            #expect(entry.text.count <= c.diaryMaxLength)
            #expect(!entry.text.contains("输") && !entry.text.contains("赢") && !entry.text.contains("失败"))
        }
        #expect(await fake.requestCount == 0, "「日记使用 LLM」关闭时不发请求")
        for sentence in ["我想要一把椅子。", "我在椅子上坐了一会儿。", "我终于有椅子坐了。",
                         "我想要一盏台灯。", "我在台灯旁睡了一觉。", "夜里有台灯陪着我了。"] {
            #expect(a1Full.contains(sentence), "都都 \(day1)：缺「\(sentence)」\n\(a1Full)")
        }
        for sentence in ["我醒了过来。", "我想去别的窗口看看。", "我走过了一座木板桥。", "我去看了想看的那扇窗。",
                         "和嘟嘟玩追逐，我抓到嘟嘟啦。", "我想给嘟嘟送花的心愿实现了。", "嘟嘟送给我一个果子。"] {
            #expect(a2Full.contains(sentence), "都都 \(day2)：缺「\(sentence)」\n\(a2Full)")
        }
        for sentence in ["和都都玩追逐，我被都都抓到了。", "我把果子送给了都都。", "我想给都都送花的心愿实现了。"] {
            #expect(b2Full.contains(sentence), "嘟嘟 \(day2)：缺「\(sentence)」\n\(b2Full)")
        }
    }
}
