import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 一位居民的初始设置。
fileprivate struct WalkResidentSpec: Sendable {
    var place: Int          // 0 窗口 1；1 窗口 2；2 木板；3 窗口 3；4 Ground
    var frac: Double
    var state: Int          // 0 idle；1 walking；2 falling（从空中落下）
    var speed: Int          // 0 → 1；1 → 1.5；2 → 1.6
    var goal: Int           // 0 无；1–3 reachWindow(1–3)；4 reachPoint(Ground)
    var goalFrac: Double
}

/// 一次模拟：三个窗口（窗口 1、2 上沿同高并架一块木板，窗口 3 有一架通往 Ground 的梯子）、两位居民，
/// 以及可选的「第几帧关闭哪个窗口」（关闭窗口 1 或 2 时木板失效，桥上的居民悬挂）。
fileprivate struct WalkScenario: Sendable {
    var bridgeY: Double
    var ladderFrac: Double
    var residents: [WalkResidentSpec]
    var frames: Int
    var closeFrame: Int     // 0 表示不关闭
    var closeWindow: Int    // 1、2 或 3
}

fileprivate extension Gen where Value == WalkResidentSpec {
    static var walkResident: Generator<WalkResidentSpec, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...4),
            Gen<Double>.double(in: 0...1),
            Gen<Int>.int(in: 0...2),
            Gen<Int>.int(in: 0...2),
            Gen<Int>.int(in: 0...4),
            Gen<Double>.double(in: 0...1)
        ).map { WalkResidentSpec(place: $0, frac: $1, state: $2, speed: $3, goal: $4, goalFrac: $5) }
    }
}

fileprivate extension Gen where Value == WalkScenario {
    static var walkScenario: Generator<WalkScenario, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 250...600),
            Gen<Double>.double(in: 0.1...0.9),
            Gen<WalkResidentSpec>.walkResident.array(of: 2),
            Gen<Int>.int(in: 60...240),
            Gen<Int>.int(in: 0...240),
            Gen<Int>.int(in: 1...3)
        ).map {
            WalkScenario(bridgeY: Double($0), ladderFrac: $1, residents: $2,
                         frames: $3, closeFrame: $4, closeWindow: $5)
        }
    }
}

struct ResidentV2Tests {
    static let screen = ResidentTests.screen
    static let dt = 1.0 / 30
    /// 窗口 3 的上沿：梯子长度固定为 Ladder_Length，下端落在 Ground 上。
    static let thirdY = screen.groundY - Tunables().ladderLength

