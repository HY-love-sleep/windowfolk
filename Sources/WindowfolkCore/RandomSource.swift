import Foundation

/// 可注入的确定性随机源（SplitMix64）。
///
/// 居民闲逛的停顿和转向都从这里取随机数。测试固定种子，应用用系统随机种子，
/// 同样的种子和输入总得到同样的世界状态。
public struct RandomSource: Hashable, Sendable, Codable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    /// 用系统随机数作种子（仅应用层使用）。
    public static func systemSeeded() -> RandomSource {
        RandomSource(seed: UInt64.random(in: .min ... .max))
    }

    /// 下一个 64 位随机数。
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1) 内均匀分布的 Double（取高 53 位）。
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// [lo, hi) 内均匀分布的 Double；`hi <= lo` 时返回 `lo`。
    public mutating func double(in lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return lo }
        return lo + (hi - lo) * nextUnit()
    }

    /// 等概率的布尔值。
    public mutating func bool() -> Bool {
        next() & 1 == 1
    }
}
