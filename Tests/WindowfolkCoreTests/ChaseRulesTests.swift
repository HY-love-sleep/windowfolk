import PropertyBased
import Testing
@testable import WindowfolkCore

/// 一个随机追逐世界：可见窗口、木板、梯子，加上 Runner 和 Chaser 位置的选择参数。
fileprivate struct FleeWorld: Sendable {
    var windows: [WindowSnapshot]
    var screen: ScreenInfo
    var plankSpecs: [NavGraphTests.PlankSpec]
    var ladderSpecs: [NavGraphTests.LadderSpec]
    var runnerIndex: Int
    var runnerFrac: Double
    var chaserIndex: Int
    var chaserFrac: Double
}

fileprivate extension Gen where Value == FleeWorld {
    /// 复用 v1 的窗口布局、木板和梯子生成器。
    static var fleeWorld: Generator<FleeWorld, some SendableSequenceType> {
        zip(
            Gen<[WindowSnapshot]>.windowLayout,
            Gen<ScreenInfo>.screen,
            NavGraphTests.plankSpecs,
            NavGraphTests.ladderSpecs,
            Gen<Int>.int(in: 0...999),
            Gen<Double>.double(in: 0...1),
            Gen<Int>.int(in: 0...999),
            Gen<Double>.double(in: 0...1)
        ).map {
            FleeWorld(windows: $0, screen: $1, plankSpecs: $2, ladderSpecs: $3,
                      runnerIndex: $4, runnerFrac: $5, chaserIndex: $6, chaserFrac: $7)
        }
    }
}

/// 抓到判定的随机输入。x 坐标和 x 差都取 0.25 的整数倍，使 `chaser.x + dx` 和 `|dx|` 都能精确表示，
/// 参考判定用生成时的 dx，不重算浮点差。
fileprivate struct CatchCase: Sendable {
    var chaserLoc: ResidentLocation?
    var runnerLoc: ResidentLocation?
    /// 生成时选定的 x 差的绝对值（runner.x - chaser.x 的绝对值）。
    var absDX: Double
    var chaserState: ResidentState
    var runnerState: ResidentState
    var hidden: Set<ResidentID>
    var phase: ChasePhase
    var elapsed: Double
}

fileprivate let catchSurfacePool: [SurfaceID] = [.ground, .ledge(1, index: 0), .ledge(1, index: 1),
                                                .ledge(2, index: 0), .plank(PlankID(1))]

fileprivate extension Gen where Value == CatchCase {
    static var surfacePool: [SurfaceID] { catchSurfacePool }

    /// dx 分四类：正好等于 Catch_Distance（16）、16 以内、刚超出 0.25、远超出。
    static var absDX: Generator<Double, some SendableSequenceType> {
        zip(Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...64), Gen<Int>.int(in: 66...4000)).map { kind, near, far in
            switch kind {
            case 0: return 16.0
            case 1: return Double(near) / 4
            case 2: return 16.25
            default: return Double(far) / 4
            }
        }
    }

    /// 已用时长有一类正好落在 Chase_Duration（60）上。
    static var elapsed: Generator<Double, some SendableSequenceType> {
        zip(Gen<Int>.int(in: 0...2), Gen<Int>.int(in: 0...480)).map { kind, q in
            kind == 0 ? 60.0 : Double(q) / 4
        }
    }

    static var catchCase: Generator<CatchCase, some SendableSequenceType> {
        let positions = zip(
            Gen<Bool>.bool(0.9), Gen<Bool>.bool(0.9),
            Gen<Int>.int(in: 0...(surfacePool.count - 1)), Gen<Bool>.bool(0.7),
            Gen<Int>.int(in: 0...(surfacePool.count - 1)),
            Gen<Int>.int(in: -2000...8000), absDX, Gen<Bool>.bool
        )
        let allStates = ResidentState.allCases
        let states = zip(
            Gen<Int>.int(in: 0...(allStates.count - 1)),
            Gen<Int>.int(in: 0...(allStates.count - 1)),
            Gen<Bool>.bool(0.2), Gen<Bool>.bool(0.2),
            Gen<Bool>.bool,
            elapsed
        )
        return zip(positions, states).map { p, s in
            let (hasC, hasR, cIdx, same, rIdx, cxQ, dx, negative) = p
            let (cStateIdx, rStateIdx, cHidden, rHidden, running, elapsed) = s
            let cState = allStates[cStateIdx], rState = allStates[rStateIdx]
            let phase: ChasePhase = running ? .running : .ready
            let cSurface = surfacePool[cIdx]
            let rSurface = same ? cSurface : surfacePool[rIdx]
            let cx = Double(cxQ) / 4
            let rx = negative ? cx - dx : cx + dx
            var hidden = Set<ResidentID>()
            if cHidden { hidden.insert(ChaseRules.chaser) }
            if rHidden { hidden.insert(ChaseRules.runner) }
            return CatchCase(
                chaserLoc: hasC ? ResidentLocation(surface: cSurface, x: cx) : nil,
                runnerLoc: hasR ? ResidentLocation(surface: rSurface, x: rx) : nil,
                absDX: dx, chaserState: cState, runnerState: rState, hidden: hidden,
                phase: phase, elapsed: elapsed)
        }
    }
}

