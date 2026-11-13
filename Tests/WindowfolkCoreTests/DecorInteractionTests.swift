import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 Decor 交互的属性测试。场景沿用 BridgeHangTests.Harness：屏幕 1440×900，Ground y = 825，
// Toolbox 位于右下角。

/// 指针相对按下点的位移：一半落在 ±6pt（0.5pt 网格，常落在 4pt 阈值附近并能恰好等于 4），
/// 一半落在 ±400pt 的大范围。
fileprivate var decorPointerOffsetGen: Generator<Point, some SendableSequenceType> {
    zip(Gen<Bool>.bool, Gen<Int>.int(in: -12...12), Gen<Int>.int(in: -12...12),
        Gen<Int>.int(in: -400...400), Gen<Int>.int(in: -400...400))
        .map { small, sx, sy, lx, ly in
            small ? Point(x: Double(sx) * 0.5, y: Double(sy) * 0.5) : Point(x: Double(lx), y: Double(ly))
        }
}

/// Property 4 的输入：已有 Decor 数量、拖出的 Decor_Type、另一种类型是否也解锁、按下点在 Decor_Slot 内的
/// 相对位置（0...1），以及按下后的指针轨迹（每帧一个相对按下点的位移，最后一个位置松开）。
fileprivate struct SlotDragCase: Sendable, CustomStringConvertible {
    var existing: Int
    var type: DecorType
    var unlockOther: Bool
    var pressU: Double
    var pressV: Double
    var offsets: [Point]

    var description: String {
        "existing=\(existing) type=\(type) unlockOther=\(unlockOther) press=(\(pressU), \(pressV)) offsets=\(offsets)"
    }
}

fileprivate var slotDragCaseGen: Generator<SlotDragCase, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...Tunables().maxDecorCount),
        Gen<Bool>.bool,
        Gen<Bool>.bool,
        Gen<Int>.int(in: 1...9),
        Gen<Int>.int(in: 1...9),
        decorPointerOffsetGen.array(of: 1...8)
    ).map { n, chair, other, u, v, offsets in
        SlotDragCase(existing: n, type: chair ? .chair : .lamp, unlockOther: other,
                     pressU: Double(u) / 10, pressV: Double(v) / 10, offsets: offsets)
    }
}

/// Property 5 的输入：Decor 所在 Surface（0 窗沿、1 木板、2 Ground）及其上的位置（0...1）、Decor_Type、
/// 按下点在 Decor 命中区域内的相对位置（0...1），以及按下后的指针轨迹（每帧一个相对按下点的位移，最后一个位置松开）。
fileprivate struct WorldDragCase: Sendable, CustomStringConvertible {
    var surface: Int
    var along: Double
    var type: DecorType
    var pressU: Double
    var pressV: Double
    var offsets: [Point]

    var description: String {
        "surface=\(surface) along=\(along) type=\(type) press=(\(pressU), \(pressV)) offsets=\(offsets)"
    }
}

fileprivate var worldDragCaseGen: Generator<WorldDragCase, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...2),
        Gen<Int>.int(in: 1...9),
        Gen<Bool>.bool,
        Gen<Int>.int(in: 1...9),
        Gen<Int>.int(in: 1...9),
        decorPointerOffsetGen.array(of: 1...8)
    ).map { s, a, chair, u, v, offsets in
        WorldDragCase(surface: s, along: Double(a) / 10, type: chair ? .chair : .lamp,
                      pressU: Double(u) / 10, pressV: Double(v) / 10, offsets: offsets)
    }
}

struct DecorInteractionTests {
    typealias H = BridgeHangTests.Harness

    /// 把点限制在屏幕内。
    static func clampToScreen(_ p: Point) -> Point {
        let f = BridgeHangTests.screen.frame
        return Point(x: min(max(p.x, f.minX), f.maxX - 1), y: min(max(p.y, f.minY), f.maxY - 1))
    }

