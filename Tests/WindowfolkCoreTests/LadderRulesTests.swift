import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 梯子吸附与判定的属性测试（Property 19）。
/// tasks.md 建议放在 InteractionTests.swift，为避免与其他任务并行修改同一文件，单独成文件。
struct LadderRulesTests {
    // MARK: - 参考实现（与 LadderRules 独立编写）

    /// 上端：离指针直线距离最近的 Window_Ledge，x 为指针 x 夹紧到窗沿两端；并列取 SurfaceID 较小者。
    static func referenceTop(_ p: Point, surfaces: [Surface]) -> (Point, SurfaceID)? {
        surfaces
            .filter { $0.id.isLedge }
            .map { s -> (Point, SurfaceID, Double) in
                let q = Point(x: min(max(p.x, s.start.x), s.end.x), y: s.start.y)
                return (q, s.id, hypot(p.x - q.x, p.y - q.y))
            }
            .min { ($0.2, $0.1) < ($1.2, $1.1) }
            .map { ($0.0, $0.1) }
    }

    /// 下端：上端正下方（y 严格更大）第一条水平范围包含 x 的 Ground 或 Window_Ledge；并列取 SurfaceID 较小者。
    static func referenceBottom(_ top: Point, surfaces: [Surface]) -> (Point, SurfaceID)? {
        surfaces
            .filter { s in
                let groundOrLedge = s.id == .ground || s.id.isLedge
                return groundOrLedge && s.start.x <= top.x && top.x <= s.end.x && s.start.y > top.y
            }
            .min { ($0.start.y, $0.id) < ($1.start.y, $1.id) }
            .map { (Point(x: top.x, y: $0.start.y), $0.id) }
    }

    /// 有效当且仅当上端存在、下端存在且竖直距离在 (0, Ladder_Length]（边界含等号）。
    static func referenceValid(top: Point?, bottom: Point?, constants k: Tunables) -> Bool {
        guard let top, let bottom else { return false }
        let d = bottom.y - top.y
        return d > 0 && d <= k.ladderLength
    }

    /// mode 1：把一个窗口上沿移到 Ground 上方 Ladder_Length ± 8pt 处，制造长度边界。
    static func shiftToBoundary(_ layout: inout [WindowSnapshot], _ i: Int, screen: ScreenInfo, delta: Int) {
        layout[i].frame.minY = screen.groundY - Tunables().ladderLength + Double(delta) * 8
    }

