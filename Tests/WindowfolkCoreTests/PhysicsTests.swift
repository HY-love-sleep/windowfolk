import PropertyBased
import Testing
@testable import WindowfolkCore

/// 一次下落的生成参数。
private struct FallCase: Sendable {
    var rawX: Double          // 起点 x，可能超出屏幕
    var yFraction: Double     // 起点 y 在 [屏幕顶边上方 100pt, Ground) 之间的位置
    var startOnLedge: Bool    // 尽量让起点恰好落在一条覆盖 x 的 Window_Ledge 上
    var fixedDt: Bool         // true：每帧 1/30 秒；false：使用 randomDts
    var randomDts: [Double]   // 每帧 dt，取值在 (0, 0.25]
}

private extension Gen where Value == FallCase {
    static var fallCase: Generator<FallCase, some SendableSequenceType> {
        zip(
            Gen<Double>.double(in: -600...3600),
            Gen<Double>.double(in: 0...1),
            Gen<Int>.int(in: 0...3),
            Gen<Int>.int(in: 0...1),
            Gen<Double>.double(in: 0.001...0.25).array(of: 1...40)
        ).map { x, yf, onLedge, fixed, dts in
            FallCase(rawX: x, yFraction: yf, startOnLedge: onLedge == 0, fixedDt: fixed == 0, randomDts: dts)
        }
    }
}

struct PhysicsTests {
    /// 参考落点：水平范围包含 x、y 严格大于起点 y 的 Surface 中最高的一条，并列按 SurfaceID。
    static func expectedLanding(x: Double, startY: Double, surfaces: [Surface]) -> Surface? {
        surfaces
            .filter { $0.xRange.lo <= x && x <= $0.xRange.hi && $0.y(atX: x) > startY }
            .min { ($0.y(atX: x), $0.id) < ($1.y(atX: x), $1.id) }
    }

    // Feature: v1, Property 10: 下落与落地
    // **Validates: Requirements 4.2, 4.3, 6.3, 6.4, 6.5, 6.6, 6.7**
    @Test func fallAndLanding() async {
        let tunables = Tunables()
        let g = tunables.fallGravity
        // 屏幕高度不超过 3000pt 时，从顶边落到底边的连续时间不超过 2 秒（Requirement 6.4）
        #expect((2 * 3000 / g).squareRoot() <= 2)

        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen.screen,
            Gen.fallCase
        ) { windows, screen, c in
            let surfaces = SurfaceBuilder.build(windows: windows, screen: screen)
            var table = WindowTable()
            table.apply(.success(eligible: windows, existingIDs: Set(windows.map(\.id))))

            let groundY = screen.groundY
            let x = Physics.clampX(c.rawX, screen: screen)
            var startY = -100 + c.yFraction * (groundY + 100)
            if c.startOnLedge,
                let ledge = surfaces.first(where: {
                    $0.id != .ground && $0.xRange.lo <= x && x <= $0.xRange.hi && $0.y(atX: x) < groundY
                })
            {
                startY = ledge.y(atX: x)
            }
            startY = min(startY, groundY - 1)

            var s = Physics.startFall(at: Point(x: c.rawX, y: startY), screen: screen)
            // x 先夹紧到屏幕宽度（Requirement 6.7）
            #expect(s.position.x == x)
            #expect(s.position.y == startY)

            let expected = Self.expectedLanding(x: x, startY: startY, surfaces: surfaces)
            #expect(expected != nil, "Ground 应作为兜底落点")

            var t = 0.0
            var frame = 0
            var landed: Surface?
            while landed == nil, t < 5 {
                let dt = c.fixedDt ? 1.0 / 30 : c.randomDts[frame % c.randomDts.count]
                let prevY = s.position.y
                landed = Physics.advance(&s, dt: dt, surfaces: surfaces, gravity: g)
                t += dt
                frame += 1
                // x 不变，y 严格增加（Requirement 6.3）
                #expect(s.position.x == x)
                #expect(s.position.y > prevY, "frame \(frame): y \(prevY) -> \(s.position.y)")
            }

            guard let landed else {
                Issue.record("5 秒内未落地：start (\(x), \(startY))")
                return
            }
            // 2 秒内落地（Requirement 6.4、6.7）
            #expect(t <= 2, "用时 \(t) 秒")
            // 落点为起点下方、包含 x 的最高一条 Surface，底边与之重合（Requirement 6.5）
            #expect(landed.id == expected?.id, "落在 \(landed.id)，应为 \(String(describing: expected?.id))")
            #expect(s.position.y == landed.y(atX: x))
            #expect(s.velocityY == 0)

            // 落地后的 Attachment（Requirement 4.2、4.3、6.6）
            let attachment = AttachmentResolver.attachment(landingOn: landed, atX: x, windows: table)
            if landed.id == .ground {
                #expect(attachment == .ground(x: x))
            } else if let wid = landed.id.windowID, let w = windows.first(where: { $0.id == wid }) {
                #expect(attachment == .window(wid, offset: x - w.frame.minX))
                if let attachment,
                    let p = AttachmentResolver.screenPosition(attachment, windows: table, screen: screen)
                {
                    #expect(abs(p.x - x) < 1e-9 && p.y == landed.y(atX: x), "screen position \(p)")
                } else {
                    Issue.record("窗沿落点的 Attachment 无法换算回屏幕坐标")
                }
            } else {
                Issue.record("意外的落点 \(landed.id)")
            }
        }
    }
}

