import PropertyBased
import Testing
@testable import WindowfolkCore

struct SurfaceBuilderTests {
    /// 参考谓词：x 处的上沿是否被某个更靠前的窗口遮挡（按 Property 3 的文字直接写出）。
    static func referenceCovered(_ w: WindowSnapshot, x: Double, in windows: [WindowSnapshot]) -> Bool {
        let y = w.frame.minY
        return windows.contains { f in
            f.zIndex < w.zIndex
                && f.frame.minY <= y && y <= f.frame.maxY
                && f.frame.minX <= x && x <= f.frame.maxX
        }
    }

    /// 前方遮挡窗口的左右边。这些点处 Window_Ledge 端点与遮挡区间相接，按 0 宽度误差不做判定。
    static func cutEdges(for w: WindowSnapshot, in windows: [WindowSnapshot]) -> [Double] {
        let y = w.frame.minY
        return windows
            .filter { $0.zIndex < w.zIndex && $0.frame.minY <= y && y <= $0.frame.maxY }
            .flatMap { [$0.frame.minX, $0.frame.maxX] }
    }

    /// 上沿 x 区间内的采样点：区间端点、所有遮挡边，以及相邻两点的中点。
    /// 参考谓词在相邻两个临界点之间是常量，因此这些点覆盖了全部情形。
    static func samplePoints(for w: WindowSnapshot, cuts: [Double], randomFraction: Double) -> [Double] {
        let lo = w.frame.minX, hi = w.frame.maxX
        var critical = Set([lo, hi])
        for c in cuts where c >= lo && c <= hi { critical.insert(c) }
        let sorted = critical.sorted()
        var points = sorted
        for (a, b) in zip(sorted, sorted.dropFirst()) { points.append((a + b) / 2) }
        points.append(lo + (hi - lo) * randomFraction)
        return points
    }

    // Feature: v1, Property 3: 窗沿逐点刻画
    // **Validates: Requirements 3.1, 3.2, 3.4, 3.5, 3.8**
    @Test func ledgePointwiseCharacterization() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen<Double>.double(in: 0...1)
        ) { windows, fraction in
            let ledges = SurfaceBuilder.ledges(for: windows)

            // 空列表时没有任何 Window_Ledge（Requirement 3.8）
            if windows.isEmpty { #expect(ledges.isEmpty) }

            for w in windows {
                let own = ledges.filter { $0.id.windowID == w.id }
                let cuts = Self.cutEdges(for: w, in: windows)
                for x in Self.samplePoints(for: w, cuts: cuts, randomFraction: fraction) {
                    // 遮挡边上允许 0 宽度误差
                    if cuts.contains(where: { abs($0 - x) < 1e-9 }) { continue }
                    let inLedge = own.contains { $0.start.x <= x && x <= $0.end.x }
                    let covered = Self.referenceCovered(w, x: x, in: windows)
                    #expect(
                        inLedge == !covered,
                        "window \(w.id) frame \(w.frame) x=\(x): inLedge=\(inLedge) covered=\(covered)")
                }
            }
        }
    }

    // Feature: v1, Property 4: 路面结构不变量
    // **Validates: Requirements 3.6, 3.7, 3.9**
    @Test func surfaceStructuralInvariants() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen.screen
        ) { windows, screen in
            let surfaces = SurfaceBuilder.build(windows: windows, screen: screen)
            let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })

            // 恰好一条 Ground，y 为 visibleFrame 底边，x 范围为 visibleFrame 左右边界（Requirement 3.7）
            let grounds = surfaces.filter { $0.id == .ground }
            #expect(grounds.count == 1)
            if let g = grounds.first {
                #expect(g.start.y == screen.visibleFrame.maxY)
                #expect(g.end.y == screen.visibleFrame.maxY)
                #expect(g.start.x == screen.visibleFrame.minX)
                #expect(g.end.x == screen.visibleFrame.maxX)
            }

            let ledges = surfaces.filter { $0.id != .ground }
            for s in ledges {
                guard let wid = s.id.windowID, let w = byID[wid] else {
                    Issue.record("ledge \(s.id) 不属于任何输入窗口")
                    continue
                }
                // 长度 > 0，水平，y 等于所属窗口上边（Requirement 3.6）
                #expect(s.length > 0, "ledge \(s.id) length \(s.length)")
                #expect(s.start.y == w.frame.minY && s.end.y == w.frame.minY, "ledge \(s.id) y")
                // x 区间落在所属窗口 [minX, maxX] 内（Requirement 3.9）
                #expect(
                    s.start.x >= w.frame.minX && s.end.x <= w.frame.maxX,
                    "ledge \(s.id) [\(s.start.x), \(s.end.x)] outside \(w.frame)")
            }

            // 同一窗口各段两两交集长度为 0（Requirement 3.9）
            let grouped = Dictionary(grouping: ledges) { $0.id.windowID! }
            for (wid, segs) in grouped {
                for (i, a) in segs.enumerated() {
                    for b in segs.dropFirst(i + 1) {
                        let overlap = min(a.end.x, b.end.x) - max(a.start.x, b.start.x)
                        #expect(overlap <= 0, "window \(wid): \(a.id) 与 \(b.id) 重叠 \(overlap)")
                    }
                }
            }
        }
    }

    // Feature: v1, Property 5: 路面计算确定性
    // **Validates: Requirements 3.10**
    @Test func surfaceComputationIsDeterministic() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen.screen,
            Gen<Int>.int(in: 0...Int.max).array(of: 50)
        ) { windows, screen, sortKeys in
            let first = SurfaceBuilder.build(windows: windows, screen: screen)

            // 对同一输入重复计算，结果完全相同
            let second = SurfaceBuilder.build(windows: windows, screen: screen)
            #expect(first == second)

            // zIndex 不变、只打乱数组顺序：按随机键对下标排序得到一个排列
            let order = windows.indices.sorted { (sortKeys[$0], $0) < (sortKeys[$1], $1) }
            let shuffled = order.map { windows[$0] }
            let permuted = SurfaceBuilder.build(windows: shuffled, screen: screen)
            #expect(
                first == permuted,
                "order \(order.map { windows[$0].id }) 得到不同结果")
        }
    }
}
