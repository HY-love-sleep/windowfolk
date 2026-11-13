import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 7.19：心愿的例子测试。全部经过 `WorldEngine`（剧情与自主活动启用，时区 UTC），自然生成 Wish 的概率
/// 设为 0，Wish 只由 `triggerWish` 触发。
///
/// 与已有测试的分工：`WishDirectorUnitTests` 直接调用 WishDirector 的纯函数，`WishEngineUnitTests` 验证接线
/// （事件顺序、Visit_Flag、重置世界）。这里用完整的世界更新跑出各 Wish 的完成与放弃：居民真的走到 Chair、Lamp、
/// Visit_Target，Night 由 Local_Clock 结束，窗口真的被隐藏和关闭，送花跑完一整轮，玩家真的点击 Wisher。
struct WishExampleTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    /// UTC 08:00，不是 Night。
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let dt = 1.0 / 30

    /// 窗口 1、3 相距最远，分别是都都和嘟嘟的家；窗口 2 是唯一的 Visit_Target 候选，与窗口 1 首尾相接
    /// （窗口 1 右边缘 x 300 = 窗口 2 左边缘），都都可以直接走过去。
    static let windows = [
        StoryEngineTests.win(1, x: 100, y: 400),
        StoryEngineTests.win(2, x: 300, y: 400),
        StoryEngineTests.win(3, x: 900, y: 400),
    ]

    final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now: Date
        var last: StepOutput?

        init(_ windows: [WindowSnapshot] = WishExampleTests.windows, start: Date = WishExampleTests.t0,
             configure: (inout Tunables) -> Void = { _ in }) {
            var c = Tunables()
            c.wishSpawnChance = 0
            configure(&c)
            now = start
            engine = WorldEngine(constants: c, clockStart: start, screen: WishExampleTests.screen,
                                 rng: RandomSource(seed: 7), story: true)
            source = FakeWindowSource(snapshots: windows)
        }

        @discardableResult
        func step(_ commands: [Command] = [], pointer: [PointerEvent] = [],
                  sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            now = now.addingTimeInterval(WishExampleTests.dt)
            let out = engine.step(FrameInput(poll: source.poll(), screen: WishExampleTests.screen, pointer: pointer,
                                             commands: commands, now: now, timeZone: WishExampleTests.utc))
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())",
                    sourceLocation: sourceLocation)
            last = out
            return out
        }

        /// 逐帧推进，直到 `done` 对本帧输出成立，返回该帧输出；`max` 帧内不成立时返回 nil。
        func run(max: Int, until done: (StepOutput) -> Bool) -> StepOutput? {
            for _ in 0 ..< max {
                let out = step()
                if done(out) { return out }
            }
            return nil
        }

        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }
        func view(_ id: ResidentID) -> ResidentView? { last?.view.residents.first { $0.id == id } }
        var wishes: WishBook { engine.state.wishes }
    }

    static func hasWishIcon(_ b: Bubble?) -> Bool {
        if case .wishIcon? = b { return true }
        return false
    }

    static func index(_ type: EventType, in out: StepOutput) -> Int? {
        out.events.firstIndex { $0.type == type }
    }

    // MARK: - Requirement 1.1：首次开局

    @Test func freshStartHasNoUnlockedDecorAndNoDecorSlot() {
        let h = Harness()
        let out = h.step()
        #expect(h.engine.state.story.homes == [.a: 1, .b: 3])
        #expect(h.engine.state.decors.unlocked.isEmpty)
        #expect(out.view.unlockedDecor.isEmpty)
        #expect(!out.events.contains { $0.type == .decorUnlocked })
        // Toolbox 只有 Plank、Ladder 两个取物区，命中区域里没有 Decor_Slot。
        let zones = out.view.hitRegions.compactMap { r -> ToolboxZone? in
            if case let .toolbox(z) = r.target { return z }
            return nil
        }
        #expect(zones == [.plank, .ladder])
        #expect(out.view.toolbox == ToolboxLayout.frame(screen: Self.screen, unlocked: []))
    }

    // MARK: - Requirement 7.3：Chair_Wish 完成

    @Test func chairWishFulfillsOnSittingWithoutCelebrating() throws {
        let h = Harness { $0.sitDuration = 2 }
        h.step()
        h.step([.triggerWish(.chair, .a)])
        #expect(h.wishes.active.map(\.type) == [.chair])
        var a = h.resident(.a)
        a.walkDistance = 2500
        h.engine.place(a)
        // 都都在窗口 1 上；椅子放在同一窗沿上离它 60pt 处。
        guard case let .window(1, offset) = h.resident(.a).attachment else {
            Issue.record("都都应在窗口 1 上：\(h.resident(.a).attachment)")
            return
        }
        let chair = DecorID(1)
        h.engine.insertDecor(Decor(id: chair, type: .chair,
                                   placement: .attached(.window(1, offset: offset <= 100 ? offset + 60 : offset - 60))))

        let out = try #require(h.run(max: 150) { $0.events.contains { $0.type == .wishFulfilled } })
        let sat = try #require(Self.index(.sat, in: out))
        let fulfilled = try #require(Self.index(.wishFulfilled, in: out))
        #expect(sat < fulfilled)
        #expect(out.events[sat].actor == "resident_a" && out.events[sat].target == "decor:1")
        #expect(out.events[fulfilled].detail == ["wish_type": "chair", "wish_state": "fulfilled"])
        // 保持 sitting，不庆祝；Wish_Bubble 隐藏，Busy 身份结束，当前 Activity 视为 rest。
        #expect(h.resident(.a).state == .sitting && h.resident(.a).seat == chair)
        #expect(h.wishes.active.isEmpty && h.wishes.busy.isEmpty)
        #expect(h.wishes.celebrations[.a] == nil)
        #expect(h.wishes.lastEnded[.a] == h.now)
        #expect(!Self.hasWishIcon(h.view(.a)?.bubble))
        #expect(h.view(.a)?.state == .sitting)
        #expect(h.engine.state.activities[.a]?.kind == .rest)

        // 下一帧仍然坐着，不转为 celebrating。
        h.step()
        #expect(h.resident(.a).state == .sitting)

        // Sit_Duration 后离开 sitting、释放 Chair、Walk_Distance 归零。
        let sitAt = h.now.addingTimeInterval(-Self.dt)
        #expect(h.run(max: 90) { _ in h.resident(.a).state != .sitting } != nil)
        #expect(h.now.timeIntervalSince(sitAt) >= 2 - 1e-6)
        #expect(h.resident(.a).seat == nil)
        #expect(h.resident(.a).walkDistance <= Tunables().walkSpeed * Self.dt + 1e-6)
    }

    // MARK: - Requirement 7.6：Lamp_Wish 完成

    @Test func lampWishFulfillsOnSleepingWithoutCelebrating() throws {
        let h = Harness()
        h.step([.setDayNight(.night)])
        h.step([.triggerWish(.lamp, .a)])
        #expect(h.wishes.active.map(\.type) == [.lamp])
        guard case let .window(1, offset) = h.resident(.a).attachment else {
            Issue.record("都都应在窗口 1 上：\(h.resident(.a).attachment)")
            return
        }
        // 台灯与都都同一窗沿、水平距离 90pt（> Lamp_Range），都都要先走过去。
        let lamp = DecorID(1)
        let lampOffset = offset <= 100 ? offset + 90 : offset - 90
        h.engine.insertDecor(Decor(id: lamp, type: .lamp, placement: .attached(.window(1, offset: lampOffset))))

        let out = try #require(h.run(max: 150) { $0.events.contains { $0.type == .wishFulfilled } })
        let slept = try #require(Self.index(.slept, in: out))
        let fulfilled = try #require(Self.index(.wishFulfilled, in: out))
        #expect(slept < fulfilled)
        #expect(out.events[slept].target == "decor:1")
        #expect(out.events[fulfilled].detail == ["wish_type": "lamp", "wish_state": "fulfilled"])
        guard case let .window(1, sleptAt) = h.resident(.a).attachment else {
            Issue.record("都都应在窗口 1 上")
            return
        }
        #expect(abs(sleptAt - lampOffset) <= Tunables().lampRange + 1e-6,
                "都都 offset \(sleptAt)，台灯 offset \(lampOffset)，开始 offset \(offset)")
        #expect(h.resident(.a).state == .sleeping)
        #expect(h.wishes.active.isEmpty && h.wishes.busy.isEmpty && h.wishes.celebrations[.a] == nil)
        #expect(h.view(.a)?.bubble == .zzz)
        #expect(h.engine.state.activities[.a]?.kind == .sleep)

        // 之后按 Requirement 5.7 醒来：Night 结束时写 woke。
        h.step()
        #expect(h.resident(.a).state == .sleeping)
        let woke = h.step([.setDayNight(.day)])
        #expect(woke.events.contains { $0.type == .woke && $0.actor == "resident_a" })
        #expect(h.resident(.a).state != .sleeping)
        #expect(!woke.events.contains { $0.type == .wishDropped })
    }

    // MARK: - Requirement 6.12：Lamp_Wish 进行中 Night 结束

    @Test func lampWishDroppedWhenLocalClockReachesNightEnd() throws {
        // UTC 05:59:58（昼夜覆盖为「自动」）：两秒后 Local_Clock 到达 Night_End。
        let start = Self.t0.addingTimeInterval(-2 * 3600 - 2)
        let h = Harness(start: start)
        h.step()
        #expect(h.engine.state.isNight)
        h.step([.triggerWish(.lamp, .b)])
        let wish = try #require(h.wishes.active.first)
        #expect(wish.type == .lamp && wish.wisher == .b)
        #expect(h.engine.state.decors.unlocked == [.lamp])

        let out = try #require(h.run(max: 90) { $0.events.contains { $0.type == .wishDropped } })
        #expect(!h.engine.state.isNight)
        // 在 Night 结束后的第一次世界更新中放弃，不必等 Wish_Timeout。
        #expect(h.now.timeIntervalSince(start) >= 2 && h.now.timeIntervalSince(start) < 2 + 2 * Self.dt)
        let dropped = try #require(out.events.first { $0.type == .wishDropped })
        #expect(dropped.actor == "resident_b")
        #expect(dropped.detail == ["wish_type": "lamp", "wish_state": "dropped"])
        #expect(!out.events.contains { $0.type == .wishFulfilled })
        #expect(h.wishes.active.isEmpty && h.wishes.busy.isEmpty)
        #expect(h.wishes.lastEnded[.b] == h.now)
        #expect(!Self.hasWishIcon(h.view(.b)?.bubble))
        // 放弃不改变 Unlocked_Decor；嘟嘟恢复自主活动。
        #expect(h.engine.state.decors.unlocked == [.lamp])
        #expect(h.run(max: 30) { _ in h.engine.state.activities[.b] != nil } != nil)
    }

    // MARK: - Requirement 9.6、9.7：Visit_Target 隐藏时等待

    @Test func visitWisherWaitsWhileTargetHiddenThenWalksThere() throws {
        let h = Harness()
        h.step()
        h.step([.triggerWish(.visit, .a)])
        let wish = try #require(h.wishes.active.first)
        #expect(wish.visitTarget?.window == 2)

        h.source.hide(2)
        for _ in 0 ..< 60 { h.step() }
        #expect(h.wishes.active.map(\.id) == [wish.id])
        #expect(h.wishes.active.first?.createdAt == wish.createdAt)
        #expect(h.resident(.a).state == .waiting)
        if case .window(1, _) = h.resident(.a).attachment {} else {
            Issue.record("隐藏期间都都应留在窗口 1：\(h.resident(.a).attachment)")
        }
        guard case .wishIcon(.flag)? = h.view(.a)?.bubble else {
            Issue.record("等待中应显示小旗 Wish_Bubble：\(String(describing: h.view(.a)?.bubble))")
            return
        }
        #expect(h.last?.view.visitFlags.isEmpty == true)

        // 重新显示：都都沿路线走到窗口 2，同一次更新先写 visited 再写 wish_fulfilled。
        h.source.show(2)
        let out = try #require(h.run(max: 450) { $0.events.contains { $0.type == .wishFulfilled } })
        let visited = try #require(Self.index(.visited, in: out))
        let fulfilled = try #require(Self.index(.wishFulfilled, in: out))
        #expect(visited < fulfilled)
        #expect(out.events[visited].target == "app:App2")
        if case .window(2, _) = h.resident(.a).attachment {} else {
            Issue.record("都都应站在窗口 2 上：\(h.resident(.a).attachment)")
        }
        #expect(h.resident(.a).state == .celebrating)
        #expect(out.view.visitFlags.isEmpty)
        #expect(!Self.hasWishIcon(h.view(.a)?.bubble))
    }

    // MARK: - Requirement 6.12：Visit_Target 关闭时放弃

    @Test func visitWishDroppedWhenTargetCloses() throws {
        let h = Harness()
        h.step()
        h.step([.triggerWish(.visit, .b)])
        #expect(h.wishes.active.first?.visitTarget?.window == 2)
        #expect(h.last?.view.visitFlags.count == 1)

        h.source.close(2)
        let out = h.step()
        let dropped = try #require(out.events.first { $0.type == .wishDropped })
        #expect(dropped.actor == "resident_b" && dropped.target == "app:App2")
        #expect(dropped.detail == ["wish_type": "visit", "wish_state": "dropped"])
        #expect(!out.events.contains { $0.type == .wishFulfilled || $0.type == .visited })
        #expect(h.wishes.active.isEmpty && h.wishes.busy.isEmpty)
        #expect(out.view.visitFlags.isEmpty)
        #expect(!Self.hasWishIcon(h.view(.b)?.bubble))
        #expect(h.resident(.b).state != .celebrating)
    }

    // MARK: - Requirement 8.4：送花完成后两人恢复活动

    @Test func flowerWishFulfilledThenBothResumeActivities() throws {
        let touching = [StoryEngineTests.win(1, x: 100, y: 400), StoryEngineTests.win(2, x: 300, y: 400)]
        let h = Harness(touching)
        h.step([.triggerWish(.flower, nil)])
        #expect(h.wishes.busy == [.a, .b])
        #expect(h.run(max: 900) { _ in h.engine.state.story.stage == .growing } != nil)
        h.step([.fastForward])
        h.step([.fastForward])

        let out = try #require(h.run(max: 900) { $0.events.contains { $0.type == .wishFulfilled } })
        let fulfilled = try #require(out.events.first { $0.type == .wishFulfilled })
        #expect(fulfilled.actor == "resident_a")
        #expect(fulfilled.detail == ["wish_type": "flower", "wish_state": "fulfilled"])
        #expect(h.engine.state.story.stage == nil)
        #expect(h.wishes.active.isEmpty && h.wishes.busy.isEmpty)
        #expect(h.wishes.lastEnded[.a] == h.now && h.wishes.lastEnded[.b] == h.now)
        #expect(h.resident(.a).state == .celebrating)

        // 庆祝结束后两人都由 Activity_Planner 选出当前 Activity；Done 阶段的活动限制不再适用。
        let frames = Int(StoryDirector.celebrateDuration / Self.dt) + 30
        #expect(h.run(max: frames) { _ in
            ResidentID.allCases.allSatisfy { h.engine.state.activities[$0] != nil }
        } != nil)
        for id in ResidentID.allCases {
            #expect(h.resident(id).state != .celebrating)
        }
        #expect(h.wishes.celebrations.isEmpty)
    }

    // MARK: - Requirement 10.6：「?」气泡期间隐藏 Wish_Bubble

    @Test func pokingWisherShowsQuestionThenRestoresWishBubble() throws {
        let h = Harness()
        h.step()
        h.step([.triggerWish(.chair, .a)])
        for _ in 0 ..< 5 { h.step() }
        let wish = try #require(h.wishes.active.first)
        #expect(h.view(.a)?.bubble == .wishIcon(.chair))

        let rect = try #require(h.last?.view.hitRegions.first { $0.target == .resident(.a) }?.rect)
        let p = Point(x: rect.midX, y: rect.midY)
        h.step(pointer: [.down(p)])
        h.step(pointer: [.up(p)])
        #expect((h.view(.a)?.poke?.bubbleRemaining ?? 0) > 0)

        // 「?」显示期间：Wish 不变，`ResidentView` 同时给出「?」（`poke`）和 Wish_Bubble，渲染层据 `poke` 隐藏
        // Wish_Bubble（design：WorldEngine+V2 `applyWishBubbles`）。
        var frames = 0
        while (h.view(.a)?.poke?.bubbleRemaining ?? 0) > 0, frames < 90 {
            #expect(h.wishes.active.map(\.id) == [wish.id])
            #expect(h.view(.a)?.bubble == .wishIcon(.chair))
            h.step()
            frames += 1
        }
        #expect(frames > 0 && frames < 90)
        // 「?」结束后的这一帧恢复显示 Wish_Bubble，Wish 仍为 active、创建时间不变。
        #expect(h.view(.a)?.poke == nil)
        #expect(h.view(.a)?.bubble == .wishIcon(.chair))
        #expect(h.wishes.active.first?.createdAt == wish.createdAt)
        #expect(h.wishes.active.first?.state == .active)
    }
}
