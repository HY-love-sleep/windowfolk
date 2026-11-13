import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// 命中区域生成器：坐标对齐 8pt 网格，制造重叠、共边和点恰好落在边上的情况。
private func makeTarget(kind: Int, index: Int) -> HitTarget {
    switch kind {
    case 0: return .resident(index % 2 == 0 ? .a : .b)
    case 1:
        let b = UInt8(truncatingIfNeeded: index)
        return .item(ItemID(UUID(uuid: (b, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0))))
    case 2: return .plank(PlankID(UInt64(index)))
    case 3: return .ladder(LadderID(UInt64(index)))
    case 4: return .decor(DecorID(UInt64(index)))
    default:
        let zones: [ToolboxZone] = [.plank, .ladder, .decor(.chair), .decor(.lamp)]
        return .toolbox(zones[index % zones.count])
    }
}

private var hitRegionGen: Generator<HitRegion, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...5),      // 目标类型
        Gen<Int>.int(in: 0...7),      // 目标编号
        Gen<Int>.int(in: 0...40),     // minX / 8
        Gen<Int>.int(in: 0...30),     // minY / 8
        Gen<Int>.int(in: 0...12),     // width / 8（含 0 宽）
        Gen<Int>.int(in: 0...12)      // height / 8
    ).map { kind, index, x, y, w, h in
        HitRegion(
            target: makeTarget(kind: kind, index: index),
            rect: Rect(minX: Double(x * 8), minY: Double(y * 8), width: Double(w * 8), height: Double(h * 8))
        )
    }
}

/// Property 13 的固定场景：两个窗口、左窗沿上一位居民、Ground 上一块落下的木板、右下角 Toolbox。
private enum GestureScene {
    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))
    static let looseID = PlankID(5)
    static let looseX = 300.0
    static let residentPos = Point(x: 250, y: 300)

    static func context(residentState: ResidentState) -> InteractionContext {
        let snaps = [
            WindowSnapshot(id: 1, ownerName: "A", ownerPID: 1,
                           frame: Rect(minX: 100, minY: 300, width: 300, height: 200), zIndex: 0),
            WindowSnapshot(id: 2, ownerName: "B", ownerPID: 1,
                           frame: Rect(minX: 500, minY: 320, width: 300, height: 200), zIndex: 1),
        ]
        var t = WindowTable()
        t.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        let surfaces = SurfaceBuilder.build(windows: snaps, screen: screen)
        let view = WorldView(screen: screen, surfaces: surfaces, showSurfaces: false, residents: [
            ResidentView(id: .a, state: residentState, position: residentPos, facing: .right,
                         isHidden: false, heldItem: nil, bubble: nil, poke: nil),
        ])
        var regions = HitTesting.regions(for: view)
        regions.append(HitRegion(target: .plank(looseID),
                                 rect: SpriteMetrics.loosePlankRect(bottomCenter: Point(x: looseX, y: screen.groundY))))
        return InteractionContext(screen: screen, windows: t, surfaces: surfaces, hitRegions: regions)
    }

    /// 按下点：0 居民、1 Toolbox Plank 区、2 落下的木板、3 空白处。
    static func pressPoint(_ kind: Int, context: InteractionContext) -> Point {
        switch kind {
        case 0: return SpriteMetrics.residentRect(bottomCenter: residentPos).center
        case 1: return ToolboxLayout.zoneFrame(.plank, screen: screen).center
        case 2: return SpriteMetrics.loosePlankRect(bottomCenter: Point(x: looseX, y: screen.groundY)).center
        default: return Point(x: 700, y: 150)
        }
    }
}

/// 指针位移：分量为 0.5pt 的整数倍，范围 ±6pt，使位移常落在 4pt 阈值附近并能恰好等于 4。
private var displacementGen: Generator<Point, some SendableSequenceType> {
    zip(Gen<Int>.int(in: -12...12), Gen<Int>.int(in: -12...12))
        .map { Point(x: Double($0) * 0.5, y: Double($1) * 0.5) }
}

/// 戳居民操作：`poke` 为点击，否则推进 `dt` 秒。
private struct PokeOp: Sendable, CustomStringConvertible {
    var poke: Bool
    var dt: Double
    var description: String { poke ? "poke" : "advance(\(dt))" }
}

private var pokeOpGen: Generator<PokeOp, some SendableSequenceType> {
    zip(Gen<Int>.int(in: 0...9), Gen<Double>.double(in: 0...0.6))
        .map { k, dt in PokeOp(poke: k < 4, dt: dt) }
}