    // Feature: v1, Property 19: 梯子吸附与判定（拖动预览部分）
    // **Validates: Requirements 10.1, 10.2, 10.3, 10.4**
    @Test func ladderPreviewMatchesReference() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen.screen,
            zip(
                Gen<Int>.int(in: -25...475),  // 指针 x（4pt 单位）
                Gen<Int>.int(in: -25...250),  // 指针 y（4pt 单位）
                Gen<Int>.int(in: 0...49),     // 边界构造的目标窗口
                Gen<Int>.int(in: -1...1),     // 边界偏移（8pt 单位）
                Gen<Int>.int(in: 0...2)       // 1：构造长度边界；其他：原样
            )
        ) { layout, screen, params in
            let (px, py, wi, delta, mode) = params
            var layout = layout
            if mode == 1, !layout.isEmpty {
                Self.shiftToBoundary(&layout, wi % layout.count, screen: screen, delta: delta)
            }
            let pointer = Point(x: Double(px) * 4, y: Double(py) * 4)
            let surfaces = SurfaceBuilder.build(windows: layout, screen: screen)
            let k = Tunables()

            let refTop = Self.referenceTop(pointer, surfaces: surfaces)
            let snapped = LadderRules.snapTop(pointer: pointer, ledges: surfaces)
            #expect(snapped?.0 == refTop?.0 && snapped?.1 == refTop?.1,
                    "snapTop \(String(describing: snapped)) != 参考 \(String(describing: refTop))，pointer \(pointer)")

            let preview = LadderRules.preview(pointer: pointer, surfaces: surfaces, constants: k)
            guard let refTop else {
                // 没有任何 Window_Ledge：不吸附，红色（Requirement 10.4）
                #expect(preview.top == nil && preview.bottom == nil)
                #expect(!preview.validity.isValid)
                return
            }
            #expect(preview.top?.0 == refTop.0 && preview.top?.1 == refTop.1)

            let refBottom = Self.referenceBottom(refTop.0, surfaces: surfaces)
            let bottom = LadderRules.bottom(below: refTop.0, surfaces: surfaces)
            #expect(bottom?.0 == refBottom?.0 && bottom?.1 == refBottom?.1,
                    "bottom \(String(describing: bottom)) != 参考 \(String(describing: refBottom))，top \(refTop.0)")
            #expect(preview.bottom?.0 == refBottom?.0 && preview.bottom?.1 == refBottom?.1)

            let expected = Self.referenceValid(top: refTop.0, bottom: refBottom?.0, constants: k)
            #expect(preview.validity.isValid == expected,
                    "预览 \(preview.validity) 与参考 \(expected) 不一致：top \(refTop.0) bottom \(String(describing: refBottom))")
        }
    }

    // Feature: v1, Property 19: 梯子吸附与判定（架设后的下端重算与失效检测部分）
    // **Validates: Requirements 10.7, 10.8**
    @Test func placedLadderTracksReferenceUnderWindowOps() async {
        let op = zip(
            Gen<Int>.int(in: 0...7),
            Gen<Int>.int(in: 0...49),
            Gen<Int>.int(in: -25...25),
            Gen<Int>.int(in: -25...25)
        )
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen.screen,
            zip(
                Gen<Int>.int(in: 0...49),   // 上端窗口
                Gen<Int>.int(in: 0...80),   // 上端偏移（8pt 单位，可能在窗沿外）
                Gen<Int>.int(in: -1...1),
                Gen<Int>.int(in: 0...1)     // 1：初始放在长度边界
            ),
            op.array(of: 0...10)
        ) { layout, screen, params, ops in
            let (wi, offUnits, delta, mode) = params
            guard !layout.isEmpty else { return }
            var layout = layout
            let i = wi % layout.count
            if mode == 1 { Self.shiftToBoundary(&layout, i, screen: screen, delta: delta) }
            let k = Tunables()
            let topWindow = layout[i].id
            let offset = min(Double(offUnits) * 8, layout[i].frame.width)

            var source = FakeWindowSource(snapshots: layout)
            var table = WindowTable()
            table.apply(source.poll())
            let initialSurfaces = SurfaceBuilder.build(windows: table.visibleSnapshots, screen: screen)
            let initialTop = Point(x: layout[i].frame.minX + offset, y: layout[i].frame.minY)
            let initialBottom = Self.referenceBottom(initialTop, surfaces: initialSurfaces)
                ?? (Point(x: initialTop.x, y: screen.groundY), .ground)
            let ladder = PlacedLadder(
                id: LadderID(1), top: PlankEnd(window: topWindow, offset: offset),
                bottomSurface: initialBottom.1, bottom: initialBottom.0)

            func check(_ label: String) {
                let surfaces = SurfaceBuilder.build(windows: table.visibleSnapshots, screen: screen)
                let actual = LadderRules.validity(of: ladder, windows: table, surfaces: surfaces, constants: k)
                if table.isHidden(topWindow) {
                    #expect(actual == nil, "\(label)：上端窗口隐藏时应暂停校验，得到 \(String(describing: actual))")
                    return
                }
                guard let w = table.visibleSnapshot(topWindow) else {
                    // 上端窗口关闭
                    #expect(actual != nil && actual?.isValid == false,
                            "\(label)：上端窗口关闭后应失效，得到 \(String(describing: actual))")
                    return
                }
                let top = Point(x: w.frame.minX + offset, y: w.frame.minY)
                let onLedge = surfaces.contains { s in
                    s.id.windowID == topWindow && s.start.y == top.y
                        && s.start.x <= top.x && top.x <= s.end.x
                }
                let refBottom = Self.referenceBottom(top, surfaces: surfaces)
                // 下端始终按当前上端重新计算（Requirement 10.7）
                let refreshed = LadderRules.refreshed(ladder, windows: table, surfaces: surfaces)
                #expect(refreshed?.bottom == refBottom?.0 && refreshed?.bottomSurface == refBottom?.1,
                        "\(label)：refreshed 下端 \(String(describing: refreshed?.bottom)) != 参考 \(String(describing: refBottom))")
                let expected = onLedge && Self.referenceValid(top: top, bottom: refBottom?.0, constants: k)
                #expect(actual?.isValid == expected,
                        "\(label)：validity(of:) = \(String(describing: actual))，参考 = \(expected)，top \(top) bottom \(String(describing: refBottom))")
            }

            check("初始")
            for (n, (kind, target, p, q)) in ops.enumerated() {
                let ids = source.windows.map(\.snapshot.id)
                guard !ids.isEmpty else { break }
                // 约一半操作作用在上端窗口上
                let id = target % 2 == 0 ? topWindow : ids[(target / 2) % ids.count]
                let other = ids[(target / 3) % ids.count]
                switch kind {
                case 0:
                    if let f = source.window(id)?.snapshot.frame {
                        source.move(id, to: Point(x: f.minX + Double(p) * 8, y: f.minY + Double(q) * 8))
                    }
                case 1: source.resize(id, to: (Double(abs(p) + 15) * 8, Double(abs(q) + 15) * 8))
                case 2: source.bringToFront(id)
                case 3: source.sendBehind(id, other)
                case 4: source.hide(id)
                case 5: source.show(id)
                case 6: source.close(id)
                default: // 把窗口上沿移到 Ground 上方 Ladder_Length 附近
                    if let f = source.window(id)?.snapshot.frame {
                        source.move(id, to: Point(
                            x: f.minX, y: screen.groundY - k.ladderLength + Double(q % 2) * 8))
                    }
                }
                table.apply(source.poll())
                check("第 \(n + 1) 次操作（kind \(kind)，窗口 \(id)）后")
            }
        }
    }

    /// Ladder_Length 边界：恰好等于上限有效，超出无效；距离为 0 或没有下端无效。
    @Test func ladderValidityBoundary() {
        let k = Tunables()
        let top = Point(x: 100, y: 300)
        #expect(LadderRules.validity(top: top, bottom: Point(x: 100, y: 300 + k.ladderLength), constants: k) == .valid)
        #expect(LadderRules.validity(top: top, bottom: Point(x: 100, y: 300 + k.ladderLength + 0.5), constants: k) == .tooLong)
        #expect(!LadderRules.validity(top: top, bottom: top, constants: k).isValid)
        #expect(LadderRules.validity(top: top, bottom: nil, constants: k) == .noBottom)
        #expect(LadderRules.validity(top: nil, bottom: nil, constants: k) == .missingLedge)
    }
}