// MARK: - Property 11

/// 一次地面等待的生成参数。
private struct GroundWaitCase: Sendable {
    var startFraction: Double   // 起点 x 在 Ground 范围内的位置
    var windowFraction: Double  // 目标窗口 minX 在屏幕宽度内的位置
    var targetX: Double         // 目标 x，可能落在 Ground 范围之外
    var wanderRange: Double     // Ground_Wander_Range
    var dts: [Double]           // 每帧 dt，取值在 (0, 0.25]
    var seed: UInt64
}

private extension Gen where Value == GroundWaitCase {
    static var groundWaitCase: Generator<GroundWaitCase, some SendableSequenceType> {
        zip(
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: -400...3400),
            Gen<Double>.double(in: 0...120),
            Gen<Double>.double(in: 0.005...0.25).array(of: 1...20),
            Gen<Int>.int(in: 0...10_000)
        ).map { s, w, t, range, dts, seed in
            GroundWaitCase(startFraction: s, windowFraction: w, targetX: t, wanderRange: range,
                           dts: dts, seed: UInt64(seed))
        }
    }
}

struct GroundWaitPropertyTests {
    // Feature: v1, Property 11: 地面等待范围
    // **Validates: Requirements 6.9**
    @Test func groundWaitStaysWithinRange() async {
        await propertyCheck(count: 100, input: Gen.screen, Gen.groundWaitCase) { screen, c in
            var constants = Tunables()
            constants.groundWanderRange = c.wanderRange

            // 目标窗口贴近屏幕顶部，上沿离 Ground 远超小跳和梯子范围：从 Ground 不可达。
            let winWidth = 300.0
            let winX = c.windowFraction * (screen.frame.width - winWidth)
            let snap = WindowSnapshot(
                id: 1, ownerName: "App1", ownerPID: 1,
                frame: Rect(minX: winX, minY: screen.visibleFrame.minY + 10, width: winWidth, height: 200),
                zIndex: 0)
            var table = WindowTable()
            table.apply(.success(eligible: [snap], existingIDs: [1]))
            let surfaces = SurfaceBuilder.build(windows: [snap], planks: [], screen: screen)
            let nav = NavGraph.build(surfaces: surfaces, planks: [], constants: constants)
            let ctx = WorldContext(
                windows: table, surfaces: surfaces, screen: screen, constants: constants, nav: nav,
                residentLocations: [.b: ResidentLocation(surface: .ledge(1, index: 0), x: c.targetX)])

            guard let ground = surfaces.first(where: { $0.id == .ground }) else {
                Issue.record("没有 Ground"); return
            }
            #expect(nav.route(from: .ground, at: ground.start.x, to: .ledge(1, index: 0), targetX: c.targetX) == nil)

            let startX = ground.start.x + c.startFraction * (ground.end.x - ground.start.x)
            let expectedCenter = min(max(c.targetX, ground.start.x), ground.end.x)
            let lo = max(ground.start.x, expectedCenter - c.wanderRange) - 1e-9
            let hi = min(ground.end.x, expectedCenter + c.wanderRange) + 1e-9

            var r = Resident(id: .a, attachment: .ground(x: startX), goal: .reach(.b))
            var rng = RandomSource(seed: c.seed)
            var patrolFrames = 0
            var frame = 0
            // 帧数上限按走到中心所需的帧数推出（最坏情况每帧都取最小 dt），再加上巡逻帧数和余量。
            let minDt = c.dts.min() ?? 0.25
            let approachFrames = Int((abs(expectedCenter - startX) / (constants.walkSpeed * minDt)).rounded(.up))
            let maxFrames = approachFrames + 200 + 100
            while patrolFrames < 200, frame < maxFrames {
                ResidentController.update(&r, world: ctx, dt: c.dts[frame % c.dts.count], rng: &rng)
                frame += 1
                #expect(r.state == .waiting, "frame \(frame): state \(r.state)")
                guard case let .ground(x) = r.attachment else {
                    Issue.record("frame \(frame): 离开了 Ground"); return
                }
                guard r.wander.groundPatrolling else { continue }
                patrolFrames += 1
                #expect(r.wander.groundCenter == expectedCenter,
                        "中心 \(String(describing: r.wander.groundCenter))，应为 \(expectedCenter)")
                #expect(x >= lo && x <= hi, "frame \(frame): x \(x) 不在 [\(lo), \(hi)]")
                if !(x >= lo && x <= hi) { return }
            }
            #expect(patrolFrames == 200, "\(maxFrames) 帧内未到达地面等待中心")
        }
    }
}
