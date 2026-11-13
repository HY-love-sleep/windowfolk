import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// Decor 松手判定的属性测试（design.md Property 6，任务 2.3）。
//
// 口径与 `DecorRules.release` 一致：Toolbox 收回距离按光标 `pointer` 计算；
// 吸附与下落按 Decor 底边中点 `pointer - grabOffset` 计算。

/// 一次松手的输入。
fileprivate struct DecorReleaseScenario: Sendable, CustomStringConvertible {
    var screen: ScreenInfo
    var windows: WindowTable
    /// 全部 Surface：窗沿（含隐藏窗口留下的旧窗沿，用来检验可见性过滤）、Ground、已架设木板。
    var surfaces: [Surface]
    var toolbox: Rect
    var pointer: Point
    var grabOffset: Point
    var fresh: Bool

    var description: String {
        "pointer \(pointer) grab \(grabOffset) fresh \(fresh) toolbox \(toolbox) "
            + "surfaces \(surfaces.map { "\($0.id) \($0.start)-\($0.end)" }) "
            + "hidden \(windows.records.filter { $0.value.visibility == .hidden }.keys.sorted())"
    }
}

/// 木板生成参数（8pt 网格）。
fileprivate struct PlankSpec: Sendable {
    var x: Int, length: Int, y: Int, slope: Int
}

fileprivate let grid = 8.0

extension Gen where Value == DecorReleaseScenario {
    /// 网格对齐的窗口布局、随机隐藏部分窗口、0 到 4 块木板（可倾斜）。
    /// 约 3/4 的样本把底边中点放在某条窗沿或木板正上方 -8 到 32pt 处，以覆盖吸附边界和并列；
    /// 约 1/3 的样本把 Toolbox 放在光标附近，以覆盖收回边界。
    fileprivate static var decorRelease: Generator<DecorReleaseScenario, some SendableSequenceType> {
        let plank = zip(
            Gen<Int>.int(in: 0...200),   // 左端 x
            Gen<Int>.int(in: 1...40),    // 水平长度
            Gen<Int>.int(in: 4...110),   // 左端 y
            Gen<Int>.int(in: -3...3)     // 右端相对左端的 y 差
        ).map { PlankSpec(x: $0, length: $1, y: $2, slope: $3) }

        let layout = zip(
            Gen<[WindowSnapshot]>.windowLayout,
            Gen<Int>.int(in: 0...3).array(of: 50),  // 0 表示该窗口隐藏
            plank.array(of: 0...4),
            Gen<ScreenInfo>.screen
        )
        let pointer = zip(
            Gen<Int>.int(in: 0...3),       // 0 自由位置，其余锚定到某条 Surface
            Gen<Int>.int(in: 0...63),      // 锚定 Surface 下标
            Gen<Int>.int(in: 0...8),       // 在线段上的位置（0 到 8 份）
            Gen<Int>.int(in: -2...8),      // 底边离 Surface 的高度（4pt 一份），6 份恰为 Drop_Snap_Distance
            Gen<Int>.int(in: -10...400),   // 自由 x（4pt 一份）
            Gen<Int>.int(in: -10...250)    // 自由 y（4pt 一份）
        )
        let rest = zip(
            Gen<Int>.int(in: -8...8),      // grabOffset.x（4pt 一份）
            Gen<Int>.int(in: -12...0),     // grabOffset.y（4pt 一份，光标在底边上方）
            Gen<Int>.int(in: 0...2),       // 0 Toolbox 在光标附近
            Gen<Int>.int(in: -14...14),    // 附近时的偏移（4pt 一份）
            Gen<Int>.int(in: 0...180),     // 随机 Toolbox x
            Gen<Int>.int(in: 0...110),     // 随机 Toolbox y
            Gen<Bool>.bool
        )

        return zip(layout, pointer, rest).map { layout, pointer, rest in
            let (snaps, hiddenMask, plankSpecs, screen) = layout
            let (mode, anchor, frac, lift, fx, fy) = pointer
            let (gx, gy, boxMode, boxShift, bx, by, fresh) = rest

            var records: [WindowID: WindowRecord] = [:]
            for (i, s) in snaps.enumerated() {
                records[s.id] = WindowRecord(snapshot: s, visibility: hiddenMask[i] == 0 ? .hidden : .visible)
            }
            var surfaces = SurfaceBuilder.build(windows: snaps, screen: screen)
            for (i, p) in plankSpecs.enumerated() {
                let start = Point(x: Double(p.x) * grid, y: Double(p.y) * grid)
                let end = Point(x: start.x + Double(p.length) * grid, y: start.y + Double(p.slope) * grid)
                surfaces.append(Surface(id: .plank(PlankID(UInt64(i + 1))), start: start, end: end))
            }

            let grab = Point(x: Double(gx) * 4, y: Double(gy) * 4)
            let candidates = surfaces.filter { $0.id != .ground }
            var bottom = Point(x: Double(fx) * 4, y: Double(fy) * 4)
            if mode != 0, !candidates.isEmpty {
                let s = candidates[anchor % candidates.count]
                let x = s.start.x + (s.end.x - s.start.x) * Double(frac) / 8
                bottom = Point(x: x, y: s.y(atX: x) - Double(lift) * 4)
            }
            let p = Point(x: bottom.x + grab.x, y: bottom.y + grab.y)

            let size = (w: 72.0, h: 52.0)
            let toolbox = boxMode == 0
                ? Rect(minX: p.x + Double(boxShift) * 4 - size.w / 2, minY: p.y + Double(boxShift) * 2 - size.h / 2,
                       width: size.w, height: size.h)
                : Rect(minX: Double(bx) * grid, minY: Double(by) * grid, width: size.w, height: size.h)

            return DecorReleaseScenario(
                screen: screen, windows: WindowTable(records: records), surfaces: surfaces,
                toolbox: toolbox, pointer: p, grabOffset: grab, fresh: fresh
            )
        }
    }
}

