import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 一组生长测试输入：Bloom_Duration、相对种下时间的时钟读数序列（可回拨、可早于种下时间）和存档中断点。
private struct GrowthCase: Sendable {
    var bloomDuration: Double
    var offsets: [Double]      // 每次读数 now - plantedAt
    var splitFraction: Double  // 在序列的哪个位置「保存再恢复」
}

private extension Gen where Value == GrowthCase {
    static var growthCase: Generator<GrowthCase, some SendableSequenceType> {
        zip(
            Gen<Double>.double(in: 1...600),
            Gen<Double>.double(in: -1...3).array(of: 1...30),
            Gen<Double>.double(in: 0...1)
        ).map { b, fractions, split in
            // 读数以 Bloom_Duration 为单位生成，覆盖种下之前、三个阶段和回拨
            GrowthCase(bloomDuration: b, offsets: fractions.map { $0 * b }, splitFraction: split)
        }
    }
}

struct GrowthTests {
    /// 整数秒的种下时间，保证 `.secondsSince1970` 编码往返精确。
    static let plantedAt = Date(timeIntervalSince1970: 1_792_500_000)

    /// 参考阶段（Requirement 17.1）：pot < 0.5B ≤ sprout < B ≤ bloom。
    static func referenceStage(_ elapsed: Double, _ b: Double) -> GrowthStage {
        if elapsed >= b { return .bloom }
        if elapsed >= 0.5 * b { return .sprout }
        return .pot
    }

    /// 依次推进，返回每次读数后的阶段。
    static func run(_ g: inout FlowerGrowth, offsets: some Sequence<Double>, b: Double) -> [GrowthStage] {
        offsets.map { off in
            Growth.advance(&g, now: plantedAt.addingTimeInterval(off), bloomDuration: b)
            return g.reached
        }
    }

    // Feature: v1, Property 30: 生长单调且只依赖时间
    // **Validates: Requirements 17.1, 17.3, 17.4, 22.10**
    @Test func growthMonotonicAndTimeOnly() async {
        await propertyCheck(count: 100, input: Gen.growthCase) { c in
            let b = c.bloomDuration

            // 1. 每次 advance 后阶段等于前缀读数参考阶段的最大值；只前进不回退；返回值恰好报告新进入的阶段
            var g = FlowerGrowth(plantedAt: Self.plantedAt, reached: .pot)
            var expected = GrowthStage.pot
            var stages: [GrowthStage] = []
            for off in c.offsets {
                let before = g.reached
                let entered = Growth.advance(&g, now: Self.plantedAt.addingTimeInterval(off), bloomDuration: b)
                expected = max(expected, Self.referenceStage(off, b))
                #expect(g.reached == expected)
                #expect(g.reached >= before)
                #expect(entered == (g.reached != before ? g.reached : nil))
                #expect(g.plantedAt == Self.plantedAt)
                stages.append(g.reached)
            }

            // 2. 还没种下的花不生长
            var unplanted = FlowerGrowth(plantedAt: nil, reached: .pot)
            for off in c.offsets {
                #expect(Growth.advance(&unplanted, now: Self.plantedAt.addingTimeInterval(off), bloomDuration: b) == nil)
            }
            #expect(unplanted == FlowerGrowth(plantedAt: nil, reached: .pot))

            // 3. 与位置无关：同一读数序列下，放在窗沿、Ground、Plank、隐藏窗口上的花得到相同阶段序列
            let placements: [ItemPlacement] = [
                .attached(.window(WindowID(1), offset: 40)),
                .attached(.ground(x: 300)),
                .attached(.plank(PlankID(1), t: 0.5)),
                .attached(.window(WindowID(99), offset: 10)),  // 隐藏窗口上的附着方式与可见窗口相同
            ]
            for placement in placements {
                var item = Item(
                    kind: .flower(storyRound: 1), placement: placement,
                    growth: FlowerGrowth(plantedAt: Self.plantedAt, reached: .pot))
                var seq: [GrowthStage] = []
                for off in c.offsets {
                    Growth.advance(&item.growth!, now: Self.plantedAt.addingTimeInterval(off), bloomDuration: b)
                    seq.append(item.growth!.reached)
                }
                #expect(seq == stages)
            }

            // 4. 存档往返后按当前时间继续，结果与不中断运行相同（Requirement 22.10）
            let split = min(c.offsets.count, Int(c.splitFraction * Double(c.offsets.count + 1)))
            var first = FlowerGrowth(plantedAt: Self.plantedAt, reached: .pot)
            let head = Self.run(&first, offsets: c.offsets.prefix(split), b: b)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            var restored = try! decoder.decode(FlowerGrowth.self, from: encoder.encode(first))
            #expect(restored == first)
            let tail = Self.run(&restored, offsets: c.offsets.dropFirst(split), b: b)
            #expect(head + tail == stages)
        }
    }
}