/// 任意居民：9 个状态、5 种 Attachment、3 种目标、有无持有物、任意 hangElapsed。
private var pokeResidentGen: Generator<Resident, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...(ResidentState.allCases.count - 1)),
        Gen<Int>.int(in: 0...4),
        Gen<Int>.int(in: 0...2),
        Gen<Bool>.bool,
        Gen<Double>.double(in: 0...1.4),
        Gen<Double>.double(in: 0...300)
    ).map { s, a, g, held, hang, v in
        let attachments = [
            Resident(id: .a, attachment: .window(7, offset: v)).attachment,
            Resident(id: .a, attachment: .ground(x: v)).attachment,
            Resident(id: .a, attachment: .plank(PlankID(3), t: v / 300)).attachment,
            Resident(id: .a, attachment: .ladder(LadderID(4), height: v / 2)).attachment,
            Resident(id: .a, attachment: .free(Point(x: v, y: 200))).attachment,
        ]
        let attachment = attachments[a]
        let goal: Goal = [.none, .confined, .reach(.b)][g]
        let item = held ? ItemID(UUID(uuid: (1, 2, 3, 4, 5, 6, 0x40, 8, 0x80, 10, 11, 12, 13, 14, 15, 16))) : nil
        return Resident(id: .a, state: ResidentState.allCases[s], attachment: attachment,
                        goal: goal, heldItem: item, hangElapsed: hang)
    }
}