struct ChaseRulesTests {
    /// Requirement 22.1 的参考判定（不含 Chase_Phase，与 `isCaught` 的职责一致）。
    fileprivate static func referenceCaught(_ c: CatchCase, distance: Double) -> Bool {
        guard let cl = c.chaserLoc, let rl = c.runnerLoc else { return false }
        let airborne: Set<ResidentState> = [.falling, .hanging, .climbing]
        return cl.surface == rl.surface
            && !airborne.contains(c.chaserState) && !airborne.contains(c.runnerState)
            && c.hidden.isEmpty
            && c.absDX <= distance
    }

    /// Requirement 22.1、22.2 的组合规则：只在 running 阶段判定；先判 caught，再判已满 Chase_Duration 的 escaped。
    fileprivate static func outcome(phase: ChasePhase, elapsed: Double, caught: Bool,
                                    duration: Double) -> ChaseOutcome? {
        guard phase == .running else { return nil }
        if caught { return .caught }
        if elapsed >= duration { return .escaped }
        return nil
    }

    // Feature: V2, Property 59: 抓到判定
    // **Validates: Requirements 22.1, 22.2**
    @Test func catchDetermination() async {
        await propertyCheck(count: 200, input: Gen.catchCase) { c in
            let k = Tunables()
            let caught = ChaseRules.isCaught(chaser: c.chaserLoc, runner: c.runnerLoc,
                                             chaserState: c.chaserState, runnerState: c.runnerState,
                                             hidden: c.hidden, distance: k.catchDistance)
            let expected = Self.referenceCaught(c, distance: k.catchDistance)
            let ctx = "chaser \(String(describing: c.chaserLoc)) \(c.chaserState) runner \(String(describing: c.runnerLoc)) "
                + "\(c.runnerState) |dx| \(c.absDX) hidden \(c.hidden)"
            #expect(caught == expected, "isCaught \(caught) expected \(expected) \(ctx)")

            // 交换两人的位置不改变判定（|dx| 对称）。
            let swapped = ChaseRules.isCaught(chaser: c.runnerLoc, runner: c.chaserLoc,
                                              chaserState: c.runnerState, runnerState: c.chaserState,
                                              hidden: c.hidden, distance: k.catchDistance)
            #expect(swapped == caught, "swapped \(swapped) original \(caught) \(ctx)")

            // 22.1：ready 阶段从不得出结局；running 阶段 isCaught 为真即 caught。
            // 22.2：同帧抓到与撑满同时成立时取 caught；未抓到且已满 Chase_Duration 时取 escaped。
            let result = Self.outcome(phase: c.phase, elapsed: c.elapsed, caught: caught, duration: k.chaseDuration)
            switch c.phase {
            case .ready:
                #expect(result == nil, "ready produced \(String(describing: result)) \(ctx)")
            case .running:
                if expected {
                    #expect(result == .caught, "phase running elapsed \(c.elapsed) → \(String(describing: result)) \(ctx)")
                } else if c.elapsed >= k.chaseDuration {
                    #expect(result == .escaped, "elapsed \(c.elapsed) → \(String(describing: result)) \(ctx)")
                } else {
                    #expect(result == nil, "elapsed \(c.elapsed) → \(String(describing: result)) \(ctx)")
                }
            }
        }
    }

    /// 按 Requirement 21.4 的排序键比较：Chaser 长度降序（nil 视为 +∞）、Runner 长度升序、x 升序、(SurfaceID, x) 升序。
    fileprivate typealias Keyed = (point: FleePoint, chaser: Double, runner: Double)

    fileprivate static func precedes(_ l: Keyed, _ r: Keyed) -> Bool {
        if l.chaser != r.chaser { return l.chaser > r.chaser }
        if l.runner != r.runner { return l.runner < r.runner }
        if l.point.x != r.point.x { return l.point.x < r.point.x }
        return l.point.surface < r.point.surface
    }