struct DecorRulesTests {
    /// 参考实现：点到矩形的欧氏距离。
    static func distance(_ p: Point, to r: Rect) -> Double {
        let cx = min(max(p.x, r.minX), r.maxX)
        let cy = min(max(p.y, r.minY), r.maxY)
        return hypot(p.x - cx, p.y - cy)
    }

    /// 参考实现：x 处正下方 [0, Drop_Snap_Distance] 内的可吸附 Surface（可见窗口的窗沿和木板），
    /// 按（竖直距离、y、SurfaceID）取最小。
    static func snapTarget(x: Double, bottomY: Double, surfaces: [Surface], windows: WindowTable,
                           snap: Double) -> Surface? {
        let eps = 1e-9
        return surfaces
            .filter { s in
                switch s.id {
                case .ground: return false
                case let .ledge(wid, _): return windows.visibleSnapshot(wid) != nil
                case .plank: return true
                }
            }
            .filter { $0.start.x - eps <= x && x <= $0.end.x + eps }
            .map { s in (s, s.y(atX: x) - bottomY, s.y(atX: x)) }
            .filter { $0.1 >= -eps && $0.1 <= snap + eps }
            .min { ($0.1, $0.2, $0.0.id) < ($1.1, $1.2, $1.0.id) }?
            .0
    }

    // Feature: V2, Property 6: Decor 松手判定
    // **Validates: Requirements 3.2, 3.3, 3.4, 3.5**
    @Test func decorReleaseMatchesReference() async {
        let k = Tunables()
        await propertyCheck(count: 200, input: Gen<DecorReleaseScenario>.decorRelease) { sc in
            let result = DecorRules.release(
                at: sc.pointer, grabOffset: sc.grabOffset, fresh: sc.fresh,
                toolbox: sc.toolbox, surfaces: sc.surfaces, windows: sc.windows,
                screen: sc.screen, constants: k
            )

            // Toolbox 收回优先于吸附（Requirement 3.4、3.5）。
            if Self.distance(sc.pointer, to: sc.toolbox) <= k.toolboxReturnDistance {
                #expect(result == (sc.fresh ? .discard : .remove), "\(sc)")
                return
            }

            let bottom = Point(x: sc.pointer.x - sc.grabOffset.x, y: sc.pointer.y - sc.grabOffset.y)
            let x = Physics.clampX(bottom.x, screen: sc.screen)

            guard let target = Self.snapTarget(x: x, bottomY: bottom.y, surfaces: sc.surfaces,
                                               windows: sc.windows, snap: k.dropSnapDistance) else {
                // 没有可吸附的 Surface：从松开点（底边中点）开始下落（Requirement 3.3）。
                #expect(result == .fall(FallState(position: Point(x: x, y: bottom.y), velocityY: 0)), "\(sc)")
                return
            }

            // 吸附（Requirement 3.2）：水平中心夹紧到线段，底边落在 Surface 上。
            let cx = min(max(x, target.start.x), target.end.x)
            guard case let .attach(attachment, surface: tag) = result else {
                Issue.record("应附着到 \(target.id)，实际 \(result)；\(sc)")
                return
            }
            let placed: Point
            switch (target.id, attachment) {
            case let (.ledge(wid, _), .window(aid, offset)):
                #expect(aid == wid, "\(sc)")
                #expect(tag == .windowLedge)
                guard let snap = sc.windows.visibleSnapshot(wid) else {
                    Issue.record("附着到不可见窗口 \(wid)")
                    return
                }
                placed = Point(x: snap.frame.minX + offset, y: snap.frame.minY)
            case let (.plank(pid), .plank(aid, t)):
                #expect(aid == pid, "\(sc)")
                #expect(tag == .plank)
                #expect((0...1).contains(t))
                placed = Point(x: target.start.x + (target.end.x - target.start.x) * t,
                               y: target.start.y + (target.end.y - target.start.y) * t)
            default:
                Issue.record("应附着到 \(target.id)，实际 \(attachment)；\(sc)")
                return
            }
            #expect(abs(placed.x - cx) <= 1e-6, "水平中心 \(placed.x) != \(cx)；\(sc)")
            #expect(target.start.x - 1e-6 <= placed.x && placed.x <= target.end.x + 1e-6)
            #expect(abs(placed.y - target.y(atX: placed.x)) <= 1, "底边离 Surface 超过 1pt；\(sc)")
        }
    }
}
