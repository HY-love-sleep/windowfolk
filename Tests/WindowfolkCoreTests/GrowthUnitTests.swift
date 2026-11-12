import Foundation
import Testing
@testable import WindowfolkCore

@Suite("Growth 单元测试")
struct GrowthUnitTests {
    let b = Tunables().bloomDuration
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("阶段边界：0.5B 为 sprout，B 为 bloom，负时长为 pot")
    func stageBoundaries() {
        #expect(Growth.stage(elapsed: -10, bloomDuration: b) == .pot)
        #expect(Growth.stage(elapsed: 0, bloomDuration: b) == .pot)
        #expect(Growth.stage(elapsed: b * 0.5 - 0.001, bloomDuration: b) == .pot)
        #expect(Growth.stage(elapsed: b * 0.5, bloomDuration: b) == .sprout)
        #expect(Growth.stage(elapsed: b - 0.001, bloomDuration: b) == .sprout)
        #expect(Growth.stage(elapsed: b, bloomDuration: b) == .bloom)
        #expect(Growth.stage(elapsed: b * 10, bloomDuration: b) == .bloom)
    }

    @Test("advance 报告新阶段，时钟回拨不倒退")
    func advanceMonotonic() {
        var g = FlowerGrowth(plantedAt: t0)
        #expect(Growth.advance(&g, now: t0.addingTimeInterval(1), bloomDuration: b) == nil)
        #expect(Growth.advance(&g, now: t0.addingTimeInterval(b * 0.5), bloomDuration: b) == .sprout)
        #expect(Growth.advance(&g, now: t0.addingTimeInterval(b * 0.6), bloomDuration: b) == nil)
        #expect(Growth.advance(&g, now: t0.addingTimeInterval(-100), bloomDuration: b) == nil)
        #expect(g.reached == .sprout)
        #expect(Growth.advance(&g, now: t0.addingTimeInterval(b), bloomDuration: b) == .bloom)
        #expect(Growth.advance(&g, now: t0, bloomDuration: b) == nil)
        #expect(g.reached == .bloom)
    }

    @Test("还没种下的花不生长")
    func unplanted() {
        var g = FlowerGrowth()
        #expect(Growth.advance(&g, now: t0.addingTimeInterval(b * 5), bloomDuration: b) == nil)
        Growth.fastForward(&g, now: t0, bloomDuration: b)
        #expect(g == FlowerGrowth())
    }

    @Test("快进每次只前进一个阶段，并从该阶段起点继续计时")
    func fastForwardOneStage() {
        var g = FlowerGrowth(plantedAt: t0)
        let now = t0.addingTimeInterval(5)
        Growth.fastForward(&g, now: now, bloomDuration: b)
        #expect(g.reached == .sprout)
        #expect(now.timeIntervalSince(g.plantedAt!) == b * 0.5)
        Growth.fastForward(&g, now: now, bloomDuration: b)
        #expect(g.reached == .bloom)
        #expect(now.timeIntervalSince(g.plantedAt!) == b)
        let before = g
        Growth.fastForward(&g, now: now, bloomDuration: b)
        #expect(g == before)
    }

    @Test("时钟回拨后快进仍从已达阶段前进")
    func fastForwardAfterClockRollback() {
        var g = FlowerGrowth(plantedAt: t0, reached: .sprout)
        let now = t0.addingTimeInterval(-50)
        Growth.fastForward(&g, now: now, bloomDuration: b)
        #expect(g.reached == .bloom)
        #expect(now.timeIntervalSince(g.plantedAt!) == b)
    }
}
