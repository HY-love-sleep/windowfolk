import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

struct PlankRulesTests {
    /// 参考实现：窗沿上离指针最近的点和距离（窗沿是水平线段）。
    static func closest(_ p: Point, on s: Surface) -> (point: Point, distance: Double) {
        let q = Point(x: min(max(p.x, s.start.x), s.end.x), y: s.start.y)
        return (q, hypot(p.x - q.x, p.y - q.y))
    }

    /// 参考实现：在给定窗沿中取距离最小者；并列时取 `SurfaceID` 最小的一条。
    static func referenceNearest(_ p: Point, in ledges: [Surface]) -> (surface: Surface, point: Point, distance: Double)? {
        ledges
            .map { s -> (surface: Surface, point: Point, distance: Double) in
                let c = closest(p, on: s)
                return (s, c.point, c.distance)
            }
            .min { ($0.distance, $0.surface.id) < ($1.distance, $1.surface.id) }
    }

    // Feature: v1, Property 16: 木板吸附
    // **Validates: Requirements 8.7, 9.1, 9.2**
    @Test func plankSnapPicksNearestLedgesOfTwoWindows() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen.screen,
            // 指针对齐 4pt 网格，覆盖屏幕外区域，便于制造与窗沿等距的并列情况
            Gen<Int>.int(in: -25...475),
            Gen<Int>.int(in: -25...250)
        ) { windows, screen, px, py in
            let pointer = Point(x: Double(px) * 4, y: Double(py) * 4)
            // 输入包含 Ground，snap 只应考虑 Window_Ledge
            let surfaces = SurfaceBuilder.build(windows: windows, screen: screen)
            let ledges = surfaces.filter { $0.id.isLedge }
            let windowsWithLedges = Set(ledges.compactMap { $0.id.windowID })

            let snap = PlankRules.snap(pointer: pointer, ledges: surfaces)

            // 有窗沿的窗口少于两个时不吸附（Requirement 9.2）
            guard windowsWithLedges.count >= 2 else {
                #expect(snap == nil, "只有 \(windowsWithLedges.count) 个窗口有窗沿时仍吸附")
                return
            }
            guard let snap else {
                Issue.record("\(windowsWithLedges.count) 个窗口有窗沿但 snap 返回 nil，pointer \(pointer)")
                return
            }

            // 第一端：所有窗沿中离指针最近的点（Requirement 9.1）
            guard let refA = Self.referenceNearest(pointer, in: ledges),
                  let refWindowA = refA.surface.id.windowID else {
                Issue.record("参考实现找不到第一端")
                return
            }
            #expect(snap.windowA == refWindowA, "windowA \(snap.windowA) != \(refWindowA)")
            #expect(snap.endA == refA.point, "endA \(snap.endA) != \(refA.point)")

            // 第二端：其他窗口的窗沿中离指针最近的点
            let others = ledges.filter { $0.id.windowID != refWindowA }
            guard let refB = Self.referenceNearest(pointer, in: others),
                  let refWindowB = refB.surface.id.windowID else {
                Issue.record("参考实现找不到第二端")
                return
            }
            #expect(snap.windowB == refWindowB, "windowB \(snap.windowB) != \(refWindowB)")
            #expect(snap.endB == refB.point, "endB \(snap.endB) != \(refB.point)")

            // 两端属于不同窗口，且各自落在所属窗口的某条窗沿上
            #expect(snap.windowA != snap.windowB)
            for (end, window) in [(snap.endA, snap.windowA), (snap.endB, snap.windowB)] {
                let onLedge = ledges.contains { s in
                    s.id.windowID == window && s.start.y == end.y
                        && s.start.x <= end.x && end.x <= s.end.x
                }
                #expect(onLedge, "端点 \(end) 不在窗口 \(window) 的窗沿上")
            }
        }
    }

    // MARK: - Property 17

    /// 参考谓词（Requirement 9.12）：两端位于两个不同窗口的现存 Window_Ledge 上，
    /// 水平距离 ≤ Plank_Max_Span，高差 ≤ Plank_Max_Rise（边界含等号）。
    /// 端点由 8pt 网格坐标构造，因此这里用精确比较。
    static func referenceValid(
        endA: Point, windowA: WindowID, endB: Point, windowB: WindowID,
        ledges: [Surface], constants k: Tunables
    ) -> Bool {
        func onLedge(_ p: Point, _ w: WindowID) -> Bool {
            ledges.contains { s in
                s.id.isLedge && s.id.windowID == w && s.start.y == p.y
                    && s.start.x <= p.x && p.x <= s.end.x
            }
        }
        return windowA != windowB
            && onLedge(endA, windowA) && onLedge(endB, windowB)
            && abs(endA.x - endB.x) <= k.plankMaxSpan
            && abs(endA.y - endB.y) <= k.plankMaxRise
    }

    /// 让 `layout[j]` 的上沿比 `layout[i]` 低 `riseUnits * 8` pt，用来制造恰好等于 Plank_Max_Rise 的高差。
    static func alignTop(_ layout: inout [WindowSnapshot], _ j: Int, to i: Int, riseUnits: Int) {
        layout[j].frame.minY = layout[i].frame.minY + Double(riseUnits) * 8
    }

    // Feature: v1, Property 17: 木板统一判定（端点判定部分）
    // **Validates: Requirements 9.3, 9.4, 9.12**
    @Test func plankValidityMatchesReferencePredicate() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            zip(
                Gen<Int>.int(in: 0...49),    // 第一端窗口
                Gen<Int>.int(in: 0...49),    // 第二端窗口（可能与第一端相同）
                Gen<Int>.int(in: -2...82),   // 第一端相对窗口左边缘的偏移（8pt 单位，含窗沿外）
                Gen<Int>.int(in: -22...22),  // 第二端相对第一端的水平距离（8pt 单位，±20 即 ±160pt）
                Gen<Int>.int(in: -6...6),    // 对齐时的高差（8pt 单位，±5 即 ±40pt）
                Gen<Int>.int(in: 0...3)      // 0：对齐上沿制造高差边界；3：第一端 y 偏离窗沿 8pt
            )
        ) { layout, params in
            let (ia, ib, xUnits, dxUnits, riseUnits, mode) = params
            guard !layout.isEmpty else { return }
            var layout = layout
            let i = ia % layout.count, j = ib % layout.count
            if mode == 0, i != j { Self.alignTop(&layout, j, to: i, riseUnits: riseUnits) }
            let wA = layout[i], wB = layout[j]
            let ledges = SurfaceBuilder.ledges(for: layout)
            let k = Tunables()

            let endA = Point(
                x: wA.frame.minX + Double(xUnits) * 8,
                y: wA.frame.minY + (mode == 3 ? 8 : 0))
            let endB = Point(x: endA.x + Double(dxUnits) * 8, y: wB.frame.minY)

            let actual = PlankRules.validity(
                endA: endA, windowA: wA.id, endB: endB, windowB: wB.id, ledges: ledges, constants: k)
            let expected = Self.referenceValid(
                endA: endA, windowA: wA.id, endB: endB, windowB: wB.id, ledges: ledges, constants: k)
            #expect(actual.isValid == expected,
                    "validity \(actual) 与参考谓词 \(expected) 不一致：A \(endA)@\(wA.id) B \(endB)@\(wB.id)")
            if wA.id == wB.id { #expect(actual == .sameWindow) }
            // 交换两端不影响判定
            let swapped = PlankRules.validity(
                endA: endB, windowA: wB.id, endB: endA, windowB: wA.id, ledges: ledges, constants: k)
            #expect(swapped.isValid == actual.isValid)
        }
    }

    // Feature: v1, Property 17: 木板统一判定（架设后的失效检测部分）
    // **Validates: Requirements 9.9, 9.12**
    @Test func placedPlankValidityTracksReferenceUnderWindowOps() async {
        // 窗口操作：种类、目标选择、两个参数
        let op = zip(
            Gen<Int>.int(in: 0...7),
            Gen<Int>.int(in: 0...49),
            Gen<Int>.int(in: -25...25),
            Gen<Int>.int(in: -25...25)
        )
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            zip(
                Gen<Int>.int(in: 0...49),
                Gen<Int>.int(in: 0...48),
                Gen<Int>.int(in: 0...82),
                Gen<Int>.int(in: -22...22),
                Gen<Int>.int(in: -6...6),
                Gen<Int>.int(in: 0...2)
            ),
            op.array(of: 0...10)
        ) { layout, params, ops in
            let (ia, ib, xUnits, dxUnits, riseUnits, mode) = params
            guard layout.count >= 2 else { return }
            var layout = layout
            let i = ia % layout.count
            let j = (i + 1 + ib % (layout.count - 1)) % layout.count
            if mode == 0 { Self.alignTop(&layout, j, to: i, riseUnits: riseUnits) }
            let k = Tunables()

            // 端点在架设时按两端窗口算出，之后只保存窗口 ID 和偏移
            let wA = layout[i], wB = layout[j]
            let offsetA = Double(xUnits) * 8
            let offsetB = wA.frame.minX + offsetA + Double(dxUnits) * 8 - wB.frame.minX
            let plank = PlacedPlank(
                id: PlankID(1),
                endA: PlankEnd(window: wA.id, offset: offsetA),
                endB: PlankEnd(window: wB.id, offset: offsetB))

            var source = FakeWindowSource(snapshots: layout)
            var table = WindowTable()

            func check(_ label: String) {
                let ledges = SurfaceBuilder.ledges(for: table.visibleSnapshots)
                let actual = PlankRules.validity(of: plank, windows: table, ledges: ledges, constants: k)
                if table.isHidden(plank.endA.window) || table.isHidden(plank.endB.window) {
                    #expect(actual == nil, "\(label)：端点窗口隐藏时应暂停校验，得到 \(String(describing: actual))")
                    return
                }
                // 关闭的窗口没有现存窗沿，参考谓词为假
                var expected = false
                if let a = table.visibleSnapshot(plank.endA.window),
                   let b = table.visibleSnapshot(plank.endB.window) {
                    expected = Self.referenceValid(
                        endA: Point(x: a.frame.minX + plank.endA.offset, y: a.frame.minY),
                        windowA: a.id,
                        endB: Point(x: b.frame.minX + plank.endB.offset, y: b.frame.minY),
                        windowB: b.id, ledges: ledges, constants: k)
                }
                #expect(actual?.isValid == expected,
                        "\(label)：validity(of:) = \(String(describing: actual))，参考谓词 = \(expected)")
            }

            table.apply(source.poll())
            check("初始")

            for (n, (kind, target, p, q)) in ops.enumerated() {
                let ids = source.windows.map(\.snapshot.id)
                guard !ids.isEmpty else { break }
                // 约 2/3 的操作作用在木板两端的窗口上
                let id: WindowID = switch target % 3 {
                case 0: plank.endA.window
                case 1: plank.endB.window
                default: ids[target % ids.count]
                }
                let other = ids[(target / 3) % ids.count]
                switch kind {
                case 0: // 平移
                    if let w = source.window(id)?.snapshot.frame {
                        source.move(id, to: Point(x: w.minX + Double(p) * 8, y: w.minY + Double(q) * 8))
                    }
                case 1: // 缩放
                    source.resize(id, to: (Double(abs(p) + 15) * 8, Double(abs(q) + 15) * 8))
                case 2: source.bringToFront(id)
                case 3: source.sendBehind(id, other)
                case 4: source.hide(id)
                case 5: source.show(id)
                case 6: source.close(id)
                default: // 让一端窗口上沿与另一端窗口对齐，制造高差边界
                    let peer = id == plank.endA.window ? plank.endB.window : plank.endA.window
                    if let me = source.window(id)?.snapshot.frame,
                       let ref = source.window(peer)?.snapshot.frame {
                        source.move(id, to: Point(x: me.minX + Double(p) * 8,
                                                  y: ref.minY + Double(q % 7) * 8))
                    }
                }
                table.apply(source.poll())
                check("第 \(n + 1) 次操作（kind \(kind)，窗口 \(id)）后")
            }
        }
    }

    /// Plank_Max_Span 与 Plank_Max_Rise 边界：恰好等于上限有效，超出一点无效。
    @Test func plankValidityBoundaryIsInclusive() {
        let k = Tunables()
        func win(_ id: WindowID, z: Int, x: Double, y: Double) -> WindowSnapshot {
            WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                           frame: Rect(minX: x, minY: y, width: 400, height: 300), zIndex: z)
        }
        func v(rise: Double, span: Double) -> PlankValidity {
            // 左端点在左窗口左上角，右端点在右窗口左上角；右窗口在前，左窗口左上角不被遮挡
            let left = win(1, z: 1, x: 0, y: 300)
            let right = win(2, z: 0, x: span, y: 300 + rise)
            let ledges = SurfaceBuilder.ledges(for: [left, right])
            return PlankRules.validity(
                endA: Point(x: 0, y: 300), windowA: 1,
                endB: Point(x: span, y: 300 + rise), windowB: 2, ledges: ledges, constants: k)
        }
        #expect(v(rise: k.plankMaxRise, span: k.plankMaxSpan) == .valid)
        #expect(v(rise: -k.plankMaxRise, span: k.plankMaxSpan) == .valid)
        #expect(v(rise: 0, span: k.plankMaxSpan.nextUp) == .tooFar)
        #expect(v(rise: k.plankMaxRise + 0.5, span: 100) == .tooSteep)
    }
}
