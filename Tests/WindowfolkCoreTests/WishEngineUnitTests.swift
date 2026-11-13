import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 7.4：WishDirector 接入 WorldEngine 后的编排例子（命令、事件顺序、气泡、Visit_Flag、成为 Busy、重置世界）。
/// 各 Wish 的完整规则由 7.5 至 7.19 的属性测试和例子覆盖，这里只验证接线。
struct WishEngineUnitTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    /// UTC 08:00，不是 Night。
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 窗口 1 与窗口 3 相距最远，分别是都都和嘟嘟的家；窗口 2 是唯一的 Visit_Target 候选。
    static let windows = [
        StoryEngineTests.win(1, x: 100, y: 400),
        StoryEngineTests.win(2, x: 400, y: 400),
        StoryEngineTests.win(3, x: 900, y: 400),
    ]

    final class Harness {
        let engine: WorldEngine
        var source = FakeWindowSource(snapshots: WishEngineUnitTests.windows)
        var now = WishEngineUnitTests.t0

        init() {
            engine = WorldEngine(clockStart: now, screen: WishEngineUnitTests.screen, rng: RandomSource(seed: 5))
        }

        @discardableResult
        func step(_ commands: [Command] = [], sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            now = now.addingTimeInterval(1.0 / 30)
            let out = engine.step(FrameInput(poll: source.poll(), screen: WishEngineUnitTests.screen,
                                             commands: commands, now: now, timeZone: WishEngineUnitTests.utc))
            #expect(engine.invariantViolations().isEmpty, sourceLocation: sourceLocation)
            return out
        }

        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }
    }

    @Test func unlockAllDecorRecordsEachTypeOnce() {
        let h = Harness()
        let first = h.step([.unlockAllDecor])
        #expect(h.engine.state.decors.unlocked == [.chair, .lamp])
        #expect(first.view.unlockedDecor == [.chair, .lamp])
        let unlocked = first.events.filter { $0.type == .decorUnlocked }
        #expect(unlocked.map { $0.detail["decor_type"] } == ["chair", "lamp"])
        #expect(unlocked.allSatisfy { $0.actor == nil && $0.target == nil })
        let second = h.step([.unlockAllDecor])
        #expect(!second.events.contains { $0.type == .decorUnlocked })
    }

    @Test func chairWishStartsBeforeUnlockAndShowsBubble() {
        let h = Harness()
        h.step()
        let out = h.step([.triggerWish(.chair, .b)])
        let types = out.events.map(\.type)
        #expect(types.firstIndex(of: .wishStarted).map { s in
            types.firstIndex(of: .decorUnlocked).map { s < $0 } ?? false
        } == true)
        let started = out.events.first { $0.type == .wishStarted }
        #expect(started?.actor == "resident_b" && started?.target == nil)
        #expect(started?.detail == ["wish_type": "chair", "wish_state": "active"])
        #expect(h.engine.state.wishes.busy == [.b])
        #expect(h.engine.state.activities[.b] == nil)
        #expect(out.view.residents.first { $0.id == .b }?.bubble == .wishIcon(.chair))
        #expect(out.view.residents.first { $0.id == .a }?.bubble == nil)
    }

    @Test func sleepingResidentWakesWhenBecomingBusy() throws {
        let h = Harness()
        h.step()
        // 让都都在一盏 Lamp 旁睡着（直接设置状态，模拟已入睡）。
        let lamp = DecorID(1)
        h.engine.insertDecor(Decor(id: lamp, type: .lamp, placement: .attached(.window(1, offset: 100))))
        var a = h.resident(.a)
        a.state = .sleeping
        a.walkDistance = 300
        h.engine.place(a)
        h.engine.state.activities[.a] = Activity(kind: .sleep, target: .lamp(lamp), startedAt: h.now, phase: .sleeping)
        h.engine.state.dayNightOverride = .night

        let out = h.step([.triggerWish(.visit, .a)])
        let types = out.events.map(\.type)
        let started = try #require(types.firstIndex(of: .wishStarted))
        let woke = try #require(out.events.firstIndex { $0.type == .woke })
        #expect(started < woke)
        #expect(out.events[woke].detail == ["reason": "became_busy"])
        #expect(h.resident(.a).state != .sleeping)
        #expect(h.resident(.a).walkDistance == 0)
        #expect(h.engine.state.activities[.a] == nil)
    }

    @Test func visitWishShowsFlagAndFulfillsWithVisitedFirst() throws {
        let h = Harness()
        h.step()
        #expect(h.engine.state.story.homes == [.a: 1, .b: 3])
        var out = h.step([.triggerWish(.visit, .a)])
        let wish = try #require(h.engine.state.wishes.active.first)
        #expect(wish.visitTarget?.window == 2)
        #expect(out.events.first { $0.type == .wishStarted }?.target == "app:App2")
        // 旗在窗口 2 窗沿中点；窗口 2 在都都右边，箭头朝右。
        #expect(out.view.visitFlags == [Point(x: 500, y: 400)])
        #expect(out.view.residents.first { $0.id == .a }?.bubble == .wishIcon(.flag(arrow: .right)))

        // 窗口 2 隐藏：旗不画（v2 Requirement 9.7）。
        h.source.hide(2)
        out = h.step()
        #expect(out.view.visitFlags.isEmpty)
        h.source.show(2)
        out = h.step()
        #expect(out.view.visitFlags.count == 1)

        // 都都站到窗口 2 的窗沿上：同一帧先写 visited 再写 wish_fulfilled，旗与气泡消失。
        var a = h.resident(.a)
        a.attachment = .window(2, offset: 50)
        a.route = nil
        h.engine.place(a)
        out = h.step()
        let types = out.events.map(\.type)
        let visited = try #require(types.firstIndex(of: .visited))
        let fulfilled = try #require(types.firstIndex(of: .wishFulfilled))
        #expect(visited < fulfilled)
        #expect(out.events[visited].target == "app:App2")
        #expect(out.events[visited].detail == ["source": "visit_wish"])
        #expect(out.events[fulfilled].detail == ["wish_type": "visit", "wish_state": "fulfilled"])
        #expect(out.view.visitFlags.isEmpty)
        #expect(h.engine.state.wishes.active.isEmpty)
        #expect(h.resident(.a).state == .celebrating)
        if case .wishIcon? = h.resident(.a).bubble { Issue.record("wish bubble still shown") }
        // 庆祝结束后选择下一个 Activity 时 go_home 在候选中（v2 Requirement 9.8）。
        #expect(h.engine.preferHome == [.a])
        for _ in 0 ..< 60 { h.step() }
        #expect(h.resident(.a).state != .celebrating)
        #expect(h.engine.state.activities[.a] != nil)
        #expect(h.engine.preferHome.isEmpty)
    }

    @Test func resetWorldClearsDecorWishesAndReassignsHomes() {
        let h = Harness()
        h.step([.setDayNight(.night)])
        h.engine.insertDecor(Decor(id: DecorID(1), type: .chair, placement: .attached(.ground(x: 700))))
        h.step([.triggerWish(.lamp, .a)])
        h.step([.triggerWish(.chair, .b)])
        var b = h.resident(.b)
        b.walkDistance = 900
        h.engine.place(b)
        #expect(h.engine.state.wishes.active.count == 2)
        #expect(h.engine.state.decors.unlocked == [.chair, .lamp])

        let out = h.step([.resetWorld])
        let st = h.engine.state
        #expect(st.wishes.active.isEmpty)
        #expect(st.wishes.flowerCount == 0 && st.wishes.lastEnded.isEmpty && st.wishes.lastFlowerDoneAt == nil)
        #expect(st.decors.count == 0 && st.decors.unlocked.isEmpty)
        #expect(st.story.homes == [.a: 1, .b: 3])
        #expect(st.wishes.nextCheckAt != nil)
        #expect(st.dayNightOverride == .night)
        #expect(st.residents.values.allSatisfy { $0.walkDistance == 0 })
        #expect(!out.events.contains { [.wishDropped, .wishFulfilled].contains($0.type) })
        #expect(out.view.residents.allSatisfy { r in
            if case .wishIcon? = r.bubble { return false }
            return true
        })
    }
}
