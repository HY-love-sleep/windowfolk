import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 一次追逐速度模拟：Chaser 与 Runner 站在同一条足够长的水平 Surface 上（窗口 1 的窗沿或 Ground）。
fileprivate struct ChaseSpeedScenario: Sendable {
    var onGround: Bool
    var ledgeY: Int          // 窗口 1 上沿
    var width: Int           // 窗口 1 宽度
    var chaserFrac: Double   // Chaser 在 Surface 上的相对位置
    var gap: Double          // Runner 与 Chaser 的初始水平距离（不超过 Surface 上可放的范围）
    var wisherIsA: Bool
}

fileprivate extension Gen where Value == ChaseSpeedScenario {
    static var chaseSpeedScenario: Generator<ChaseSpeedScenario, some SendableSequenceType> {
        zip(
            Gen<Bool>.bool,
            Gen<Int>.int(in: 250...450),
            Gen<Int>.int(in: 800...1300),
            Gen<Double>.double(in: 0...1),
            Gen<Double>.double(in: 60...400),
            Gen<Bool>.bool
        ).map {
            ChaseSpeedScenario(onGround: $0, ledgeY: $1, width: $2, chaserFrac: $3, gap: $4, wisherIsA: $5)
        }
    }
}

struct ChaseSpeedTests {
    static let screen = StoryEngineTests.screen
    static let dt = 1.0 / 30
    static let mainX = 50.0

    /// 跨迭代累计的覆盖计数，用于全局断言属性没有被空洞地满足。
    final class Coverage: @unchecked Sendable {
        private let lock = NSLock()
        private var iterations = 0
        private var covered = 0
        func record(checked: Bool) {
            lock.lock(); defer { lock.unlock() }
            iterations += 1
            if checked { covered += 1 }
        }
        var snapshot: (iterations: Int, covered: Int) {
            lock.lock(); defer { lock.unlock() }
            return (iterations, covered)
        }
    }

    /// 窗口 1：长窗沿；窗口 2：远在下方的另一个合格窗口（只用于分配 Home_Window），两者之间不能小跳或往下跳。
    fileprivate static func windows(_ s: ChaseSpeedScenario) -> [WindowSnapshot] {
        [
            WindowSnapshot(id: 1, ownerName: "App1", ownerPID: 1,
                           frame: Rect(minX: mainX, minY: Double(s.ledgeY), width: Double(s.width), height: 150),
                           zIndex: 0),
            WindowSnapshot(id: 2, ownerName: "App2", ownerPID: 2,
                           frame: Rect(minX: 100, minY: 650, width: 300, height: 150), zIndex: 1),
        ]
    }

    /// 在 Surface 上的屏幕 x 处的 Attachment。
    fileprivate static func attachment(_ s: ChaseSpeedScenario, x: Double) -> CoreAttachment {
        s.onGround ? .ground(x: x) : .window(1, offset: x - mainX)
    }

    /// 居民沿 Surface 水平移动时所在的 Surface 标识；不在 Surface 上（爬梯、下落、悬挂、被拖动）为 nil。
    static func surfaceKey(_ a: CoreAttachment) -> String? {
        switch a {
        case let .window(id, _): return "w\(id)"
        case .ground: return "g"
        case let .plank(id, _): return "p\(id)"
        default: return nil
        }
    }

    /// 一位居民在 running 阶段同向连续水平移动的帧：`xs` 为起点及之后各帧结束时的屏幕 x，`sign` 为方向。
    struct Run {
        var xs: [Double] = []
        var sign: Double = 0
        mutating func reset() { xs = []; sign = 0 }
    }