struct InteractionTests {
    // Feature: v1, Property 14: 戳居民不改变行动
    // **Validates: Requirements 7.6, 7.7, 7.8, 7.9**
    @Test func pokeDoesNotChangeResidentBehavior() async {
        await propertyCheck(
            count: 100,
            input: pokeResidentGen,
            pokeOpGen.array(of: 1...30)
        ) { resident0, ops in
            let k = Tunables()
            let eps = 1e-9
            let canJump = InteractionController.jumpingStates.contains(resident0.state)
            #expect(canJump == [.idle, .walking, .carrying, .waiting].contains(resident0.state))
            #expect(k.pokeJumpHeight <= 16 && k.pokeJumpDuration <= 0.5)

            var r = resident0
            // 参考模型：距最近一次点击的时间、距当前跳跃开始的时间（nil 表示没有跳跃）
            var sinceLastPoke: Double?
            var sinceJumpStart: Double?

            for op in ops {
                if op.poke {
                    let active = r.poke.map { $0.jumpRemaining > 0 || $0.bubbleRemaining > 0 } ?? false
                    let jumpBefore = r.poke?.jumpRemaining ?? 0
                    InteractionController.poke(&r, constants: k)
                    guard let p = r.poke else { Issue.record("点击后没有 poke 状态"); return }
                    // 每次点击后「?」气泡剩余 1.5 秒（Requirement 7.6、7.8、7.9）
                    #expect(p.bubbleRemaining == k.pokeBubbleDuration)
                    if active {
                        // 跳跃或气泡未结束时再点：不开始新跳跃（Requirement 7.9）
                        #expect(p.jumpRemaining == jumpBefore, "再次点击改变了跳跃：\(jumpBefore) → \(p.jumpRemaining)")
                    } else if canJump {
                        #expect(p.jumpRemaining == k.pokeJumpDuration)
                        sinceJumpStart = 0
                    } else {
                        // 不跳跃的状态只显示气泡（Requirement 7.8）
                        #expect(p.jumpRemaining == 0)
                    }
                    sinceLastPoke = 0
                } else {
                    let wasJumping = (r.poke?.jumpRemaining ?? 0) > 0
                    let reported = InteractionController.advancePoke(&r, dt: op.dt)
                    #expect(reported == wasJumping)
                    sinceLastPoke = sinceLastPoke.map { $0 + op.dt }
                    sinceJumpStart = sinceJumpStart.map { $0 + op.dt }
                }

                // 同一时间最多一次跳跃：跳跃剩余时间与参考的开始时刻一致，0.5 秒内结束
                let jumpRemaining = r.poke?.jumpRemaining ?? 0
                if let t = sinceJumpStart {
                    let expected = max(0, k.pokeJumpDuration - t)
                    #expect(abs(jumpRemaining - expected) < eps, "跳跃剩余 \(jumpRemaining)，参考 \(expected)")
                    if t >= 0.5 { #expect(jumpRemaining == 0, "跳跃超过 0.5 秒仍未结束") }
                    if jumpRemaining == 0 { sinceJumpStart = nil }
                } else {
                    #expect(jumpRemaining == 0, "没有点击开始跳跃却在跳")
                }
                if !canJump { #expect(jumpRemaining == 0) }

                // 气泡恰好在最后一次点击后 1.5 秒结束
                let bubble = r.poke?.bubbleRemaining ?? 0
                let expectedBubble = sinceLastPoke.map { max(0, k.pokeBubbleDuration - $0) } ?? 0
                #expect(abs(bubble - expectedBubble) < eps, "气泡剩余 \(bubble)，参考 \(expectedBubble)")
                if (r.poke?.jumpRemaining ?? 0) == 0 && bubble == 0 { #expect(r.poke == nil) }

                // 跳跃高度在 [0, 16]pt
                let lift = InteractionController.jumpLift(r.poke, constants: k)
                #expect(lift >= 0 && lift <= 16 && lift <= k.pokeJumpHeight + eps, "跳跃高度 \(lift)")
                if jumpRemaining == 0 { #expect(lift == 0) }

                // 戳不改变居民的其他任何字段（Requirement 7.7、7.8：状态、目标、持有物、Attachment、hangElapsed）
                var stripped = r
                stripped.poke = nil
                #expect(stripped == resident0, "点击序列改变了居民：\(r)")
            }

            // 足够长时间后跳跃和气泡都结束，落回原 Attachment
            InteractionController.advancePoke(&r, dt: k.pokeBubbleDuration + 0.1)
            #expect(r.poke == nil)
            #expect(InteractionController.jumpLift(r.poke, constants: k) == 0)
            #expect(r == resident0)

            // 跳跃轨迹逐点：起点和终点为 0，全程不超过 16pt
            for i in 0...40 {
                let rem = k.pokeJumpDuration * Double(i) / 40
                let l = InteractionController.jumpLift(PokeState(jumpRemaining: rem, bubbleRemaining: 1), constants: k)
                #expect(l >= 0 && l <= 16)
                if i == 0 || i == 40 { #expect(abs(l) < eps) }
            }
        }
    }

    /// 参考实现：包含该点（含边）的区域中取优先级最高者，并列取列表中最靠前的一个。
    static func referenceHit(_ p: Point, regions: [HitRegion]) -> HitTarget? {
        let containing = regions.filter {
            p.x >= $0.rect.minX && p.x <= $0.rect.maxX && p.y >= $0.rect.minY && p.y <= $0.rect.maxY
        }
        guard let best = containing.map({ $0.target.priority }).min() else { return nil }
        return containing.first { $0.target.priority == best }?.target
    }

    static func rank(_ t: HitTarget) -> Int {
        switch t {
        case .resident: return 0
        case .item: return 1
        case .decor: return 2
        case .plank, .ladder: return 3
        case .toolbox: return 4
        }
    }

    // Feature: v1, Property 12: 命中检测（v2 调整：加入 Decor，Resident > Item > Decor > Plank/Ladder > Toolbox）
    // **Validates: Requirements 7.1, v2 3.7**
    @Test func hitTestMatchesBoundingRectsAndPriority() async {
        await propertyCheck(
            count: 100,
            input: hitRegionGen.array(of: 0...12),
            // 点对齐 4pt 网格，一半落在 8pt 网格上（即可能恰好在边上）
            Gen<Int>.int(in: -4...110),
            Gen<Int>.int(in: -4...85)
        ) { regions, px, py in
            let p = Point(x: Double(px) * 4, y: Double(py) * 4)
            let result = HitTesting.hitTest(p, regions: regions)
            let expected = Self.referenceHit(p, regions: regions)

            #expect(result == expected, "点 \(p)：hitTest 得到 \(String(describing: result))，参考为 \(String(describing: expected))")

            let insideAny = regions.contains { $0.rect.contains(p) }
            #expect((result != nil) == insideAny, "点 \(p) 是否命中与是否落在某个外接矩形内不一致")

            if let result {
                // 返回的目标必须有一个包含该点的区域，且没有更高优先级的区域包含该点
                #expect(regions.contains { $0.target == result && $0.rect.contains(p) })
                #expect(!regions.contains { $0.rect.contains(p) && Self.rank($0.target) < Self.rank(result) })
            }
        }
    }

    // Feature: v1, Property 13: 手势判定
    // **Validates: Requirements 7.5, 7.10, 7.11, 8.8, 11.1, 11.2**
    @Test func gestureClassificationByMaxDisplacement() async {
        await propertyCheck(
            count: 100,
            input: Gen<Int>.int(in: 0...3),                       // 按下的对象
            Gen<Int>.int(in: 0...(ResidentState.allCases.count - 1)),
            displacementGen.array(of: 0...6),                     // moved 事件相对按下点的位移
            displacementGen,                                       // up 事件相对按下点的位移
            Gen<Int>.int(in: 1...3)                                // 位移放大倍数（3 时制造大幅拖动）
        ) { kind, stateIndex, moves, upDelta, scaleIndex in
            let k = Tunables()
            let state = ResidentState.allCases[stateIndex]
            let ctx = GestureScene.context(residentState: state)
            let start = GestureScene.pressPoint(kind, context: ctx)
            let scale = scaleIndex == 3 ? 10.0 : 1.0
            let offsets = (moves + [upDelta]).map { Point(x: $0.x * scale, y: $0.y * scale) }
            let points = offsets.map { Point(x: start.x + $0.x, y: start.y + $0.y) }

            let resident0 = Resident(id: .a, state: state, attachment: .window(1, offset: 150))
            var residents: [ResidentID: Resident] = [.a: resident0]
            let planks0 = PlankStore(planks: [GestureScene.looseID: .loose(.ground(x: GestureScene.looseX))], nextID: 6)
            var planks = planks0
            var g = Gesture.none

            func handle(_ e: PointerEvent) -> [InteractionOutcome] {
                InteractionController.handle(e, gesture: &g, context: ctx, planks: &planks,
                                             residents: &residents, constants: k)
            }

            var outcomes = handle(.down(start))
            // 第一个位移超过阈值的事件下标；没有则为点击。
            let firstDrag = offsets.firstIndex { hypot($0.x, $0.y) > k.clickDragThreshold }
            let maxDisp = offsets.map { hypot($0.x, $0.y) }.max() ?? 0
            let isDrag = maxDisp > k.clickDragThreshold
            #expect(isDrag == (firstDrag != nil))

            // 拖动木板时的抓取偏移（按下点减去对象位置）
            let loosePos = Point(x: GestureScene.looseX, y: GestureScene.screen.groundY)
            let grab = Point(x: start.x - loosePos.x, y: start.y - loosePos.y)

            for (i, p) in points.enumerated() {
                let isUp = i == points.count - 1
                let out = handle(isUp ? .up(p) : .moved(p))
                outcomes += out
                let dragging = firstDrag.map { i >= $0 } ?? false

                // 进入拖动的那个事件恰好产生一次 dragStarted（只有可拖对象）
                let started = out.filter { if case .dragStarted = $0 { return true } else { return false } }
                if i == firstDrag, kind == 1 {
                    #expect(started == [.dragStarted(.newPlank)])
                } else if i == firstDrag, kind == 2 {
                    #expect(started == [.dragStarted(.plank(GestureScene.looseID))])
                } else {
                    #expect(started.isEmpty, "事件 \(i) 意外开始拖动：\(out)")
                }

                guard !isUp else { continue }
                switch kind {
                case 0:
                    // 在居民上：未超阈值为 pressed，超过后吞掉
                    if dragging { #expect(g == .swallowed) } else { #expect(g == .pressed(on: .resident(.a), at: start)) }
                case 1:
                    if dragging {
                        #expect(g == .dragging(.newPlank, grabOffset: Point(x: 0, y: 0), pointer: p))
                    } else {
                        #expect(g == .pressed(on: .toolbox(.plank), at: start))
                    }
                case 2:
                    if dragging {
                        // Requirement 11.2：对象位置 = 指针 − 抓取偏移，每帧成立
                        guard case let .dragging(subject, gOff, ptr) = g else {
                            Issue.record("事件 \(i) 应在拖动中，实际 \(g)"); continue
                        }
                        #expect(subject == .plank(GestureScene.looseID))
                        #expect(gOff == grab)
                        #expect(ptr == p)
                        #expect(Point(x: ptr.x - gOff.x, y: ptr.y - gOff.y)
                                == Point(x: loosePos.x + offsets[i].x, y: loosePos.y + offsets[i].y))
                        #expect(planks.planks[GestureScene.looseID] == .dragged)
                    } else {
                        #expect(g == .pressed(on: .plank(GestureScene.looseID), at: start))
                        #expect(planks == planks0)
                    }
                default:
                    #expect(g == .none)
                }
            }

            // 松开后手势结束
            #expect(g == .none)

            switch kind {
            case 0:
                if isDrag {
                    // Requirement 7.11：拖动居民不改变它，也没有气泡
                    #expect(outcomes.isEmpty)
                    #expect(residents[.a] == resident0)
                } else {
                    // Requirement 7.5：点击居民 → 戳；状态与 Attachment 不变
                    #expect(outcomes == [.poked(.a)])
                    #expect(residents[.a]?.state == state)
                    #expect(residents[.a]?.attachment == resident0.attachment)
                    #expect(residents[.a]?.poke != nil)
                }
                #expect(planks == planks0)
            case 1:
                if isDrag {
                    #expect(outcomes.first == .dragStarted(.newPlank))
                    #expect(planks.planks.count == 2, "拖出后松手应新增恰好一块木板")
                } else {
                    // Requirement 8.8：点击 Toolbox 不新建任何对象
                    #expect(outcomes.isEmpty)
                    #expect(planks == planks0)
                }
                #expect(residents[.a] == resident0)
            case 2:
                if isDrag {
                    #expect(outcomes.first == .dragStarted(.plank(GestureScene.looseID)))
                    #expect(planks.planks.count == 1)
                    #expect(planks.planks[GestureScene.looseID] != .dragged)
                } else {
                    #expect(outcomes.isEmpty)
                    #expect(planks == planks0)
                }
                #expect(residents[.a] == resident0)
            default:
                // 空白处：不产生任何结果，世界不变
                #expect(outcomes.isEmpty)
                #expect(planks == planks0)
                #expect(residents[.a] == resident0)
            }
        }
    }
}

// MARK: - Property 18：放置结果与预览一致

/// Property 18 的窗口布局：0 到 5 个窗口，坐标对齐 8pt 网格。`minY` 先表示上沿在 Ground 上方的高度
/// （64 到 480pt），由测试按屏幕换算成真实坐标，使梯子能够到 Ground。约 2/3 的窗口紧挨前一个窗口右侧
/// （间隙 −40 到 200pt、上沿高差 ±64pt），使木板的绿色预览经常出现。
private var placementLayoutGen: Generator<[Rect], some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...2),     // 0 随机位置；否则紧挨前一个窗口
        Gen<Int>.int(in: 0...150),   // minX / 8（0 到 1200pt）
        Gen<Int>.int(in: 8...60),    // 上沿在 Ground 上方的高度 / 8
        Gen<Int>.int(in: 15...50),   // width / 8
        Gen<Int>.int(in: 15...50),   // height / 8
        Gen<Int>.int(in: -5...25),   // 紧挨时的水平间隙 / 8
        Gen<Int>.int(in: -8...8)     // 紧挨时的上沿高差 / 8
    ).map { mode, x, y, w, h, gap, rise in
        (mode, Rect(minX: Double(x * 8), minY: Double(y * 8), width: Double(w * 8), height: Double(h * 8)),
         Double(gap * 8), Double(rise * 8))
    }
    .array(of: 0...5)
    .map { specs in
        var frames: [Rect] = []
        for (mode, r0, gap, rise) in specs {
            var r = r0
            if mode > 0, let prev = frames.last {
                r.minX = prev.maxX + gap
                r.minY = min(max(prev.minY + rise, 64), 480)
            }
            frames.append(r)
        }
        return frames
    }
}

/// 松手点的生成参数：屏幕内任意位置（mode 0）、某个窗口上沿附近（mode 1）或某个窗口右端附近（mode 2）。
private struct ReleaseSpec: Sendable, CustomStringConvertible {
    var mode: Int
    var windowIndex: Int
    var u: Double       // 窗口宽度上的相对位置，或屏幕宽度上的相对位置
    var dy: Double      // 相对窗口上沿的竖直偏移，或屏幕高度上的相对位置
    var description: String { "release(mode: \(mode), w: \(windowIndex), u: \(u), dy: \(dy))" }
}

private var releaseSpecGen: Generator<ReleaseSpec, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...4),
        Gen<Int>.int(in: 0...9),
        Gen<Double>.double(in: -0.2...1.2),
        Gen<Double>.double(in: -80...80)
    ).map { k, w, u, dy in ReleaseSpec(mode: min(k, 2), windowIndex: w, u: u, dy: dy) }
}

