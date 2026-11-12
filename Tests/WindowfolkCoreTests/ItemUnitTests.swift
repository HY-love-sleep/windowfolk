import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 11.1：Item 模型与居民持有的单元测试。
struct ItemUnitTests {
    typealias H = BridgeHangTests

    // MARK: - 模型

    @Test func flowerPotStartsAsUnplantedPot() {
        let pot = Item.flowerPot(storyRound: 1, placement: .attached(.ground(x: 10)))
        #expect(pot.stage == .pot)
        #expect(pot.growth?.plantedAt == nil)
        #expect(pot.kind.isStoryFlower)
        #expect(pot.assetKey == "flower_pot")
        #expect(!Item.flowerPot(placement: .attached(.ground(x: 0))).kind.isStoryFlower)

        let fruit = Item.fruit(placement: .attached(.ground(x: 10)))
        #expect(fruit.growth == nil && fruit.stage == nil)
        #expect(fruit.assetKey == AssetCatalog.fruitKey)
    }

    @Test func growthStageOrderAndAssetKeys() throws {
        #expect(GrowthStage.pot < .sprout && GrowthStage.sprout < .bloom)
        for stage in GrowthStage.allCases {
            #expect(AssetCatalog.spec(AssetCatalog.flowerKey(growth: stage)) != nil)
        }
        let data = try JSONEncoder().encode(FlowerGrowth(plantedAt: nil, reached: .sprout))
        #expect(String(decoding: data, as: UTF8.self).contains("\"sprout\""))
        #expect(try JSONDecoder().decode(FlowerGrowth.self, from: data).reached == .sprout)
    }

    // MARK: - 持有规则（Requirement 14.3、11.9）

    @Test func residentHoldsAtMostOneItem() {
        var store = ItemStore()
        var r = Resident(id: .a, attachment: .ground(x: 100))
        let first = Item.flowerPot(placement: .attached(.ground(x: 0)))
        let second = Item.fruit(placement: .attached(.ground(x: 0)))
        #expect(store.give(first, to: &r))
        #expect(!store.give(second, to: &r))
        #expect(r.heldItem == first.id)
        #expect(store[second.id] == nil)
        #expect(store.holder(of: first.id) == .a)
        #expect(store.holdingViolations(residents: [.a: r]).isEmpty)
    }

    @Test func heldOrDraggedItemCannotBeTakenByAnother() {
        var store = ItemStore()
        var a = Resident(id: .a, attachment: .ground(x: 100))
        var b = Resident(id: .b, attachment: .ground(x: 200))
        let pot = Item.flowerPot(placement: .attached(.ground(x: 0)))
        #expect(store.give(pot, to: &a))
        #expect(!store.give(store[pot.id]!, to: &b))
        #expect(b.heldItem == nil)

        let dragged = Item.fruit(placement: .dragged(grabOffset: Point(x: 0, y: 0)))
        store[dragged.id] = dragged
        #expect(!store.give(dragged, to: &b))
        #expect(store[dragged.id]?.placement == .dragged(grabOffset: Point(x: 0, y: 0)))
    }

    @Test func releasePlacesItemAndClearsHolder() {
        var store = ItemStore()
        var r = Resident(id: .b, attachment: .ground(x: 100))
        let fruit = Item.fruit(placement: .attached(.ground(x: 0)))
        store.give(fruit, to: &r)
        #expect(store.release(from: &r, to: .attached(.ground(x: 100))) == fruit.id)
        #expect(r.heldItem == nil)
        #expect(store[fruit.id]?.placement == .attached(.ground(x: 100)))
        #expect(store.holdingViolations(residents: [.b: r]).isEmpty)
    }

    // MARK: - 引擎中的持有（Requirement 14.1、14.2、14.4 至 14.6、13.3）

    @Test func heldItemFollowsResidentThroughHangFallAndLanding() {
        let (h, pid) = H.bridgeScene()
        h.engine.place(H.idle(.a, plank: pid, t: 0.5))
        let pot = Item.flowerPot(placement: .attached(.ground(x: 0)))
        #expect(h.engine.give(pot, to: .a))
        #expect(!h.engine.give(Item.fruit(placement: .attached(.ground(x: 0))), to: .a))

        func check(_ out: StepOutput) {
            let rv = out.view.residents.first { $0.id == .a }!
            let iv = out.view.items.first { $0.id == pot.id }
            #expect(h.resident(.a).heldItem == pot.id)
            #expect(h.engine.state.items[pot.id]?.placement == .held(.a))
            #expect(iv?.holder == .a)
            if let p = rv.position {
                #expect(iv?.position == ItemHolding.heldPosition(residentPosition: p))
            }
        }

        check(h.step())
        h.source.move(2, to: Point(x: 900, y: 300))   // 木板失效：悬挂，再下落
        var frames = 0
        repeat {
            check(h.step())
            frames += 1
        } while h.resident(.a).state != .idle && frames < 300
        #expect(h.resident(.a).attachment == .ground(x: 450))
        #expect(h.engine.state.items.holdingViolations(residents: h.engine.state.residents).isEmpty)
    }

    @Test func wanderingWithItemIsCarryingAtCarrySpeed() {
        let h = H.Harness([H.win(1, 100, 300, 400, 300)])
        h.engine.place(Resident(id: .a, attachment: .window(1, offset: 100),
                                wander: WanderState(pauseRemaining: 0)))
        #expect(h.engine.give(Item.flowerPot(placement: .attached(.ground(x: 0))), to: .a))
        h.step()  // 起步
        #expect(h.resident(.a).state == .carrying)
        guard case let .window(_, o0) = h.resident(.a).attachment else { Issue.record("not on window"); return }
        h.step()
        guard case let .window(_, o1) = h.resident(.a).attachment else { Issue.record("not on window"); return }
        #expect(h.resident(.a).state == .carrying)
        #expect(abs(abs(o1 - o0) - Tunables().carrySpeed * H.dt) < 1e-6)
    }
}
