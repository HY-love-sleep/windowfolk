import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// V2 静止时降到 Idle_Poll_Rate（design.md Property 54，任务 16.5；扩展 v1 Property 41 / R24.2）。
//
// 随机静止世界：0 至 2 个窗口；1 至 2 位居民，状态为 idle、waiting、sitting（坐在自己脚下的 Chair 上）或
// sleeping，放在 Ground 或窗沿上；另有 0 至 3 个 Chair 或 Lamp。剧情、自主活动和小心思关闭，居民用
// `Goal.hold` 停在原地，时区固定为 UTC，起始时刻离昼夜切换至少 1 小时。
// 静止阶段每帧检查：从第一个安静帧（启动帧之后）起满 2 秒时 `nextRate` 变为 idle，此前为 active，此后保持 idle。
// 随后打破一个条件（居民 running、拖拽 Decor 并保持不动、新增 Decor、移动 Decor、移动或新增窗口、居民状态或位置变化），
// 该帧起回到 active。

fileprivate struct ObjectSpec: Sendable {
    /// 0 为 Ground，其余为窗口下标 + 1（没有该窗口时放 Ground）。
    var surface: Int
    /// 居民：0 idle、1 waiting、2 sitting、3 sleeping；Decor：0、1 为 Chair，2、3 为 Lamp。
    var kind: Int
}

fileprivate struct PollScenario: Sendable, CustomStringConvertible {
    var windowYs: [Int]
    var residents: [ObjectSpec]
    var decors: [ObjectSpec]
    var hour: Int
    var seed: Int
    var dts: [Double]
    var breakKind: Int
    var holdSeconds: Double

    static let breakNames = ["running", "dragDecor", "addDecor", "moveDecor", "window", "resident"]

    var description: String {
        "windows \(windowYs) residents \(residents.map { "\($0.kind)@\($0.surface)" }) "
            + "decors \(decors.map { "\($0.kind)@\($0.surface)" }) hour \(hour) seed \(seed) "
            + "frames \(dts.count) total \(dts.reduce(0, +)) break \(Self.breakNames[breakKind]) hold \(holdSeconds)"
    }
}

fileprivate extension Gen where Value == PollScenario {
    static var scenario: Generator<PollScenario, some SendableSequenceType> {
        let object = zip(Gen<Int>.int(in: 0...2), Gen<Int>.int(in: 0...3)).map { ObjectSpec(surface: $0, kind: $1) }
        return zip(
            Gen<Int>.int(in: 4...10).array(of: 0...2),
            object.array(of: 1...2),
            object.array(of: 0...3),
            Gen<Int>.int(in: 0...2),
            Gen<Int>.int(in: 0...1_000_000),
            // 75 至 100 帧、每帧 1/30 至 0.1 秒：静止阶段总长至少 2.5 秒
            Gen<Double>.double(in: (1.0 / 30)...0.1).array(of: 75...100),
            zip(Gen<Int>.int(in: 0...5), Gen<Double>.double(in: 2.1...3.0))
        ).map { ys, residents, decors, hour, seed, dts, brk in
            PollScenario(windowYs: ys, residents: residents, decors: decors, hour: [2, 12, 22][hour],
                         seed: seed, dts: dts, breakKind: brk.0, holdSeconds: brk.1)
        }
    }
}

struct PollRateV2Tests {
    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let windowWidth = 400.0

    fileprivate final class Sim {
        let engine: WorldEngine
        var source: FakeWindowSource
        var windows: [WindowSnapshot]
        var now: Date
        /// 不被居民占用的 Decor（可拖拽、可移动）。
        var freeDecors: [DecorID] = []
        /// 每个 Surface 已用的槽位数（键 0 为 Ground）。
        private var used: [Int: Int] = [:]

        init(_ s: PollScenario) {
            now = Date(timeIntervalSince1970: 23 * 86400 + Double(s.hour) * 3600)
            windows = s.windowYs.enumerated().map { i, y in
                WindowSnapshot(id: WindowID(i + 1), ownerName: "App\(i + 1)", ownerPID: 1,
                               frame: Rect(minX: 100 + 600 * Double(i), minY: Double(y) * 40,
                                           width: PollRateV2Tests.windowWidth, height: 160), zIndex: 0)
            }
            source = FakeWindowSource(snapshots: windows)
            engine = WorldEngine(clockStart: now, screen: PollRateV2Tests.screen,
                                 rng: RandomSource(seed: UInt64(s.seed)), demoResident: false,
                                 story: false, activities: false)
            var nextDecor: UInt64 = 1
            for (i, r) in s.residents.enumerated() {
                let at = slot(r.surface)
                let state: ResidentState = [.idle, .waiting, .sitting, .sleeping][r.kind]
                var seat: DecorID?
                if state == .sitting {
                    seat = DecorID(nextDecor)
                    engine.insertDecor(Decor(id: DecorID(nextDecor), type: .chair, placement: .attached(at)))
                    nextDecor += 1
                }
                engine.place(Resident(id: i == 0 ? .a : .b, state: state, attachment: at,
                                      facing: r.kind % 2 == 0 ? .left : .right,
                                      goal: state == .waiting ? .wait(face: nil) : .hold(face: nil), seat: seat))
            }
            for d in s.decors {
                let id = DecorID(nextDecor)
                nextDecor += 1
                engine.insertDecor(Decor(id: id, type: d.kind < 2 ? .chair : .lamp, placement: .attached(slot(d.surface))))
                freeDecors.append(id)
            }
        }

        /// 互不重叠的位置：Ground 上 x = 60 + 90k（k < 10），窗沿上偏移 40 + 70k（k < 5）。
        func slot(_ surface: Int) -> CoreAttachment {
            if surface > 0, surface <= windows.count, used[surface, default: 0] < 5 {
                let k = used[surface, default: 0]
                used[surface] = k + 1
                return .window(windows[surface - 1].id, offset: 40 + 70 * Double(k))
            }
            let k = used[0, default: 0]
            used[0] = k + 1
            return .ground(x: 60 + 90 * Double(k))
        }

        @discardableResult
        func step(_ dt: Double, pointer: [PointerEvent] = []) -> StepOutput {
            now = now.addingTimeInterval(dt)
            return engine.step(FrameInput(poll: source.poll(), screen: PollRateV2Tests.screen,
                                          pointer: pointer, now: now, timeZone: PollRateV2Tests.utc))
        }
    }

