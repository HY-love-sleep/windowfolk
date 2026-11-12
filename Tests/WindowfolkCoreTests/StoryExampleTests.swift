import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 13.13：剧情的具体例子，用 WorldEngine（剧情启用）+ FakeWindowSource + 手动时钟驱动。
/// 「Done 中快进立即开始下一轮」已由 StoryEngineTests.storyRunsToDoneWithFastForward 覆盖，这里不重复。
struct StoryExampleTests {
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

        init(_ windows: [WindowSnapshot]) {
            engine = WorldEngine(clockStart: now, screen: StoryExampleTests.screen,
                                 rng: RandomSource(seed: 11), story: true)
            source = FakeWindowSource(snapshots: windows)
        }

        @discardableResult
        func step(_ commands: [Command] = [], sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            now = now.addingTimeInterval(StoryExampleTests.dt)
            let out = engine.step(FrameInput(poll: source.poll(), screen: StoryExampleTests.screen,
                                             commands: commands, now: now))
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())",
                    sourceLocation: sourceLocation)
            return out
        }

        /// 推进直到条件成立或达到帧数上限，返回是否成立。
        @discardableResult
        func run(max frames: Int = 1800, until done: () -> Bool) -> Bool {
            for _ in 0 ..< frames {
                if done() { return true }
                step()
            }
            return done()
        }

        var story: StoryState { engine.state.story }
        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }

        /// 把居民移到 `attachment` 处，保留持有物，清除路线和动作。
        func move(_ id: ResidentID, to attachment: CoreAttachment) {
            var r = resident(id)
            r.attachment = attachment
            r.state = .idle
            r.route = nil
            r.traversal = nil
            r.fall = nil
            r.wander = WanderState()
            engine.place(r)
        }

        func flowerPlacement() -> ItemPlacement? {
            story.currentFlower.flatMap { engine.state.items[$0]?.placement }
        }
    }

    static let apart = [win(1, x: 100, y: 400), win(2, x: 400, y: 400)]
    static let touching = [win(1, x: 100, y: 400), win(2, x: 300, y: 400)]

    // MARK: - 窗口不足时在 Ground 活动，窗口够了之后开局（Requirement 15.6、15.7）

    @Test func residentsStayOnGroundUntilTwoWindowsThenBegin() {
        let h = Harness([Self.win(1, x: 100, y: 400)])
        for _ in 0 ..< 240 {
            h.step()
            #expect(h.story.stage == nil)
            for id in ResidentID.allCases {
                let r = h.resident(id)
                if case .ground = r.attachment {} else { Issue.record("\(id) not on ground: \(r.attachment)") }
                #expect(r.state == .idle || r.state == .walking)
                #expect(r.heldItem == nil)
            }
        }
        #expect(h.engine.state.items.items.isEmpty)

        h.source.add(Self.win(2, x: 700, y: 400))
        let out = h.step()
        #expect(h.story.homes == [.a: 1, .b: 2])
        #expect(h.story.stage == .waiting)
        #expect(out.storyEvents.contains(.roundStarted(round: 1, giver: .a, receiver: .b)))
        #expect(h.resident(.a).heldItem == h.story.currentFlower)
        if case .window(1, _) = h.resident(.a).attachment {} else { Issue.record("A not home") }
        if case .window(2, _) = h.resident(.b).attachment {} else { Issue.record("B not home") }
    }

    // MARK: - 种花落点：Window_Ledge、Plank、Ground（Requirement 16.11）

    @Test func flowerPlantedOnReceiversWindowLedge() throws {
        let h = Harness(Self.touching)
        #expect(h.run { h.story.stage == .growing })
        let placement = try #require(h.flowerPlacement())
        guard case let .attached(.window(wid, offset)) = placement else {
            Issue.record("flower not on ledge: \(placement)"); return
        }
        #expect(wid == 2)
        #expect(offset >= 0 && offset <= 200)
        #expect(h.resident(.a).heldItem == nil)
        let flower = try #require(h.story.currentFlower.flatMap { h.engine.state.items[$0] })
        #expect(flower.stage == .pot)
        #expect(flower.growth?.plantedAt != nil)
    }

    @Test func flowerPlantedOnPlankWhenReceiverStandsOnIt() throws {
        let h = Harness(Self.apart)
        let pid = h.engine.insertPlank(.placed(PlacedPlank(
            id: PlankID(0), endA: PlankEnd(window: 1, offset: 200), endB: PlankEnd(window: 2, offset: 0))))
        h.step()
        #expect(h.story.stage == .travel)
        h.move(.b, to: .plank(pid, t: 0.5))
        #expect(h.run { h.story.stage == .growing })
        let placement = try #require(h.flowerPlacement())
        guard case .attached(.plank(pid, _)) = placement else {
            Issue.record("flower not on plank: \(placement)"); return
        }
    }

    @Test func flowerPlantedOnGroundWhenBothOnGround() throws {
        let h = Harness(Self.apart)
        h.step()
        #expect(h.story.stage == .waiting)
        h.move(.a, to: .ground(x: 300))
        h.move(.b, to: .ground(x: 600))
        h.step()
        #expect(h.story.stage == .travel)
        #expect(h.run { h.story.stage == .growing })
        let placement = try #require(h.flowerPlacement())
        guard case .attached(.ground) = placement else {
            Issue.record("flower not on ground: \(placement)"); return
        }
    }

    // MARK: - 种花时窗口隐藏暂停计时（Requirement 16.14）

    @Test func plantingTimerPausesWhileHomeHidden() throws {
        let h = Harness(Self.touching)
        #expect(h.run { h.story.stage == .planting })
        h.step()
        h.step()
        // 两人都在窗口 2 上种花。
        for id in ResidentID.allCases {
            if case .window(2, _) = h.resident(id).attachment {} else { Issue.record("\(id) not on window 2") }
        }
        h.source.hide(2)
        h.step()
        let paused = h.story.plantingElapsed
        #expect(paused > 0 && paused < Tunables().plantAnimationDuration)
        for _ in 0 ..< 120 { h.step() }
        #expect(h.story.stage == .planting)
        #expect(h.story.plantingElapsed == paused)
        #expect(h.resident(.a).state == .planting && h.resident(.b).state == .planting)
        #expect(h.resident(.a).heldItem == h.story.currentFlower)

        h.source.show(2)
        h.step()
        #expect(h.story.plantingElapsed > paused)
        let remaining = Int(((Tunables().plantAnimationDuration - paused) / Self.dt).rounded(.up)) + 2
        #expect(h.run(max: remaining) { h.story.stage == .growing })
    }

    // MARK: - ReturnGift 中 Receiver 掉落后继续送果子（Requirement 18.6、18.7、18.8）

    @Test func receiverKeepsFruitAfterFallAndDeliversOnGround() throws {
        let h = Harness(Self.touching)
        #expect(h.run { h.story.stage == .growing })
        h.step([.fastForward])
        h.step([.fastForward])
        // 开花与回赠同一次 step 完成；两人此时还相邻，下一次 step 之前先把都都移开。
        #expect(h.story.stage == .returnGift)
        let fruit = try #require(h.story.currentFruit)
        #expect(h.resident(.b).heldItem == fruit)

        // 都都被放到 Ground 上；嘟嘟所在的窗口 2 被关闭，嘟嘟抱着果子掉下去。
        h.move(.a, to: .ground(x: 1000))
        h.source.close(2)
        h.step()
        #expect(h.resident(.b).state == .falling)
        var sawFall = false
        while h.resident(.b).state == .falling || h.resident(.b).state == .hanging {
            sawFall = true
            #expect(h.story.stage == .returnGift)
            #expect(h.resident(.b).heldItem == fruit)
            h.step()
        }
        #expect(sawFall)
        if case .ground = h.resident(.b).attachment {} else { Issue.record("B not on ground") }
        #expect(h.resident(.b).heldItem == fruit)
        #expect(h.story.stage == .returnGift)
        #expect(h.resident(.b).goal == .reach(.a))

        #expect(h.run { h.story.stage == .done })
        let placement = try #require(h.engine.state.items[fruit]?.placement)
        guard case let .attached(.ground(x)) = placement else {
            Issue.record("fruit not on ground: \(placement)"); return
        }
        #expect(abs(x - h.engine.state.residents[.a]!.screenXOnGround) <= Tunables().giftReachDistance)
        #expect(h.resident(.b).heldItem == nil)
        #expect(h.resident(.a).state == .celebrating && h.resident(.b).state == .celebrating)

        let frames = Int(StoryDirector.celebrateDuration / Self.dt) + 3
        for _ in 0 ..< frames { h.step() }
        for id in ResidentID.allCases {
            #expect(h.resident(id).state == .idle || h.resident(id).state == .walking)
        }
        #expect(h.story.stage == .done)
    }
}

private extension Resident {
    /// Ground 上居民的屏幕 x。
    var screenXOnGround: Double {
        if case let .ground(x) = attachment { return x }
        return .nan
    }
}
