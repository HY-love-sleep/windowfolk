import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 13.5：WorldEngine 接入剧情与调试菜单命令。
///
/// V2（任务 7.4，design.md「v1 属性的调整」）：剧情不再自动开局和换轮。开局只分配 Home_Window 并放置居民，
/// 送花由 `triggerWish(.flower, nil)` 启动；「重新开始剧情」改为「重置世界」。
struct StoryEngineTests {
    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    static let dt = 1.0 / 30

    static func win(_ id: WindowID, x: Double, y: Double, w: Double = 200, h: Double = 200) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: 0)
    }

    final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now = Date(timeIntervalSince1970: 1_800_000_000)

        init(_ windows: [WindowSnapshot], constants: Tunables = Tunables()) {
            engine = WorldEngine(constants: constants, clockStart: now, screen: StoryEngineTests.screen,
                                 rng: RandomSource(seed: 3))
            source = FakeWindowSource(snapshots: windows)
        }

        @discardableResult
        func step(_ commands: [Command] = [], sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            now = now.addingTimeInterval(StoryEngineTests.dt)
            let out = engine.step(FrameInput(poll: source.poll(), screen: StoryEngineTests.screen,
                                             commands: commands, now: now))
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())",
                    sourceLocation: sourceLocation)
            return out
        }

        /// 触发送花（V2）：Home_Window 在同一帧先分配，随后开始第 `flowerCount + 1` 轮。
        @discardableResult
        func startFlower(sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            step([.triggerWish(.flower, nil)], sourceLocation: sourceLocation)
        }

        var story: StoryState { engine.state.story }
        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }
    }

    /// 两个上沿同高、相距 100pt 的窗口（窗口 1 右边缘 x 300，窗口 2 左边缘 x 400）。
    static let apart = [win(1, x: 100, y: 400), win(2, x: 400, y: 400)]
    /// 首尾相接的两个窗口：上沿同高，可直接走过去。
    static let touching = [win(1, x: 100, y: 400), win(2, x: 300, y: 400)]

    // MARK: - 开局与视图

    @Test func defaultEngineAssignsHomesWithoutStartingStory() {
        let h = Harness(Self.apart)
        let out = h.step()
        #expect(h.engine.storyEnabled)
        #expect(h.engine.activitiesEnabled)
        #expect(h.story.stage == nil)
        #expect(h.story.homes == [.a: 1, .b: 2])
        #expect(!out.storyEvents.contains { if case .roundStarted = $0 { true } else { false } })
        // Wish 调度从分配完成起满 1 个 Wish_Check_Interval 时第一次检查（v2 Requirement 6.1）。
        #expect(h.engine.state.wishes.nextCheckAt == h.now.addingTimeInterval(Tunables().wishCheckInterval))
        #expect(h.engine.state.wishes.active.isEmpty)
    }

    @Test func flowerWishStartsStoryAndExposesView() {
        let h = Harness(Self.apart)
        let out = h.startFlower()
        #expect(h.engine.state.wishes.active.map(\.type) == [.flower])
        #expect(h.story.stage == .waiting)
        #expect(h.story.round == 1)
        #expect(h.story.homes == [.a: 1, .b: 2])
        #expect(out.storyEvents.contains(.roundStarted(round: 1, giver: .a, receiver: .b)))
        #expect(out.view.story?.stage == .waiting)
        #expect(out.view.story?.giver == .a && out.view.story?.receiver == .b)
        // 都都抱着本轮的 Story_Flower。
        let flower = h.story.currentFlower
        #expect(flower != nil && h.resident(.a).heldItem == flower)
    }

    @Test func legacyEnginesWithoutDemoResidentHaveNoStory() {
        let engine = WorldEngine(clockStart: Date(timeIntervalSince1970: 0), screen: Self.screen,
                                 rng: RandomSource(seed: 1), demoResident: false)
        var source = FakeWindowSource(snapshots: Self.apart)
        let out = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: Date(timeIntervalSince1970: 0.1)))
        #expect(!engine.storyEnabled)
        #expect(engine.state.residents.isEmpty)
        #expect(out.view.story == nil)
        #expect(engine.state.story.stage == nil)
    }

    // MARK: - Waiting 中显示许愿气泡

    @Test func giverShowsWishBubbleWhileWaitingOnLedge() {
        let h = Harness(Self.apart)
        h.startFlower()
        for _ in 0 ..< 9 { h.step() }
        #expect(h.story.stage == .waiting)
        #expect(h.resident(.a).state == .waiting)
        #expect(h.resident(.a).bubble == .wish(receiver: .b))
        let view = h.step().view
        #expect(view.residents.first { $0.id == .a }?.bubble == .wish(receiver: .b))
    }

    @Test func wishBubbleClearsWhenRouteAppears() {
        let h = Harness(Self.apart)
        h.startFlower()
        for _ in 0 ..< 4 { h.step() }
        #expect(h.resident(.a).bubble == .wish(receiver: .b))
        // 把窗口 2 拉到与窗口 1 首尾相接：路线出现，进入 Travel。
        h.source.move(2, to: Point(x: 300, y: 400))
        h.step()
        #expect(h.story.stage == .travel)
        #expect(h.resident(.a).bubble == nil)
    }

    // MARK: - 剧情跑到 Growing，快进开花并回赠果子

    @Test func storyRunsToDoneWithFastForward() {
        let h = Harness(Self.touching)
        h.startFlower()
        var frames = 0
        while h.story.stage != .growing, frames < 900 { h.step(); frames += 1 }
        #expect(h.story.stage == .growing)

        // 快进两次：pot → sprout → bloom，随后同帧进入 ReturnGift。
        var out = h.step([.fastForward])
        #expect(out.storyEvents.contains { if case .sprouted = $0 { true } else { false } })
        out = h.step([.fastForward])
        #expect(out.storyEvents.contains { if case .bloomed = $0 { true } else { false } })
        #expect(h.story.stage == .returnGift)
        #expect(h.resident(.b).heldItem == h.story.currentFruit)

        // 进入 Done 的同一次更新中 Flower_Wish 完成，Story_Stage 清为 nil（v2 Requirement 8.4）。
        frames = 0
        var fulfilled = false
        while !fulfilled, frames < 900 {
            out = h.step()
            frames += 1
            fulfilled = out.events.contains { $0.type == .wishFulfilled }
        }
        #expect(fulfilled)
        #expect(h.story.stage == nil)
        #expect(h.engine.state.wishes.active.isEmpty)
        #expect(h.engine.state.wishes.lastFlowerDoneAt == h.story.doneAt)

        // 快进只结束 Round_Interval 等待，不直接开始下一轮（v2 Requirement 8.9）。
        out = h.step([.fastForward])
        #expect(h.story.round == 1)
        #expect(!out.storyEvents.contains { if case .roundStarted = $0 { true } else { false } })
        let done = h.engine.state.wishes.lastFlowerDoneAt!
        #expect(h.now.timeIntervalSince(done) >= Tunables().roundInterval)

        // 再触发送花：第 2 轮，嘟嘟送花。
        out = h.startFlower()
        #expect(h.story.round == 2)
        #expect(out.storyEvents.contains(.roundStarted(round: 2, giver: .b, receiver: .a)))
    }

    @Test func fastForwardOutsideGrowingOrDoneChangesNothing() {
        let h = Harness(Self.apart)
        h.startFlower()
        let before = h.story
        h.step([.fastForward])
        #expect(h.story.stage == before.stage && h.story.round == before.round)
    }

    // MARK: - 重置世界（取代 v1「重新开始剧情」）

    @Test func resetWorldClearsItemsKeepsPlanks() {
        let h = Harness(Self.apart)
        h.startFlower()
        let pid = h.engine.insertPlank(.loose(.ground(x: 700)))
        h.step()
        #expect(h.story.stage != nil)
        h.step([.resetWorld])
        #expect(h.story.round == 1)
        #expect(h.engine.state.planks.planks[pid] != nil)
        // 全部 Flower 和 Fruit 被删除，不再自动开局；Home_Window 同一帧重新分配。
        #expect(h.engine.state.items.items.isEmpty)
        #expect(h.resident(.a).heldItem == nil)
        #expect(h.story.stage == nil)
        #expect(h.story.homes == [.a: 1, .b: 2])
        #expect(h.engine.state.wishes.active.isEmpty)
        #expect(h.engine.state.wishes.flowerCount == 0)
        // 之后送花从第 1 轮重新开始。
        h.startFlower()
        #expect(h.story.round == 1 && h.story.giver == .a)
    }

    // MARK: - 调试寻找覆盖

    @Test func debugSeekOverridesStoryGoalUntilArrival() {
        // 第 1 轮进行中（Growing）时都都是 confined；「让都都去找嘟嘟」临时改为 reach(嘟嘟)。
        let h = Harness(Self.touching)
        h.startFlower()
        var frames = 0
        while h.story.stage != .growing, frames < 900 { h.step(); frames += 1 }
        #expect(h.story.stage == .growing)
        #expect(h.resident(.a).goal == .confined)

        // 把都都放回窗口 1 左端，离嘟嘟足够远。
        var a = h.resident(.a)
        a.attachment = .window(1, offset: 10)
        a.route = nil
        h.engine.place(a)
        h.step()
        #expect(h.resident(.a).goal == .confined)

        h.step([.debugSeek])
        #expect(h.resident(.a).goal == .reach(.b))
        h.step()
        #expect(h.resident(.a).goal == .reach(.b))
        #expect(h.story.stage == .growing)

        // 都都走到嘟嘟身边后覆盖结束，Goal 回到剧情分配的值。
        frames = 0
        while h.resident(.a).goal == .reach(.b), frames < 900 { h.step(); frames += 1 }
        #expect(h.resident(.a).goal == .confined)
        #expect(frames > 10)
        #expect(h.story.stage == .growing)
    }
}
