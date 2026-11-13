import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 3.2：Decor 的拖出、拖动、放置与收回交互的单元测试。
/// 屏幕 1440×900，Ground y = 825；窗口 1 位于 (100, 300)，宽 300，上沿 y = 300。
struct DecorInteractionUnitTests {
    typealias H = BridgeHangTests.Harness

    static let window = BridgeHangTests.win(1, 100, 300, 300, 200)

    /// 发送一组指针事件并推进一帧。
    @discardableResult
    static func send(_ h: H, _ pointer: [PointerEvent], sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
        h.now = h.now.addingTimeInterval(BridgeHangTests.dt)
        let out = h.engine.step(FrameInput(poll: h.source.poll(), screen: BridgeHangTests.screen,
                                           pointer: pointer, now: h.now))
        #expect(h.engine.invariantViolations().isEmpty, "\(h.engine.invariantViolations())",
                sourceLocation: sourceLocation)
        return out
    }

    static func slotCenter(_ h: H, _ t: DecorType) -> Point {
        let r = ToolboxLayout.zoneFrame(.decor(t), screen: BridgeHangTests.screen,
                                        unlocked: h.engine.state.decors.unlocked)!
        return Point(x: r.midX, y: r.midY)
    }

    static func decorEvents(_ out: StepOutput) -> [EventRecord] {
        out.events.filter { [.decorPlaced, .decorRemoved, .decorUnlocked].contains($0.type) }
    }

    static func chair(_ id: UInt64, _ a: CoreAttachment) -> Decor {
        Decor(id: DecorID(id), type: .chair, placement: .attached(a))
    }

    // MARK: - 从 Decor_Slot 拖出（v2 Requirement 2.3、2.5、3.1、3.2、3.10）

    @Test func dragFromSlotFollowsPointerAndAttachesToLedge() {
        let h = H([Self.window])
        h.engine.unlockDecor(.chair)
        h.step()
        let start = Self.slotCenter(h, .chair)
        var out = Self.send(h, [.down(start), .moved(Point(x: start.x - 10, y: start.y))])
        #expect(out.interactions == [.dragStarted(.decor(DecorID(1)))])
        #expect(h.engine.state.decors.count == 1)

        out = Self.send(h, [.moved(Point(x: 250, y: 280))])
        let grab = InteractionController.freshDecorGrabOffset(.chair)
        let dragged = out.view.decors.first { $0.id == DecorID(1) }
        #expect(dragged?.isDragged == true)
        #expect(dragged?.position == Point(x: 250 - grab.x, y: 280 - grab.y))
        // 光标位于 Decor 图形中心。
        #expect(dragged.map { SpriteMetrics.decorRect(type: .chair, bottomCenter: $0.position).center }
                == Point(x: 250, y: 280))
        #expect(!out.view.hitRegions.contains { $0.target == .decor(DecorID(1)) })

        out = Self.send(h, [.up(Point(x: 250, y: 280))])
        #expect(h.engine.state.decors.decors[DecorID(1)]?.placement == .attached(.window(1, offset: 150)))
        #expect(h.engine.state.decors.decors[DecorID(1)]!.placedSeq > 0)
        let events = Self.decorEvents(out)
        #expect(events.count == 1)
        #expect(events.first?.type == .decorPlaced)
        #expect(events.first?.actor == EventRecord.playerActor)
        #expect(events.first?.target == "decor:1")
        #expect(events.first?.detail == ["decor_type": "chair", "surface": "window_ledge"])
        #expect(out.view.hitRegions.contains {
            $0.target == .decor(DecorID(1))
                && $0.rect == SpriteMetrics.decorRect(type: .chair, bottomCenter: Point(x: 250, y: 300))
        })
    }

    @Test func clickOnSlotCreatesNothing() {
        let h = H([])
        h.engine.unlockDecor(.lamp)
        h.step()
        let p = Self.slotCenter(h, .lamp)
        let out = Self.send(h, [.down(p), .moved(Point(x: p.x + 3, y: p.y)), .up(Point(x: p.x + 4, y: p.y))])
        #expect(h.engine.state.decors.count == 0)
        #expect(out.view.decors.isEmpty)
        #expect(Self.decorEvents(out).isEmpty)
    }

    @Test func slotAtLimitShakesAndSwallowsGesture() {
        let h = H([])
        h.engine.unlockDecor(.chair)
        let k = Tunables()
        for i in 1 ... k.maxDecorCount {
            h.engine.insertDecor(Self.chair(UInt64(i), .ground(x: 200 + Double(i) * 30)))
        }
        h.step()
        let p = Self.slotCenter(h, .chair)
        var out = Self.send(h, [.down(p), .moved(Point(x: 500, y: 500))])
        #expect(h.engine.state.decors.count == k.maxDecorCount)
        #expect(h.engine.state.gesture == .swallowed)
        #expect(out.view.toolboxShake == ToolboxShake(zone: .decor(.chair), remaining: k.toolboxShakeDuration))
        #expect(!out.interactions.contains { if case .dragStarted = $0 { return true } else { return false } })
        out = Self.send(h, [.moved(Point(x: 600, y: 500)), .up(Point(x: 600, y: 500))])
        #expect(h.engine.state.decors.count == k.maxDecorCount)
        #expect(!out.view.decors.contains { $0.isDragged })
        #expect(Self.decorEvents(out).isEmpty)
        // 晃动不超过 0.5 秒后结束。
        for _ in 0 ..< 15 { out = h.step() }
        #expect(out.view.toolboxShake == nil)
    }

    @Test func freshDecorReleasedOnToolboxIsDiscardedWithoutEvents() {
        let h = H([])
        h.engine.unlockDecor(.chair)
        h.step()
        let p = Self.slotCenter(h, .chair)
        let out = Self.send(h, [.down(p), .moved(Point(x: p.x - 30, y: p.y - 40)), .up(Point(x: p.x - 30, y: p.y - 40))])
        #expect(out.interactions.contains(.decorDiscarded(DecorID(1))))
        #expect(h.engine.state.decors.count == 0)
        #expect(Self.decorEvents(out).isEmpty)
    }

    @Test func releaseInAirFallsAndWritesPlacedOnceOnLanding() {
        let h = H([])
        h.engine.unlockDecor(.lamp)
        h.step()
        let p = Self.slotCenter(h, .lamp)
        var all: [EventRecord] = []
        var out = Self.send(h, [.down(p), .moved(Point(x: 600, y: 200)), .up(Point(x: 600, y: 200))])
        all += Self.decorEvents(out)
        guard case .falling(_, byPlayer: true) = h.engine.state.decors.decors[DecorID(1)]?.placement else {
            Issue.record("应为玩家下落"); return
        }
        for _ in 0 ..< 60 {
            out = h.step()
            all += Self.decorEvents(out)
        }
        #expect(h.engine.state.decors.decors[DecorID(1)]?.placement == .attached(.ground(x: 600)))
        #expect(all.count == 1)
        #expect(all.first?.type == .decorPlaced)
        #expect(all.first?.detail == ["decor_type": "lamp", "surface": "ground"])
    }

    // MARK: - 拖动已有 Decor（v2 Requirement 3.4、3.6）

    @Test func clickOnPlacedDecorChangesNothing() {
        let h = H([Self.window])
        h.engine.insertDecor(Self.chair(1, .window(1, offset: 100)))
        h.step()
        let c = SpriteMetrics.decorRect(type: .chair, bottomCenter: Point(x: 200, y: 300)).center
        let out = Self.send(h, [.down(c), .moved(Point(x: c.x + 2, y: c.y + 2)), .up(Point(x: c.x + 2, y: c.y + 2))])
        #expect(h.engine.state.decors.decors[DecorID(1)]?.placement == .attached(.window(1, offset: 100)))
        #expect(out.events.isEmpty)
    }

    @Test func draggedDecorKeepsGrabOffsetAndMovesToGround() {
        let h = H([Self.window])
        h.engine.insertDecor(Self.chair(1, .window(1, offset: 100)))
        h.step()
        let press = Point(x: 205, y: 290)   // 底边中点 (200, 300) 右上方
        var out = Self.send(h, [.down(press), .moved(Point(x: 705, y: 400))])
        #expect(out.interactions == [.dragStarted(.decor(DecorID(1)))])
        #expect(h.engine.state.decors.decors[DecorID(1)]?.placement
                == .dragged(grabOffset: Point(x: 5, y: -10), fresh: false))
        #expect(out.view.decors.first?.position == Point(x: 700, y: 410))
        out = Self.send(h, [.up(Point(x: 705, y: 805))])   // 底边 815，Ground 825 在吸附距离内，但 Ground 不吸附
        guard case .falling(_, byPlayer: true) = h.engine.state.decors.decors[DecorID(1)]?.placement else {
            Issue.record("应为玩家下落"); return
        }
        var events = Self.decorEvents(out)
        for _ in 0 ..< 30 { events += Self.decorEvents(h.step()) }
        #expect(h.engine.state.decors.decors[DecorID(1)]?.placement == .attached(.ground(x: 700)))
        #expect(events.map(\.type) == [.decorPlaced])
    }

    @Test func placedDecorReturnedToToolboxIsRemoved() {
        let h = H([])
        h.engine.insertDecor(Self.chair(1, .ground(x: 600)))
        h.step()
        let c = SpriteMetrics.decorRect(type: .chair, bottomCenter: Point(x: 600, y: 825)).center
        let tb = ToolboxLayout.frame(screen: BridgeHangTests.screen, unlocked: [])
        let drop = Point(x: tb.midX, y: tb.minY - 20)   // 外框上方 20pt，不超过 Toolbox_Return_Distance
        let out = Self.send(h, [.down(c), .moved(drop), .up(drop)])
        #expect(h.engine.state.decors.count == 0)
        #expect(out.interactions.contains(.decorRemoved(DecorID(1), .chair)))
        let events = Self.decorEvents(out)
        #expect(events.count == 1)
        #expect(events.first?.type == .decorRemoved)
        #expect(events.first?.target == "decor:1")
        #expect(events.first?.detail == ["decor_type": "chair"])
        #expect(out.view.decors.isEmpty)
    }

    // MARK: - 命中优先级（v2 Requirement 3.7）

    @Test func residentBeatsDecorAndDecorBeatsToolbox() {
        let rect = Rect(minX: 0, minY: 0, width: 50, height: 50)
        let p = Point(x: 10, y: 10)
        let regions = [
            HitRegion(target: .toolbox(.plank), rect: rect),
            HitRegion(target: .plank(PlankID(1)), rect: rect),
            HitRegion(target: .decor(DecorID(1)), rect: rect),
        ]
        #expect(HitTesting.hitTest(p, regions: regions) == .decor(DecorID(1)))
        #expect(HitTesting.hitTest(p, regions: regions + [HitRegion(target: .item(ItemID()), rect: rect)])?
            .priority == 1)
        #expect(HitTesting.hitTest(p, regions: regions + [HitRegion(target: .resident(.a), rect: rect)])
                == .resident(.a))
    }
}
