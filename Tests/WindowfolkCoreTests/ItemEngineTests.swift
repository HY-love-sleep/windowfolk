import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 11.3：WorldEngine 接入物件（跟随、夹紧、关闭与失效时下落、隐藏）和「给都都一个花盆」的单元测试。
/// 屏幕 1440×900，Ground y = 825。每次 step 后 Harness 都检查无悬空不变量（含物件）。
struct ItemEngineTests {
    typealias H = BridgeHangTests.Harness
    static let groundY = ResidentFollowAndFallTests.groundY

    static func item(_ h: H, _ id: ItemID) -> Item { h.engine.state.items[id]! }

    /// 推进到物件不再下落为止（最多 3 秒）。
    static func settle(_ h: H, _ id: ItemID) {
        for _ in 0 ..< 90 {
            if case .falling = item(h, id).placement { h.step() } else { return }
        }
    }

    @Test func ledgeItemFollowsWindowMove() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        let id = ItemID()
        h.engine.insertItem(.fruit(id: id, placement: .attached(.window(1, offset: 50))))
        h.step()
        h.source.move(1, to: Point(x: 400, y: 250))
        let out = h.step()
        #expect(Self.item(h, id).placement == .attached(.window(1, offset: 50)))
        #expect(out.view.items.first { $0.id == id }?.position == Point(x: 450, y: 250))
    }

    @Test func ledgeItemClampsWhenWindowShrinks() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        let id = ItemID()
        h.engine.insertItem(.fruit(id: id, placement: .attached(.window(1, offset: 280))))
        h.step()
        h.source.resize(1, to: (150, 200))
        h.step()
        #expect(Self.item(h, id).placement == .attached(.window(1, offset: 150)))
    }

    @Test func fullyCoveredLedgeDropsItemToLowerLedge() {
        // 窗口 2 在前、完全盖住窗口 1 的上沿；下方窗口 3 的上沿 y = 600 接住物件。
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200), BridgeHangTests.win(3, 100, 600, 300, 150)])
        let id = ItemID()
        h.engine.insertItem(.fruit(id: id, placement: .attached(.window(1, offset: 100))))
        h.step()
        h.source.add(BridgeHangTests.win(2, 50, 250, 400, 200))
        h.source.bringToFront(2)
        h.step()
        guard case .falling = Self.item(h, id).placement else { Issue.record("应下落"); return }
        Self.settle(h, id)
        #expect(Self.item(h, id).placement == .attached(.window(3, offset: 100)))
    }

    @Test func closingWindowDropsItemToGround() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        let id = ItemID()
        h.engine.insertItem(.flowerPot(id: id, placement: .attached(.window(1, offset: 60))))
        h.step()
        h.source.close(1)
        h.step()
        guard case let .falling(f) = Self.item(h, id).placement else { Issue.record("应下落"); return }
        #expect(f.position.x == 160)
        Self.settle(h, id)
        #expect(Self.item(h, id).placement == .attached(.ground(x: 160)))
    }

    @Test func hiddenWindowKeepsItemAndClosedWhileHiddenFallsFromLastVisible() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        let id = ItemID()
        h.engine.insertItem(.fruit(id: id, placement: .attached(.window(1, offset: 70))))
        h.step()
        h.source.hide(1)
        for _ in 0 ..< 30 {
            let out = h.step()
            #expect(!out.view.items.contains { $0.id == id })
        }
        #expect(Self.item(h, id).placement == .attached(.window(1, offset: 70)))
        h.source.close(1)
        h.step()
        guard case let .falling(f) = Self.item(h, id).placement else { Issue.record("应下落"); return }
        #expect(f.position.x == 170)
        #expect(f.position.y > 300 && f.position.y < 320)
    }

    @Test func failingPlankDropsItemOnIt() {
        let (h, pid) = BridgeHangTests.bridgeScene()
        let id = ItemID()
        h.engine.insertItem(.fruit(id: id, placement: .attached(.plank(pid, t: 0.5))))
        var out = h.step()
        #expect(out.view.items.first { $0.id == id }?.position == Point(x: 450, y: 300))
        h.source.move(2, to: Point(x: 900, y: 300))
        out = h.step()
        #expect(out.failedPlanks == [pid])
        guard case let .falling(f) = Self.item(h, id).placement else { Issue.record("应下落"); return }
        #expect(f.position.x == 450)
        Self.settle(h, id)
        #expect(Self.item(h, id).placement == .attached(.ground(x: 450)))
    }

    @Test func fallingItemLandsOnPlacedPlank() {
        let (h, pid) = BridgeHangTests.bridgeScene()
        let id = ItemID()
        h.engine.insertItem(.fruit(id: id, placement: .falling(FallState(position: Point(x: 450, y: 100)))))
        h.step()
        Self.settle(h, id)
        #expect(Self.item(h, id).placement == .attached(.plank(pid, t: 0.5)))
    }

    @Test func heldItemFallsWithResidentWhenWindowCloses() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        h.engine.place(BridgeHangTests.idle(.a, window: 1, offset: 100))
        h.step([.debugGiveFlower])
        let held = h.resident(.a).heldItem
        #expect(held != nil)
        h.source.close(1)
        h.step()
        #expect(h.resident(.a).state == .falling)
        for _ in 0 ..< 90 where h.resident(.a).state == .falling { h.step() }
        #expect(h.resident(.a).heldItem == held)
        #expect(held.flatMap { h.engine.state.items[$0]?.placement } == .held(.a))
    }

    @Test func debugGiveFlowerGivesPotOnlyWhenEmptyHanded() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        h.engine.place(BridgeHangTests.idle(.a, window: 1, offset: 100))
        let out = h.step([.debugGiveFlower])
        guard let id = h.resident(.a).heldItem, let flower = h.engine.state.items[id] else {
            Issue.record("都都应持有花盆"); return
        }
        #expect(flower.kind == .flower(storyRound: nil))
        #expect(flower.stage == .pot && flower.growth?.plantedAt == nil)
        #expect(out.view.items.first { $0.id == id }?.holder == .a)

        h.step([.debugGiveFlower])
        #expect(h.resident(.a).heldItem == id)
        #expect(h.engine.state.items.items.count == 1)
    }

    @Test func debugGiveFlowerKeepsExistingFruit() {
        let h = H([BridgeHangTests.win(1, 100, 300, 300, 200)])
        h.engine.place(BridgeHangTests.idle(.a, window: 1, offset: 100))
        let fruit = Item.fruit(placement: .attached(.ground(x: 10)))
        #expect(h.engine.give(fruit, to: .a))
        h.step([.debugGiveFlower])
        #expect(h.resident(.a).heldItem == fruit.id)
        #expect(h.engine.state.items.items.count == 1)
    }
}