extension InteractionTests {
    /// 下落起点的参考：预览中木板的中心、梯子的上端（已吸附时比较高一端抬高 `releaseLift`），平放时为底边中点。
    static func expectedFallStart(_ g: PreviewGeometry) -> Point {
        let lift = InteractionController.releaseLift
        switch g {
        case let .snappedPlank(a, b, _, _): return Point(x: (a.x + b.x) / 2, y: min(a.y, b.y) - lift)
        case let .loosePlank(c), let .looseLadder(c): return c
        case let .snappedLadder(top, _, _): return Point(x: top.x, y: top.y - lift)
        }
    }

    // Feature: v1, Property 18: 放置结果与预览一致
    // **Validates: Requirements 9.5, 9.6, 9.8, 9.11, 10.5, 10.6, 10.10, 11.7**
    @Test func releaseResultMatchesPreview() async {
        await propertyCheck(
            count: 100,
            input: Gen<ScreenInfo>.screen,
            placementLayoutGen,
            Gen<Int>.int(in: 0...3),               // 0 新木板、1 新梯子、2 落下的木板、3 落下的梯子
            Gen<Double>.double(in: 0.1...0.6),     // 落下物件在 Ground 上的相对 x
            releaseSpecGen
        ) { screen, layout, kind, looseU, spec in
            let k = Tunables()
            let snaps = layout.enumerated().map { i, r in
                var f = r
                f.minY = screen.groundY - r.minY
                return WindowSnapshot(id: WindowID(i + 1), ownerName: "App\(i + 1)", ownerPID: Int32(200 + i),
                                      frame: f, zIndex: i)
            }
            let dt = 1.0 / 30
            var clock = Date(timeIntervalSince1970: 1_000_000)
            var source = FakeWindowSource(snapshots: snaps)
            let engine = WorldEngine(constants: k, clockStart: clock, screen: screen,
                                     rng: RandomSource(seed: 7), demoResident: false)
            @discardableResult
            func step(_ pointer: [PointerEvent] = []) -> StepOutput {
                clock = clock.addingTimeInterval(dt)
                return engine.step(FrameInput(poll: source.poll(), screen: screen, pointer: pointer, now: clock))
            }

            // 落下的木板或梯子放在 Ground 上
            let looseX = screen.visibleFrame.minX + looseU * screen.visibleFrame.width
            let isPlank = kind == 0 || kind == 2
            var existingPlank: PlankID?
            var existingLadder: LadderID?
            if kind == 2 { existingPlank = engine.insertPlank(.loose(.ground(x: looseX))) }
            if kind == 3 { existingLadder = engine.insertLadder(.loose(.ground(x: looseX))) }
            step()

            let ground = Point(x: looseX, y: screen.groundY)
            let press: Point
            switch kind {
            case 0: press = ToolboxLayout.zoneFrame(.plank, screen: screen).center
            case 1: press = ToolboxLayout.zoneFrame(.ladder, screen: screen).center
            case 2: press = SpriteMetrics.loosePlankRect(bottomCenter: ground).center
            default: press = SpriteMetrics.looseLadderRect(bottomCenter: ground).center
            }

            let frames = snaps.map(\.frame)
            let release: Point
            if spec.mode > 0, !frames.isEmpty {
                let f = frames[spec.windowIndex % frames.count]
                let x = spec.mode == 1 ? f.minX + spec.u * f.width : f.maxX + (spec.u - 0.5) * 100
                release = Point(x: x, y: f.minY + spec.dy)
            } else {
                release = Point(x: screen.frame.minX + spec.u * screen.frame.width,
                                y: screen.frame.minY + (spec.dy + 80) / 160 * screen.frame.height)
            }

            let planksBefore = Set(engine.state.planks.planks.keys)
            let laddersBefore = Set(engine.state.ladders.ladders.keys)

            // 按下、拖出阈值、移到松手点；松手前一帧的预览就是玩家看到的预览
            step([.down(press), .moved(Point(x: press.x, y: press.y - 20))])
            let shown = step([.moved(release)]).view.preview
            guard let preview = shown else {
                Issue.record("拖动中没有预览，kind \(kind)，手势 \(engine.state.gesture)"); return
            }
            let out = step([.up(release)])
            #expect(engine.state.gesture == .none)

            // 确定本次松手的对象 ID：拖出时恰好新增一个，拖起已有对象时数量不变
            let id: UInt64
            if isPlank {
                let added = Set(engine.state.planks.planks.keys).subtracting(planksBefore)
                if let e = existingPlank {
                    #expect(added.isEmpty)
                    #expect(engine.state.planks.planks.count == planksBefore.count)
                    id = e.rawValue
                } else {
                    #expect(added.count == 1, "拖出木板后新增 \(added.count) 块")
                    guard let a = added.first else { return }
                    id = a.rawValue
                }
            } else {
                let added = Set(engine.state.ladders.ladders.keys).subtracting(laddersBefore)
                if let e = existingLadder {
                    #expect(added.isEmpty)
                    #expect(engine.state.ladders.ladders.count == laddersBefore.count)
                    id = e.rawValue
                } else {
                    #expect(added.count == 1, "拖出梯子后新增 \(added.count) 架")
                    guard let a = added.first else { return }
                    id = a.rawValue
                }
            }
            let pid = PlankID(id), lid = LadderID(id)
            let nav = engine.state.nav

            func offsetOn(_ w: WindowID, _ x: Double) -> Double? {
                engine.state.windows.visibleSnapshot(w).map { x - $0.frame.minX }
            }

            if preview.isValid {
                if isPlank {
                    guard case let .snappedPlank(a, b, wa, wb) = preview.geometry,
                          let oa = offsetOn(wa, a.x), let ob = offsetOn(wb, b.x) else {
                        Issue.record("绿色木板预览不是吸附形状：\(preview.geometry)"); return
                    }
                    #expect(out.interactions.contains(.plankPlaced(pid)))
                    #expect(engine.state.planks.planks[pid] == .placed(PlacedPlank(
                        id: pid, endA: PlankEnd(window: wa, offset: oa), endB: PlankEnd(window: wb, offset: ob))))
                    // Requirement 9.6：本次 step 结束前已出现在路面和通路图中
                    #expect(engine.state.surfaces.contains { $0.id == .plank(pid) })
                    #expect(nav.nodes[.plank(pid)] != nil)
                    let plankEdges = nav.allEdges.filter { $0.kind == .plank && ($0.from == .plank(pid) || $0.to == .plank(pid)) }
                    #expect(plankEdges.count == 4, "木板 \(pid) 的走木板边数为 \(plankEdges.count)")
                } else {
                    guard case let .snappedLadder(top, bottom?, topSurface) = preview.geometry,
                          let wid = topSurface.windowID, let ot = offsetOn(wid, top.x) else {
                        Issue.record("绿色梯子预览不是吸附形状：\(preview.geometry)"); return
                    }
                    #expect(out.interactions.contains(.ladderPlaced(lid)))
                    guard case let .placed(l)? = engine.state.ladders.ladders[lid] else {
                        Issue.record("绿色松手后梯子未架设：\(String(describing: engine.state.ladders.ladders[lid]))"); return
                    }
                    #expect(l.top == PlankEnd(window: wid, offset: ot))
                    #expect(l.bottom == bottom)
                    // Requirement 10.5：双向爬梯边在本次 step 结束前已出现
                    let ladderEdges = nav.allEdges.filter { $0.kind == .ladder(lid) }
                    #expect(ladderEdges.count == 2, "梯子 \(lid) 的爬梯边数为 \(ladderEdges.count)")
                    #expect(Set(ladderEdges.map(\.from)) == [topSurface, l.bottomSurface])
                }
                return
            }

            // 红色：开始下落（同一帧可能已落地），不贡献任何节点或边
            if isPlank {
                #expect(out.interactions.contains(.plankDropped(pid)))
            } else {
                #expect(out.interactions.contains(.ladderDropped(lid)))
            }
            func notInGraph() {
                #expect(!engine.state.surfaces.contains { $0.id == .plank(pid) })
                #expect(engine.state.nav.nodes[.plank(pid)] == nil)
                #expect(!engine.state.nav.allEdges.contains { $0.from == .plank(pid) || $0.to == .plank(pid) })
                if !isPlank {
                    #expect(engine.state.ladders.ladders[lid]?.placed == nil)
                    #expect(!engine.state.nav.allEdges.contains { $0.kind == .ladder(lid) })
                }
            }
            notInGraph()

            // 落定后的状态，用 PlankState 表示（梯子的 `.loose` 转写为同一形式以便比较）
            func resting() -> PlankState? {
                if isPlank, case let .loose(a)? = engine.state.planks.planks[pid] { return .loose(a) }
                if !isPlank, case let .loose(a)? = engine.state.ladders.ladders[lid] { return .loose(a) }
                return nil
            }
            var frames2 = 0
            while resting() == nil, frames2 < 120 {
                step()
                notInGraph()
                frames2 += 1
            }
            guard let rest = resting() else {
                Issue.record("红色松手后 4 秒仍未落地"); return
            }

            // 参考落点：x 夹紧到屏幕宽度与 Ground 范围的交集，取起点下方第一条 Window_Ledge 或 Ground
            let start = Self.expectedFallStart(preview.geometry)
            let lo = max(screen.frame.minX, screen.visibleFrame.minX)
            let hi = min(screen.frame.maxX, screen.visibleFrame.maxX)
            let x = min(max(start.x, lo), hi)
            let candidates = engine.state.surfaces.filter {
                $0.id.plankID == nil && x >= $0.start.x && x <= $0.end.x && $0.y(atX: x) > start.y
            }
            let target = candidates.min { ($0.y(atX: x), $0.id) < ($1.y(atX: x), $1.id) }
                ?? engine.state.surfaces.first { $0.id == .ground }
            guard let target else { Issue.record("没有 Ground"); return }
            let expected: PlankState
            switch target.id {
            case let .ledge(w, _):
                guard let o = offsetOn(w, x) else { Issue.record("落点窗口不可见"); return }
                expected = .loose(.window(w, offset: o))
            default:
                expected = .loose(.ground(x: x))
            }
            #expect(rest == expected, "落点 \(rest)，参考 \(expected)（起点 \(start)，预览 \(preview.geometry)）")
        }
    }
}