    // Feature: V2, Property 56: 追逐速度
    /// Chase_Phase 为 `running` 时，Chaser（Runner）沿 Surface 水平移动的每一帧状态为 `running`；
    /// 任意连续 1 秒（30 帧）同向水平移动中，水平位移与 `walkSpeed × 1.6`（`× 1.5`）× 1 秒之差不超过 5%。
    /// 小跳、往下跳、爬梯、悬挂、下落中的居民不处于 `running`。
    ///
    /// **Validates: Requirements 21.1**
    ///
    /// 覆盖断言：Chaser 接近 Surface 中点（两端路线长度几乎相等）且初始间距小时，Runner 的 Flee_Target 不一定是测试
    /// 预想的那一端，`running` 阶段不到 1 秒（实测 26 至 29 帧）就被抓到，本次迭代不可能出现 1 秒同向移动窗口。
    /// 因此只在 `running` 阶段持续超过 30 帧时要求本次迭代至少检查过一个窗口，并在全部迭代上要求至少一半有覆盖，
    /// 避免属性被空洞地满足。速度比例和 `running` 状态的逐帧检查不变。
    ///
    /// 到达帧：Runner 在某帧走完最后一段（位移不超过一帧的速度上限）到达 Flee_Target 时，按设计同帧停下、
    /// 状态为 `idle` 面朝 Chaser。这一帧已不在移动，不要求 `running`，同向移动段在此结束。
    @Test func chaserAndRunnerRunAtScaledWalkSpeed() async {
        let coverage = Coverage()
        await propertyCheck(count: 100, input: Gen.chaseSpeedScenario) { s in
            let k = Tunables()
            var source = FakeWindowSource(snapshots: Self.windows(s))
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            let engine = WorldEngine(constants: k, clockStart: now, screen: Self.screen, rng: RandomSource(seed: 3))
            @discardableResult
            func step(_ commands: [Command] = []) -> StepOutput {
                now = now.addingTimeInterval(Self.dt)
                return engine.step(FrameInput(poll: source.poll(), screen: Self.screen, commands: commands, now: now))
            }
            step()   // 分配 Home_Window

            // Surface 范围与两人的起点。Runner 放在 Chaser 与离 Chaser 较远的 Surface 端点之间，
            // 使它逃向该端点时不必穿过 Chaser，从而有足够长的连续水平移动。
            let lo = s.onGround ? 0.0 : Self.mainX
            let hi = s.onGround ? Self.screen.frame.width : Self.mainX + Double(s.width)
            let inset = 20.0
            let cx = lo + inset + (hi - lo - 2 * inset) * s.chaserFrac
            let towardRight = hi - cx >= cx - lo
            let room = (towardRight ? hi - cx : cx - lo) - inset - 10
            let gap = min(s.gap, room)
            let rx = cx + (towardRight ? gap : -gap)
            engine.place(Resident(id: ChaseRules.chaser, attachment: Self.attachment(s, x: cx)))
            engine.place(Resident(id: ChaseRules.runner, attachment: Self.attachment(s, x: rx)))

            var out = step([.triggerWish(.chase, s.wisherIsA ? .a : .b)])
            #expect(engine.state.wishes.active.map(\.type) == [.chase])

            let factor: [ResidentID: Double] = [ChaseRules.chaser: k.chaserSpeedFactor,
                                                ChaseRules.runner: k.runnerSpeedFactor]
            var runs: [ResidentID: Run] = [.a: Run(), .b: Run()]
            var windowsChecked = 0
            var runningFrames = 0
            // ready 2 秒 + running 最多 3 秒。
            for frame in 0 ..< Int((k.chaseReadyDuration + 3) / Self.dt) {
                let before = engine.state.residents
                let prevX = Dictionary(uniqueKeysWithValues: out.view.residents.compactMap { v in
                    v.position.map { (v.id, $0.x) }
                })
                out = step()
                // 追逐在本帧结束（得出结局后状态改为 celebrating）：不再检查。
                guard let chase = engine.state.wishes.active.first(where: { $0.type == .chase })?.chase,
                      chase.phase == .running else {
                    if frame > Int(k.chaseReadyDuration / Self.dt) + 1 { break }
                    continue
                }
                runningFrames += 1
                let x = Dictionary(uniqueKeysWithValues: out.view.residents.compactMap { v in
                    v.position.map { (v.id, $0.x) }
                })
                for id in [ResidentID.a, .b] {
                    guard let r = engine.state.residents[id], let r0 = before[id] else { continue }
                    let v = k.walkSpeed * factor[id]!
                    // 小跳、往下跳、爬梯、悬挂、下落：不为 running。
                    if r.traversal != nil || [.falling, .hanging, .climbing].contains(r.state)
                        || Self.surfaceKey(r.attachment) == nil {
                        #expect(r.state != .running, "frame \(frame) \(id): \(r.state) \(r.attachment)")
                        runs[id]!.reset()
                        continue
                    }
                    guard let x0 = prevX[id], let x1 = x[id], r0.traversal == nil,
                          let k0 = Self.surfaceKey(r0.attachment), k0 == Self.surfaceKey(r.attachment)
                    else { runs[id]!.reset(); continue }
                    let dx = x1 - x0
                    guard abs(dx) > 1e-9 else { runs[id]!.reset(); continue }
                    // Runner 在本帧走完最后一段到达 Flee_Target（x 差不超过 1pt），随即按设计停下、`idle` 面朝 Chaser：
                    // 这一帧有水平位移但已不在移动，不要求 `running`，同向移动段到此结束。
                    if id == ChaseRules.runner, r.state == .idle, let flee = chase.fleeTarget,
                       abs(x1 - flee.x) <= 1 + 1e-9, abs(dx) <= v * Self.dt + 1e-9 {
                        runs[id]!.reset()
                        continue
                    }
                    // 沿 Surface 水平移动：状态为 running，每帧位移不超过速度 × dt。
                    #expect(r.state == .running, "frame \(frame) \(id): \(r.state)")
                    #expect(abs(dx) <= v * Self.dt + 1e-9, "frame \(frame) \(id): dx \(dx)")
                    let sign: Double = dx > 0 ? 1 : -1
                    if runs[id]!.sign != sign { runs[id]!.reset(); runs[id]!.xs = [x0]; runs[id]!.sign = sign }
                    runs[id]!.xs.append(x1)
                    let xs = runs[id]!.xs
                    if xs.count > 30 {
                        let moved = abs(xs[xs.count - 1] - xs[xs.count - 31])
                        let expected = v * 30 * Self.dt
                        #expect(abs(moved - expected) <= 0.05 * expected,
                                "frame \(frame) \(id): moved \(moved) in 1s, expected \(expected)")
                        windowsChecked += 1
                    }
                }
            }
            // `running` 持续超过 1 秒时，足够长的 Surface 上至少有一段 1 秒的连续水平移动被检查。
            if runningFrames > 30 {
                #expect(windowsChecked > 0, "running \(runningFrames) frames without a 1s window: \(s)")
            }
            coverage.record(checked: windowsChecked > 0)
        }
        let c = coverage.snapshot
        #expect(c.covered * 2 >= c.iterations, "only \(c.covered)/\(c.iterations) iterations checked a 1s window")
    }
}