    // Feature: V2, Property 54: 静止时降到 Idle_Poll_Rate
    // **Validates: Requirements 19.8**
    @Test func staticV2DesktopDropsToIdleAndWakesOnChange() async {
        // sitting、sleeping 不阻止降频；running 一定保持 active（扩展 v1 R24.4）
        for s in [ResidentState.idle, .waiting, .sitting, .sleeping] {
            #expect(!WorldEngine.activeResidentStates.contains(s))
        }
        #expect(WorldEngine.activeResidentStates.contains(.running))

        await propertyCheck(count: 100, input: Gen.scenario) { s in
            let sim = Sim(s)
            #expect(sim.step(s.dts[0]).nextRate == .active)   // 启动帧

            // 静止阶段：居民状态和位置、Decor 数量和位置、窗口快照都不变，没有拖拽
            let before = sim.engine.state.residents
            var quietStart: Date?
            var sawIdle = false
            for dt in s.dts.dropFirst() {
                let rate = sim.step(dt).nextRate
                let start = quietStart ?? sim.now
                quietStart = start
                let elapsed = sim.now.timeIntervalSince(start)
                let expected: PollRate = elapsed >= 2 ? .idle : .active
                #expect(rate == expected, "t=\(elapsed) \(s)")
                if rate == .idle { sawIdle = true }
            }
            #expect(sawIdle, "\(s)")
            for (id, r) in sim.engine.state.residents {
                #expect(r.state == before[id]?.state && r.attachment == before[id]?.attachment, "\(id) \(s)")
            }

            // 打破一个条件：该帧起回到 active
            let dt = 1.0 / 30
            var kind = s.breakKind
            if (kind == 1 || kind == 3) && sim.freeDecors.isEmpty { kind = 2 }
            switch PollScenario.breakNames[kind] {
            case "running":
                // 居民 A 在 Ground 上快跑去远处（speedFactor > 1 时为 running）
                guard var r = sim.engine.state.residents[.a] else { break }
                r.state = .running
                r.seat = nil
                r.speedFactor = 1.6
                r.attachment = .ground(x: 960)
                r.goal = .reachPoint(.ground, x: 60, arriveWithin: 1)
                sim.engine.place(r)
                var sawRunning = false
                for _ in 0 ..< 15 {
                    let out = sim.step(dt)
                    let running = out.view.residents.contains { $0.state == .running }
                    if running { sawRunning = true }
                    #expect(out.nextRate == .active, "running \(s)")
                }
                #expect(sawRunning, "\(s)")
            case "dragDecor":
                // 按住一个 Decor 拖开后鼠标保持不动，超过 2 秒仍为 active
                let id = sim.freeDecors[0]
                guard let v = sim.step(dt).view.decors.first(where: { $0.id == id }) else {
                    Issue.record("decor \(id) not visible \(s)")
                    break
                }
                let p = Point(x: v.position.x, y: v.position.y - 4)
                #expect(sim.step(dt, pointer: [.down(p), .moved(Point(x: p.x + 60, y: p.y - 150))]).nextRate == .active)
                #expect(sim.engine.state.gesture.isActive, "\(s)")
                var held = 0.0
                while held < s.holdSeconds {
                    held += 0.1
                    #expect(sim.step(0.1).nextRate == .active, "held \(held) \(s)")
                }
            case "addDecor":
                sim.engine.insertDecor(Decor(id: DecorID(100), type: .lamp, placement: .attached(.ground(x: 1000))))
                #expect(sim.step(dt).nextRate == .active, "\(s)")
            case "moveDecor":
                let id = sim.freeDecors[0]
                guard let d = sim.engine.state.decors.decors[id] else { break }
                sim.engine.insertDecor(Decor(id: id, type: d.type, placement: .attached(.ground(x: 1000))))
                #expect(sim.step(dt).nextRate == .active, "\(s)")
            case "window":
                if let w = sim.windows.first {
                    sim.source.move(w.id, to: Point(x: w.frame.minX + 40, y: w.frame.minY))
                } else {
                    sim.source.add(WindowSnapshot(id: WindowID(9), ownerName: "New", ownerPID: 2,
                                                  frame: Rect(minX: 600, minY: 200, width: 200, height: 160), zIndex: 0))
                }
                #expect(sim.step(dt).nextRate == .active, "\(s)")
            default:
                // 居民 A：坐着或睡着的改为 idle；idle 或 waiting 的挪到另一个位置
                guard var r = sim.engine.state.residents[.a] else { break }
                if r.state == .sitting || r.state == .sleeping {
                    r.state = .idle
                    r.seat = nil
                } else {
                    r.attachment = .ground(x: 1000)
                }
                sim.engine.place(r)
                #expect(sim.step(dt).nextRate == .active, "\(s)")
            }
        }
    }
}