// MARK: - Property 20: 物件松手

/// 物件松手点的生成参数。`mode`：0 屏内任意点；1 屏幕左右两侧之外；2 某窗口上沿附近 ±30pt；
/// 3 某窗口上沿上方恰好 0 / Drop_Snap_Distance / 略超出处；4 前方窗口 x 范围内、后方窗口上沿附近（常为被遮挡部分）。
private struct ItemReleaseCase: Sendable {
    var mode: Int
    var i: Int
    var j: Int
    var u: Double      // 0...1，用于在区间内取 x
    var v: Double      // 0...1，用于取 y 或屏外距离
    var exact: Int     // mode 3 的竖直距离档位
}

private var itemReleaseCaseGen: Generator<ItemReleaseCase, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...4),
        Gen<Int>.int(in: 0...49),
        Gen<Int>.int(in: 0...49),
        Gen<Double>.double(in: 0...1),
        Gen<Double>.double(in: 0...1),
        Gen<Int>.int(in: 0...4)
    ).map { ItemReleaseCase(mode: $0, i: $1, j: $2, u: $3, v: $4, exact: $5) }
}

struct ItemReleasePropertyTests {
    /// 由用例参数构造松开点（物件底边中点）。
    private static func releasePoint(_ c: ItemReleaseCase, windows: [WindowSnapshot], screen: ScreenInfo) -> Point {
        let f = screen.frame
        let mode = windows.isEmpty ? min(c.mode, 1) : c.mode
        switch mode {
        case 0:
            return Point(x: f.minX + c.u * f.width, y: f.minY + c.v * f.height)
        case 1:
            let x = c.u < 0.5 ? f.minX - 1 - c.v * 400 : f.maxX + 1 + c.v * 400
            return Point(x: x, y: f.minY + c.u * f.height)
        case 2:
            let w = windows[c.i % windows.count].frame
            return Point(x: w.minX + c.u * w.width, y: w.minY - 30 + c.v * 60)
        case 3:
            let w = windows[c.i % windows.count].frame
            let dys: [Double] = [0, 24, 24.001, -0.001, 12]
            return Point(x: w.minX + c.u * w.width, y: w.minY - dys[c.exact])
        default:
            let front = windows[c.i % windows.count].frame
            let back = windows[c.j % windows.count].frame
            return Point(x: front.minX + c.u * front.width, y: back.minY - 30 + c.v * 40)
        }
    }

