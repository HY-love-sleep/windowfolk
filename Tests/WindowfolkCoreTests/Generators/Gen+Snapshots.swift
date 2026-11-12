import PropertyBased
@testable import WindowfolkCore

// Eligible_Window 快照列表的共享生成器（design.md「生成器」表中的 `Gen.windowLayout`）。
// 坐标对齐到 8pt 网格，并按一定比例让窗口复制、贴齐前面某个窗口的边，
// 以制造完全覆盖、上沿相等、上沿恰好等于前方窗口下边等边界情况。

/// 单个窗口的生成参数，由 `windowLayout` 组装为快照。
private struct WindowSpec: Sendable {
    var kind: Int      // 0 复制参照窗口；1 与参照窗口上沿相同；2 上沿等于参照窗口下边；3 左边贴参照窗口右边；其余随机
    var ref: Int       // 参照窗口（取前面已生成窗口中的一个）
    var x: Int         // 以 8pt 为单位
    var y: Int
    var w: Int
    var h: Int
}

private let grid = 8.0

extension Gen where Value == [WindowSnapshot] {
    /// 0 到 12 个窗口，约 1/20 的概率为 50 个。数组按从前到后排列，`zIndex` 等于数组下标，
    /// id 从 1 起连续编号，ownerName 为 `App<id>`。宽高都不小于 120pt。
    static var windowLayout: Generator<[WindowSnapshot], some SendableSequenceType> {
        let spec = zip(
            Gen<Int>.int(in: 0...9),
            Gen<Int>.int(in: 0...49),
            Gen<Int>.int(in: 0...200),   // minX 0 到 1600pt
            Gen<Int>.int(in: 0...110),   // minY 0 到 880pt
            Gen<Int>.int(in: 15...80),   // width 120 到 640pt
            Gen<Int>.int(in: 15...60)    // height 120 到 480pt
        ).map { WindowSpec(kind: $0, ref: $1, x: $2, y: $3, w: $4, h: $5) }

        return zip(
            Gen<Int>.int(in: 0...19),
            Gen<Int>.int(in: 0...12),
            spec.array(of: 50)
        ).map { pickLarge, smallCount, specs in
            let count = pickLarge == 0 ? 50 : smallCount
            var frames: [Rect] = []
            for (i, s) in specs.prefix(count).enumerated() {
                var r = Rect(
                    minX: Double(s.x) * grid, minY: Double(s.y) * grid,
                    width: Double(s.w) * grid, height: Double(s.h) * grid)
                if i > 0 {
                    let ref = frames[s.ref % i]
                    switch s.kind {
                    case 0: r = ref
                    case 1: r.minY = ref.minY
                    case 2: r.minY = ref.maxY
                    case 3: r.minX = ref.maxX
                    default: break
                    }
                }
                frames.append(r)
            }
            return frames.enumerated().map { i, frame in
                let id = WindowID(i + 1)
                return WindowSnapshot(
                    id: id, ownerName: "App\(id)", ownerPID: Int32(100 + i), frame: frame, zIndex: i)
            }
        }
    }
}