    // Feature: V2, Property 58: Flee_Target 选择
    // **Validates: Requirements 21.4, 21.5**
    @Test func fleeTargetSelection() async {
        await propertyCheck(count: 100, input: Gen.fleeWorld) { w in
            let k = Tunables()
            let planks = NavGraphTests.makePlanks(w.plankSpecs, windows: w.windows)
            let placedLadders = NavGraphTests.makeLadders(w.ladderSpecs, windows: w.windows, screen: w.screen)
            var table = WindowTable()
            for win in w.windows { table.records[win.id] = WindowRecord(snapshot: win, visibility: .visible) }
            let surfaces = SurfaceBuilder.build(windows: w.windows, planks: planks, screen: w.screen)
            let presentPlanks = Set(surfaces.compactMap(\.id.plankID))
            let navPlanks = planks.filter { presentPlanks.contains($0.id) }
            let ladders = placedLadders.compactMap { $0.navLadder(windows: table, surfaces: surfaces) }
            let graph = NavGraph.build(surfaces: surfaces, planks: navPlanks, ladders: ladders, constants: k)

            func point(on s: Surface, _ frac: Double) -> Double { s.start.x + (s.end.x - s.start.x) * frac }

            // Runner 随机放在某条 Surface 上。
            let runnerSurface = surfaces[w.runnerIndex % surfaces.count]
            let runnerX = point(on: runnerSurface, w.runnerFrac)
            let runnerField = graph.horizontalField(from: runnerSurface.id, at: runnerX)

            // Chaser 随机放置；不可达 Runner 所在 Surface 时退回到 Runner 所在 Surface（满足属性前提）。
            var chaserSurface = surfaces[w.chaserIndex % surfaces.count]
            var chaserX = point(on: chaserSurface, w.chaserFrac)
            var chaserField = graph.horizontalField(from: chaserSurface.id, at: chaserX)
            if !chaserField.isReachable(runnerSurface.id) {
                chaserSurface = runnerSurface
                chaserX = point(on: runnerSurface, w.chaserFrac)
                chaserField = graph.horizontalField(from: chaserSurface.id, at: chaserX)
            }
            let ctx = "runner \(runnerSurface.id)@\(runnerX) chaser \(chaserSurface.id)@\(chaserX) surfaces \(surfaces.count)"
            #expect(chaserField.isReachable(runnerSurface.id), "\(ctx)")

            // 候选点集合：Runner 可达的每条 Surface 两端内收 inset，长度 ≤ 2 × inset 时取中点。
            let inset = k.fleeEdgeInset
            var expectedSet = Set<FleePoint>()
            for s in surfaces where runnerField.isReachable(s.id) {
                let lo = min(s.start.x, s.end.x), hi = max(s.start.x, s.end.x)
                if hi - lo <= 2 * inset {
                    expectedSet.insert(FleePoint(surface: s.id, x: (lo + hi) / 2))
                } else {
                    expectedSet.insert(FleePoint(surface: s.id, x: lo + inset))
                    expectedSet.insert(FleePoint(surface: s.id, x: hi - inset))
                }
            }
            let candidates = ChaseRules.candidates(runnerField: runnerField, surfaces: surfaces, inset: inset)
            #expect(Set(candidates) == expectedSet, "candidates \(candidates) expected \(expectedSet) \(ctx)")
            #expect(candidates.count == expectedSet.count, "duplicate candidates \(candidates) \(ctx)")
            // Runner 所在 Surface 本身总是可达，候选不为空。
            #expect(!candidates.isEmpty, "\(ctx)")

            // 参考选择：按排序键全排序后取第一个。
            let keyed: [Keyed] = candidates.map {
                ($0, chaserField.length(to: $0.surface, x: $0.x) ?? .infinity,
                 runnerField.length(to: $0.surface, x: $0.x) ?? .infinity)
            }
            let expected = keyed.sorted(by: Self.precedes).first?.point
            let selected = ChaseRules.selectFleeTarget(candidates, chaserField: chaserField, runnerField: runnerField)
            #expect(selected == expected, "selected \(String(describing: selected)) expected \(String(describing: expected)) \(ctx)")

            // 选中点的 Chaser 长度是全部候选中的最大值（不可达视为最大）。
            if let selected {
                let sel = chaserField.length(to: selected.surface, x: selected.x) ?? .infinity
                let maxLen = keyed.map(\.chaser).max() ?? -.infinity
                #expect(sel == maxLen, "chaser length \(sel) max \(maxLen) \(ctx)")
            }

            // 确定性：重复调用、打乱候选顺序后结果相同。
            #expect(ChaseRules.selectFleeTarget(candidates, chaserField: chaserField, runnerField: runnerField) == selected,
                    "\(ctx)")
            #expect(ChaseRules.selectFleeTarget(candidates.reversed(), chaserField: chaserField,
                                                runnerField: runnerField) == selected, "\(ctx)")
            #expect(ChaseRules.candidates(runnerField: runnerField, surfaces: surfaces.reversed(), inset: inset)
                    == candidates, "\(ctx)")
        }
    }
}