    /// 参考实现：直接按窗口几何判断「x 处是否是窗口 w 的 Window_Ledge」，不使用 SurfaceBuilder。
    /// `strict` 为 true 时前方窗口的左右边不算遮挡。返回可接受的窗口集合；空集表示应下落。
    private static func referenceTargets(
        x: Double, y: Double, windows: [WindowSnapshot], snapDistance: Double, strict: Bool
    ) -> Set<WindowID> {
        func exposed(_ w: WindowSnapshot) -> Bool {
            guard w.frame.minX <= x, x <= w.frame.maxX else { return false }
            let top = w.frame.minY
            return !windows.contains { f in
                f.zIndex < w.zIndex && f.frame.minY <= top && top <= f.frame.maxY
                    && (strict ? (f.frame.minX < x && x < f.frame.maxX)
                               : (f.frame.minX <= x && x <= f.frame.maxX))
            }
        }
        let candidates = windows.filter { w in
            let dy = w.frame.minY - y
            return dy >= 0 && dy <= snapDistance && exposed(w)
        }
        guard let best = candidates.map({ $0.frame.minY - y }).min() else { return [] }
        return Set(candidates.filter { $0.frame.minY - y == best }.map(\.id))
    }

    // Feature: v1, Property 20: 物件松手
    // **Validates: Requirements 11.3, 11.4, 11.5, 11.6**
    @Test func itemRelease() async {
        let k = Tunables()
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen.screen,
            itemReleaseCaseGen
        ) { windows, screen, c in
            var table = WindowTable()
            table.apply(.success(eligible: windows, existingIDs: Set(windows.map(\.id))))
            let surfaces = SurfaceBuilder.build(windows: windows, screen: screen)
            let release = Self.releasePoint(c, windows: windows, screen: screen)

            // x 先夹紧到主显示器宽度（与 Ground 范围的交集）
            let lo = max(screen.frame.minX, screen.visibleFrame.minX)
            let hi = min(screen.frame.maxX, screen.visibleFrame.maxX)
            let x = min(max(release.x, lo), hi)

            // 窗口左右边恰好落在 x 上时遮挡与否有两种合理理解，两者都接受。
            let strict = Self.referenceTargets(x: x, y: release.y, windows: windows,
                                               snapDistance: k.dropSnapDistance, strict: true)
            let loose = Self.referenceTargets(x: x, y: release.y, windows: windows,
                                              snapDistance: k.dropSnapDistance, strict: false)

            let result = InteractionController.itemRelease(
                at: release, surfaces: surfaces, windows: table, screen: screen, constants: k)

            switch result {
            case let .attached(.window(id, offset)):
                #expect(strict.contains(id) || loose.contains(id),
                        "附着到 \(id)，参考 strict=\(strict) loose=\(loose)，松开点 \(release)，x=\(x)")
                if let w = windows.first(where: { $0.id == id }) {
                    #expect(abs(offset - (x - w.frame.minX)) < 1e-9, "offset \(offset)，参考 \(x - w.frame.minX)")
                } else {
                    Issue.record("附着到不存在的窗口 \(id)")
                }
            case let .falling(f):
                #expect(strict.isEmpty || loose.isEmpty,
                        "应附着到 strict=\(strict) loose=\(loose)，却下落；松开点 \(release)，x=\(x)")
                #expect(f.position == Point(x: x, y: release.y))
                #expect(f.velocityY == 0)
            default:
                Issue.record("意外的结果 \(result)，松开点 \(release)")
            }
        }
    }
}