    static func win(_ id: WindowID, x: Double, y: Double, w: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: 150), zIndex: 0)
    }

    fileprivate static func resident(_ id: ResidentID, _ s: WalkResidentSpec, scenario: WalkScenario,
                                     plank: PlankID) -> Resident {
        let attachment: CoreAttachment
        let point: Point
        switch s.place {
        case 0:
            attachment = .window(1, offset: 300 * s.frac)
            point = Point(x: 100 + 300 * s.frac, y: scenario.bridgeY)
        case 1:
            attachment = .window(2, offset: 300 * s.frac)
            point = Point(x: 500 + 300 * s.frac, y: scenario.bridgeY)
        case 2:
            attachment = .plank(plank, t: s.frac)
            point = Point(x: 400 + 100 * s.frac, y: scenario.bridgeY)
        case 3:
            attachment = .window(3, offset: 300 * s.frac)
            point = Point(x: 950 + 300 * s.frac, y: thirdY)
        default:
            attachment = .ground(x: 50 + 1340 * s.frac)
            point = Point(x: 50 + 1340 * s.frac, y: screen.groundY)
        }
        let goal: Goal
        switch s.goal {
        case 1, 2, 3: goal = .reachWindow(WindowID(s.goal))
        case 4: goal = .reachPoint(.ground, x: 50 + 1340 * s.goalFrac, arriveWithin: 5)
        default: goal = .none
        }
        let speedFactor = [1, 1.5, 1.6][s.speed]
        if s.state == 2 {
            // 从附着点上方 60pt 开始下落。
            let p = Point(x: point.x, y: point.y - 60)
            return Resident(id: id, state: .falling, attachment: .free(p), goal: goal,
                            fall: FallState(position: p), speedFactor: speedFactor)
        }
        return Resident(id: id, state: s.state == 1 ? .walking : .idle, attachment: attachment, goal: goal,
                        wander: WanderState(pauseRemaining: 0.2 + s.goalFrac, walkRemaining: 2 * s.frac),
                        speedFactor: speedFactor)
    }

    // Feature: V2, Property 13: Walk_Distance 累加
    /// 每一帧：`walkDistance` 的增量等于「本帧结束时为 `walking` 或 `running`，且上一帧结束时不是
    /// `falling`、`hanging`、`climbing`」时屏幕 x 位移的绝对值，否则为 0。
    /// 归零（离开 `sitting` / `sleeping`，或数值变小）的那一帧重新开始计数，不检查。
    ///
    /// **Validates: Requirements 4.14**
    @Test func walkDistanceAccumulatesWalkingFramesOnly() async {
        await propertyCheck(count: 100, input: Gen.walkScenario) { s in
            var source = FakeWindowSource(snapshots: [
                Self.win(1, x: 100, y: s.bridgeY, w: 300),
                Self.win(2, x: 500, y: s.bridgeY, w: 300),
                Self.win(3, x: 950, y: Self.thirdY, w: 300),
            ])
            var now = Date(timeIntervalSince1970: 3_000_000)
            let engine = WorldEngine(clockStart: now, screen: Self.screen, rng: RandomSource(seed: 7),
                                     demoResident: false)
            let plank = engine.insertPlank(.placed(PlacedPlank(
                id: PlankID(0), endA: PlankEnd(window: 1, offset: 300), endB: PlankEnd(window: 2, offset: 0))))
            let ladderOffset = (300 * s.ladderFrac).rounded()
            engine.insertLadder(.placed(PlacedLadder(
                id: LadderID(0), top: PlankEnd(window: 3, offset: ladderOffset),
                bottomSurface: .ground, bottom: Point(x: 950 + ladderOffset, y: Self.screen.groundY))))
            for (id, spec) in zip([ResidentID.a, .b], s.residents) {
                engine.place(Self.resident(id, spec, scenario: s, plank: plank))
            }

            func step() -> StepOutput {
                now = now.addingTimeInterval(Self.dt)
                return engine.step(FrameInput(poll: source.poll(), screen: Self.screen, commands: [], now: now))
            }

            var out = step()
            for frame in 1 ..< s.frames {
                let prevStates = engine.state.residents.mapValues(\.state)
                let prevDistance = engine.state.residents.mapValues(\.walkDistance)
                let prevX = Dictionary(uniqueKeysWithValues: out.view.residents.compactMap { v in v.position.map { (v.id, $0.x) } })
                if frame == s.closeFrame { source.close(WindowID(s.closeWindow)) }
                out = step()
                let x = Dictionary(uniqueKeysWithValues: out.view.residents.compactMap { v in v.position.map { (v.id, $0.x) } })
                for (id, r) in engine.state.residents {
                    guard let before = prevStates[id], let d0 = prevDistance[id] else { continue }
                    // 归零的帧：重新开始计数。
                    if before == .sitting || before == .sleeping || r.walkDistance < d0 { continue }
                    var expected = 0.0
                    if r.state == .walking || r.state == .running,
                       before != .falling, before != .hanging, before != .climbing,
                       let x0 = prevX[id], let x1 = x[id] {
                        expected = abs(x1 - x0)
                    }
                    #expect(abs(r.walkDistance - d0 - expected) < 1e-6,
                            "frame \(frame) \(id): \(before) → \(r.state), Δ \(r.walkDistance - d0), expected \(expected)")
                }
            }
        }
    }
}