    // Feature: V2, Property 4: Decor_Slot 拖出与上限
    // **Validates: Requirements 2.3, 2.4, 2.5, 2.6**
    @Test func decorSlotDragOutAndLimit() async {
        await propertyCheck(count: 100, input: slotDragCaseGen) { c in
            let k = Tunables()
            let h = H([])
            h.engine.unlockDecor(c.type)
            if c.unlockOther { h.engine.unlockDecor(c.type == .chair ? .lamp : .chair) }
            // 已有 Decor 都放在 Ground 左侧，远离右下角的 Toolbox。
            for i in 0 ..< c.existing {
                h.engine.insertDecor(Decor(id: DecorID(UInt64(i + 1)), type: i % 2 == 0 ? .chair : .lamp,
                                           placement: .attached(.ground(x: 100 + Double(i) * 30))))
            }
            var out = h.step()
            let before = Set(h.engine.state.decors.decors.keys)
            #expect(before.count == c.existing)

            let slot = ToolboxLayout.zoneFrame(.decor(c.type), screen: BridgeHangTests.screen,
                                               unlocked: h.engine.state.decors.unlocked)!
            let start = Point(x: slot.minX + slot.width * c.pressU, y: slot.minY + slot.height * c.pressV)
            #expect(HitTesting.hitTest(start, regions: out.view.hitRegions) == .toolbox(.decor(c.type)),
                    "按下点 \(start) 不在 Decor_Slot 内")

            let pointers = c.offsets.map { Self.clampToScreen(Point(x: start.x + $0.x, y: start.y + $0.y)) }
            let atLimit = c.existing >= k.maxDecorCount
            let grab = InteractionController.freshDecorGrabOffset(c.type)
            var exceeded = false
            var newID: DecorID?
            var shakeSeen = false
            var lastShakeRemaining = Double.infinity

            for (i, p) in pointers.enumerated() {
                let last = i == pointers.count - 1
                var events: [PointerEvent] = i == 0 ? [.down(start)] : []
                events.append(.moved(p))
                h.now = h.now.addingTimeInterval(BridgeHangTests.dt)
                out = h.engine.step(FrameInput(poll: h.source.poll(), screen: BridgeHangTests.screen,
                                               pointer: events, now: h.now))
                #expect(h.engine.invariantViolations().isEmpty, "\(h.engine.invariantViolations())")
                if hypot(p.x - start.x, p.y - start.y) > k.clickDragThreshold { exceeded = true }

                // Requirement 2.6：任意时刻数量（含拖动中的 Decor）不超过上限。
                let count = h.engine.state.decors.count
                #expect(count <= k.maxDecorCount)
                let created = Set(h.engine.state.decors.decors.keys).subtracting(before)

                if exceeded && !atLimit {
                    // Requirement 2.3：恰好新建 1 个该类型的 Decor，预览位置为指针减抓取偏移。
                    #expect(count == c.existing + 1)
                    #expect(created.count == 1)
                    if let id = created.first {
                        if let prev = newID { #expect(prev == id) }
                        newID = id
                        #expect(h.engine.state.decors.decors[id]?.type == c.type)
                        let v = out.view.decors.first { $0.id == id }
                        #expect(v?.isDragged == true)
                        #expect(v?.position == Point(x: p.x - grab.x, y: p.y - grab.y),
                                "第 \(i) 帧预览位置 \(String(describing: v?.position))，指针 \(p)")
                    }
                } else {
                    // Requirement 2.4、2.5：不新建、不预览、数量不变。
                    #expect(count == c.existing)
                    #expect(created.isEmpty)
                    #expect(!out.view.decors.contains { $0.isDragged })
                }

                // Requirement 2.4：只有达到上限并开始拖动时才晃动，设置一次，时长不超过 0.5 秒。
                if let shake = out.view.toolboxShake {
                    #expect(atLimit && exceeded, "未达上限或未拖动却晃动：\(shake)")
                    #expect(shake.zone == .decor(c.type))
                    #expect(shake.remaining > 0 && shake.remaining <= 0.5)
                    #expect(shake.remaining < lastShakeRemaining, "晃动被重新设置")
                    lastShakeRemaining = shake.remaining
                    shakeSeen = true
                } else if atLimit && exceeded {
                    #expect(shakeSeen, "达到上限开始拖动的那一帧没有晃动")
                }

                if last {
                    // 松开：只在这一帧发送 up，不再检查预览。
                    h.now = h.now.addingTimeInterval(BridgeHangTests.dt)
                    out = h.engine.step(FrameInput(poll: h.source.poll(), screen: BridgeHangTests.screen,
                                                   pointer: [.up(p)], now: h.now))
                    #expect(h.engine.invariantViolations().isEmpty, "\(h.engine.invariantViolations())")
                    #expect(h.engine.state.decors.count <= k.maxDecorCount)
                    if !(exceeded && !atLimit) {
                        #expect(h.engine.state.decors.count == c.existing)
                        #expect(!out.view.decors.contains { $0.isDragged })
                    }
                }
            }
            if atLimit && exceeded { #expect(shakeSeen) }
            if !exceeded || !atLimit { #expect(!shakeSeen) }
        }
    }
    // Feature: V2, Property 5: Decor 拖动跟随与点击不变
    // **Validates: Requirements 3.1, 3.6**
    @Test func decorDragFollowAndClickInvariant() async {
        await propertyCheck(count: 100, input: worldDragCaseGen) { c in
            let k = Tunables()
            // 两个窗口（上沿 y = 300）之间架一块木板（x 400 → 500）。
            let (h, pid) = BridgeHangTests.bridgeScene()
            let placement0: DecorPlacement
            switch c.surface {
            case 0: placement0 = .attached(.window(1, offset: 300 * c.along))
            case 1: placement0 = .attached(.plank(pid, t: c.along))
            default: placement0 = .attached(.ground(x: 100 + 1000 * c.along))
            }
            let id = DecorID(1)
            h.engine.insertDecor(Decor(id: id, type: c.type, placement: placement0))
            h.step()
            var out = h.step()
            let placementBefore = h.engine.state.decors.decors[id]?.placement
            #expect(placementBefore == placement0)
            guard let posBefore = out.view.decors.first(where: { $0.id == id })?.position,
                  let rect = out.view.hitRegions.first(where: { $0.target == .decor(id) })?.rect
            else {
                Issue.record("Decor 不在视图或命中区域中")
                return
            }
            let start = Point(x: rect.minX + rect.width * c.pressU, y: rect.minY + rect.height * c.pressV)
            #expect(HitTesting.hitTest(start, regions: out.view.hitRegions) == .decor(id),
                    "按下点 \(start) 不在 Decor 命中区域内")
            let expectedGrab = Point(x: start.x - posBefore.x, y: start.y - posBefore.y)

            let pointers = c.offsets.map { Self.clampToScreen(Point(x: start.x + $0.x, y: start.y + $0.y)) }
            var exceeded = false
            var events: [EventRecord] = []
            for (i, p) in pointers.enumerated() {
                var input: [PointerEvent] = i == 0 ? [.down(start)] : []
                input.append(.moved(p))
                h.now = h.now.addingTimeInterval(BridgeHangTests.dt)
                out = h.engine.step(FrameInput(poll: h.source.poll(), screen: BridgeHangTests.screen,
                                               pointer: input, now: h.now))
                #expect(h.engine.invariantViolations().isEmpty, "\(h.engine.invariantViolations())")
                events += out.events
                if hypot(p.x - start.x, p.y - start.y) > k.clickDragThreshold { exceeded = true }

                let placement = h.engine.state.decors.decors[id]?.placement
                if exceeded {
                    // Requirement 3.1、3.6：进入拖动，不附着任何 Surface，位置为指针减按下时的抓取偏移。
                    guard case let .dragged(grab, fresh)? = placement else {
                        Issue.record("第 \(i) 帧已超过阈值但 placement 为 \(String(describing: placement))")
                        continue
                    }
                    #expect(!fresh)
                    #expect(abs(grab.x - expectedGrab.x) <= 1e-9 && abs(grab.y - expectedGrab.y) <= 1e-9,
                            "抓取偏移 \(grab)，期望 \(expectedGrab)")
                    let v = out.view.decors.first { $0.id == id }
                    #expect(v?.isDragged == true)
                    #expect(v?.isFalling == false)
                    if let pos = v?.position {
                        #expect(abs(pos.x - (p.x - expectedGrab.x)) <= 1 && abs(pos.y - (p.y - expectedGrab.y)) <= 1,
                                "第 \(i) 帧位置 \(pos)，指针 \(p)")
                    } else {
                        Issue.record("第 \(i) 帧拖动中的 Decor 不在视图中")
                    }
                } else {
                    // 尚未超过阈值：保持原 placement。
                    #expect(placement == placementBefore, "第 \(i) 帧未超过阈值但 placement 变为 \(String(describing: placement))")
                }
            }

            // 松开。
            h.now = h.now.addingTimeInterval(BridgeHangTests.dt)
            out = h.engine.step(FrameInput(poll: h.source.poll(), screen: BridgeHangTests.screen,
                                           pointer: [.up(pointers.last!)], now: h.now))
            #expect(h.engine.invariantViolations().isEmpty, "\(h.engine.invariantViolations())")
            events += out.events
            if !exceeded {
                // Requirement 3.6：点击不改变位置和附着，也不写事件记录。
                #expect(h.engine.state.decors.decors[id]?.placement == placementBefore)
                #expect(out.view.decors.first { $0.id == id }?.position == posBefore)
                #expect(events.isEmpty, "点击产生了事件记录：\(events)")
            }
        }
    }
}
