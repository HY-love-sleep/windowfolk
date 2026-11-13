import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 家的选择的测试输入：窗口布局、屏幕、Min_Window_Size，以及「先出现前几个窗口」的分界点。
private struct HomeCase: Sendable {
    var windows: [WindowSnapshot]
    var screen: ScreenInfo
    var minSize: Double
    var prefixCount: Int
}

/// 生成器中的窗口宽高都 ≥ 120pt；取更大的 Min_Window_Size 才能让「面积 ≥ Min_Window_Size²」这一条起作用。
private let minSizeChoices: [Double] = [120, 160, 240, 320]

private extension Gen where Value == HomeCase {
    static var homeCase: Generator<HomeCase, some SendableSequenceType> {
        zip(
            Gen<[WindowSnapshot]>.windowLayout,
            Gen<ScreenInfo>.screen,
            Gen<Int>.int(in: 0...(minSizeChoices.count - 1)),
            Gen<Int>.int(in: 0...2)
        ).map { windows, screen, sizeIndex, prefix in
            HomeCase(windows: windows, screen: screen, minSize: minSizeChoices[sizeIndex],
                     prefixCount: min(prefix, windows.count))
        }
    }
}

struct StoryDirectorTests {
    // MARK: 参考实现

    /// 暴力枚举（Requirement 15.1 至 15.3）：候选为面积 ≥ minSize² 且至少有一段 Window_Ledge 的窗口；
    /// 按「中心距离最大 → zIndex 之和最小 → 窗口 ID 较小的一对」排序取第一对；中心 x 较小者归 Resident_A。
    static func referenceHomes(
        _ windows: [WindowSnapshot], ledges: [Surface], minSize: Double
    ) -> (a: WindowID, b: WindowID)? {
        func hasLedge(_ id: WindowID) -> Bool {
            ledges.contains { if case let .ledge(wid, _) = $0.id { wid == id } else { false } }
        }
        let candidates = windows.filter {
            $0.frame.width * $0.frame.height >= minSize * minSize && hasLedge($0.id)
        }
        var pairs: [(d: Double, z: Int, lo: WindowID, hi: WindowID, p: WindowSnapshot, q: WindowSnapshot)] = []
        for p in candidates {
            for q in candidates where p.id < q.id {
                pairs.append((abs(p.frame.midX - q.frame.midX), p.zIndex + q.zIndex, p.id, q.id, p, q))
            }
        }
        let best = pairs.min { x, y in
            if x.d != y.d { return x.d > y.d }
            if x.z != y.z { return x.z < y.z }
            return (x.lo, x.hi) < (y.lo, y.hi)
        }
        guard let b = best else { return nil }
        if b.p.frame.midX < b.q.frame.midX { return (b.p.id, b.q.id) }
        if b.q.frame.midX < b.p.frame.midX { return (b.q.id, b.p.id) }
        return (b.lo, b.hi)
    }

    /// 家窗口最长一段窗沿中点的偏移量（Requirement 15.4），长度并列时取编号较小的一段。
    static func referenceHomeOffset(_ w: WindowSnapshot, ledges: [Surface]) -> Double? {
        let own = ledges.compactMap { s -> (Int, Surface)? in
            if case let .ledge(wid, index) = s.id, wid == w.id { return (index, s) }
            return nil
        }.sorted { $0.0 < $1.0 }
        var best: Surface?
        for (_, s) in own where best == nil || s.end.x - s.start.x > best!.end.x - best!.start.x {
            best = s
        }
        guard let longest = best else { return nil }
        return (longest.start.x + longest.end.x) / 2 - w.frame.minX
    }

    static func setWindows(_ w: inout WorldState, _ snaps: [WindowSnapshot], constants: Tunables) {
        w.windows.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id))))
        w.surfaces = SurfaceBuilder.build(windows: snaps, planks: [], screen: w.screen)
        w.nav = NavGraph.build(surfaces: w.surfaces, planks: [], constants: constants)
    }

    /// 检查一次开局后的结果与参考一致：选中两个家时居民在家窗口最长窗沿中点、`idle`、剧情已开始；
    /// 否则两人在 Ground 上、未开局。
    static func checkBegin(
        _ s: StoryState, _ w: WorldState, windows: [WindowSnapshot], minSize: Double
    ) {
        let expected = referenceHomes(windows, ledges: w.surfaces, minSize: minSize)
        #expect(w.residents.count == 2)
        guard let homes = expected else {
            #expect(s.stage == nil)
            #expect(s.homes.isEmpty)
            for r in w.residents.values {
                if case .ground = r.attachment {} else { Issue.record("expected ground: \(r.attachment)") }
            }
            return
        }
        #expect(s.homes == [.a: homes.a, .b: homes.b])
        #expect(s.round == 1)
        #expect(s.stage == .wish || s.stage == .waiting || s.stage == .travel)
        for (id, home) in [(ResidentID.a, homes.a), (.b, homes.b)] {
            let snap = windows.first { $0.id == home }!
            let offset = referenceHomeOffset(snap, ledges: w.surfaces)!
            let expectedAttachment: CoreAttachment = .window(home, offset: offset)
            #expect(w.residents[id]?.attachment == expectedAttachment)
            #expect(w.residents[id]?.state == .idle)
        }
    }

    // Feature: v1, Property 27: 家的选择
    // **Validates: Requirements 15.1, 15.2, 15.3, 15.4**
    @Test func homeSelection() async {
        await propertyCheck(count: 100, input: Gen.homeCase) { c in
            var constants = Tunables()
            constants.minWindowSize = c.minSize
            let ledges = SurfaceBuilder.build(windows: c.windows, planks: [], screen: c.screen)

            // 1. selectHomes 与暴力枚举一致
            let actual = StoryDirector.selectHomes(windows: c.windows, ledges: ledges, minSize: c.minSize)
            let expected = Self.referenceHomes(c.windows, ledges: ledges, minSize: c.minSize)
            #expect(actual?.a == expected?.a && actual?.b == expected?.b,
                    "actual \(String(describing: actual)), expected \(String(describing: expected))")
            if let h = expected {
                let fa = c.windows.first { $0.id == h.a }!.frame.midX
                let fb = c.windows.first { $0.id == h.b }!.frame.midX
                #expect(fa <= fb)
            }

            // 2. 首次开局：一次 update 后落位与阶段符合参考
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var w = WorldState(screen: c.screen)
            Self.setWindows(&w, c.windows, constants: constants)
            var s = StoryState()
            StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: 1.0 / 30)
            Self.checkBegin(s, w, windows: c.windows, minSize: c.minSize)

            // 3. 先只有前几个窗口（多半不足两个候选，在 Ground 上等），全部窗口出现后同一次 update 内开局
            var w2 = WorldState(screen: c.screen)
            let early = Array(c.windows.prefix(c.prefixCount))
            Self.setWindows(&w2, early, constants: constants)
            var s2 = StoryState()
            StoryDirector.update(&s2, world: &w2, constants: constants, now: now, dt: 1.0 / 30)
            Self.checkBegin(s2, w2, windows: early, minSize: c.minSize)
            if s2.stage == nil {
                Self.setWindows(&w2, c.windows, constants: constants)
                StoryDirector.update(&s2, world: &w2, constants: constants,
                                     now: now.addingTimeInterval(1.0 / 30), dt: 1.0 / 30)
                Self.checkBegin(s2, w2, windows: c.windows, minSize: c.minSize)
            }
        }
    }
}

// MARK: - Property 28：剧情阶段与可达性一致

/// 剧情模拟中的一次操作，后接若干帧推进。
private struct StoryOp: Sendable, CustomStringConvertible {
    var kind: Int
    var index: Int
    var a: Int
    var b: Int
    var frames: Int

    static let names = ["move", "move", "connect", "connect", "plank", "plank", "hide", "show", "close", "wait"]

    var description: String {
        "\(Self.names[kind])(w\(index), \(a), \(b)) + \(frames)f"
    }
}

private extension Gen where Value == StoryOp {
    static var storyOps: Generator<[StoryOp], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...(StoryOp.names.count - 1)),
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: -12...12),
            Gen<Int>.int(in: -12...12),
            Gen<Int>.int(in: 1...20)
        ).map { StoryOp(kind: $0, index: $1, a: $2, b: $3, frames: $4) }
            .array(of: 1...12)
    }
}

struct StoryReachabilityTests {
    static let screen = ResidentTests.screen
    static let dt = ResidentTests.dt

    /// 加快行走，缩短生长、种花和轮次间隔，让一次模拟能跑过 Growing、ReturnGift、Done 并进入第 2 轮（角色互换）。
    static var constants: Tunables {
        var c = Tunables()
        c.walkSpeed = 240
        c.plantAnimationDuration = 0.5
        c.bloomDuration = 1
        c.roundInterval = 1
        return c
    }

    /// 对假窗口源或引擎执行一个操作。`connect` 把下一个窗口移到与当前窗口首尾相接、上沿同高（产生行走边）；
    /// `plank` 在当前窗口右上角与下一个窗口左上角之间架木板（超长或过陡时下一帧失效下落）；
    /// 关闭只在 |a| 较大时发生，避免窗口过早全部消失。
    fileprivate static func apply(_ op: StoryOp, source: inout FakeWindowSource, engine: WorldEngine) {
        let ids = source.windows.map(\.snapshot.id).sorted()
        guard !ids.isEmpty else { return }
        let i = op.index % ids.count
        let id = ids[i]
        let next = ids.count > 1 ? ids[(i + 1) % ids.count] : nil
        guard let f = source.window(id)?.snapshot.frame else { return }
        switch op.kind {
        case 0, 1:
            source.move(id, to: Point(x: f.minX + Double(op.a) * 8, y: min(max(f.minY + Double(op.b) * 4, 40), 760)))
        case 2, 3:
            guard let n = next else { return }
            source.move(n, to: Point(x: f.maxX, y: f.minY))
        case 4, 5:
            guard let n = next else { return }
            engine.insertPlank(.placed(PlacedPlank(
                id: PlankID(0), endA: PlankEnd(window: id, offset: f.width), endB: PlankEnd(window: n, offset: 0))))
        case 6:
            source.hide(id)
        case 7:
            source.show(id)
        case 8:
            if abs(op.a) >= 9 { source.close(id) } else { source.show(id) }
        default:
            break
        }
    }

    /// 居民在 `world` 中的位置（StoryDirector 的定位规则：下落、悬挂、隐藏窗口或梯子上时为 nil）。
    static func location(_ id: ResidentID, _ world: WorldState) -> ResidentLocation? {
        StoryDirector.location(id, world: world, ctx: StoryDirector.context(world, constants))
    }

    static func airborne(_ r: Resident?) -> Bool {
        r?.state == .falling || r?.state == .hanging
    }

    /// 一次 step 结束时检查 Property 28 及相关的剧情约束。`prev` 为 step 之前的世界。返回违规描述。
    ///
    /// 剧情在居民移动之前判定可达性；居民在同一 step 稍后才落地或结束动作时，阶段要到下一帧才跟上
    /// （Requirement 20.2「落地后的下一帧」）。因此可达性一致只在 step 前后两人都能定位、都不在下落或悬挂中时检查。
    static func violation(prev: WorldState, now w: WorldState) -> String? {
        let s = w.story
        let g = s.giver, r = s.receiver
        guard let stage = s.stage, let gr = w.residents[g], let rr = w.residents[r] else { return nil }
        let sameRound = prev.story.round == s.round

        // 目标分配（Requirement 16.3、16.5、16.6、18.2、18.5、20.4）。
        switch stage {
        case .wish, .waiting, .travel, .planting:
            if gr.goal != .reach(r) || rr.goal != .confined { return "\(stage): goals g \(gr.goal) r \(rr.goal)" }
        case .returnGift:
            if rr.goal != .reach(g) || gr.goal != .confined { return "returnGift: goals g \(gr.goal) r \(rr.goal)" }
        default:
            break
        }

        // 许愿气泡（Requirement 16.2）：Wish、Waiting 中显示，Travel 中不显示。
        if stage == .wish || stage == .waiting, gr.bubble != .wish(receiver: r) {
            return "\(stage): giver bubble \(String(describing: gr.bubble))"
        }
        if stage == .travel, case .wish? = gr.bubble { return "travel: wish bubble still shown" }

        // 非送礼一方只在当前 Surface 内 idle / walking（Requirement 16.8、18.3）。
        let confined: Resident? = switch stage {
        case .wish, .waiting, .travel: rr
        case .returnGift: gr
        default: nil
        }
        if let c = confined {
            if c.route != nil || c.traversal != nil { return "\(stage): confined \(c.id) uses edges" }
            if ![.idle, .walking, .falling, .hanging].contains(c.state) {
                return "\(stage): confined \(c.id) in state \(c.state)"
            }
        }

        // 送礼方下落或悬挂期间阶段和持有物不变（Requirement 20.1）。
        if sameRound, let ps = prev.story.stage, [.waiting, .travel, .returnGift].contains(ps) {
            let carrier = ps == .returnGift ? r : g
            if airborne(prev.residents[carrier]), airborne(w.residents[carrier]) {
                if stage != ps { return "carrier \(carrier) airborne but stage \(ps) -> \(stage)" }
                if prev.residents[carrier]?.heldItem != w.residents[carrier]?.heldItem {
                    return "carrier \(carrier) airborne but held item changed"
                }
            }
        }

        // 阶段与可达性一致（Requirement 16.3、16.4、16.5、16.7、20.2）。
        guard [.wish, .waiting, .travel].contains(stage) else { return nil }
        guard sameRound, !airborne(prev.residents[g]), !airborne(prev.residents[r]),
              !airborne(gr), !airborne(rr),
              let pgl = location(g, prev), let prl = location(r, prev),
              let gl = location(g, w), let rl = location(r, w) else { return nil }
        if stage == .wish { return "still in wish although both residents are locatable" }
        // 剧情在居民移动之前判定；居民在本次 step 的移动中换了 Surface（例如通路已断但已开始的小跳在本帧落地），
        // 阶段按移动前的位置判定，下一帧才跟上。
        guard pgl.surface == gl.surface, prl.surface == rl.surface else { return nil }
        let reachable = w.nav.isReachable(from: gl.surface, to: rl.surface)
        if (stage == .travel) != reachable {
            return "stage \(stage) but reachable = \(reachable): giver \(gl) receiver \(rl)"
        }
        return nil
    }

    // Feature: v1, Property 28: 剧情阶段与可达性一致
    // **Validates: Requirements 16.3, 16.4, 16.5, 16.7, 20.2**
    @Test func storyStageMatchesReachability() async {
        await propertyCheck(
            count: 100,
            input: ResidentTests.windowSpecs,
            Gen<Int>.int(in: 0...1_000_000),
            Gen.storyOps
        ) { specs, seed, ops in
            let windows = ResidentTests.makeWindows(specs)
            var now = Date(timeIntervalSince1970: 3_000_000)
            let engine = WorldEngine(
                constants: Self.constants, clockStart: now, screen: Self.screen,
                rng: RandomSource(seed: UInt64(seed)), story: true)
            var source = FakeWindowSource(snapshots: windows)

            func step(_ label: String) -> Bool {
                let prev = engine.state
                now = now.addingTimeInterval(Self.dt)
                // V2（design.md「v1 属性的调整」）：剧情不再自动开局和换轮。没有进行中的送花时触发送花，
                // 让模拟仍能跑过多轮（角色互换）；其他 Wish 进行中时触发不生效。
                let commands: [Command] = engine.state.story.stage == nil ? [.triggerWish(.flower, nil)] : []
                engine.step(FrameInput(poll: source.poll(), screen: Self.screen, commands: commands, now: now))
                if let v = Self.violation(prev: prev, now: engine.state) {
                    Issue.record("\(label): \(v)")
                    return false
                }
                return true
            }

            guard step("initial") else { return }
            #expect(engine.state.story.stage != nil, "two windows are always eligible at start")
            for (n, op) in ops.enumerated() {
                Self.apply(op, source: &source, engine: engine)
                for f in 0 ..< op.frames {
                    guard step("op \(n) \(op) frame \(f)") else { return }
                }
            }
            // 收尾：不再操作，让剧情沿当前布局继续推进一段时间。
            for f in 0 ..< 90 {
                guard step("settle frame \(f)") else { return }
            }
        }
    }
}

// MARK: - Property 29：种花中断

/// 种花中断的测试输入。
/// - `layout` 0：两个窗口首尾相接、上沿同高，两人在窗口 2 的窗沿上种花；
///   `layout` 1：两个窗口之间架木板，嘟嘟先被放到木板上，两人在木板上种花。
/// - `op`：0 关闭窗口 2；1 用前方新窗口完全遮住窗口 2 的上沿；2 关闭窗口 1；3 把窗口 2 向右拉开 200pt（木板跨度必超过 Plank_Max_Span）；4 隐藏窗口 2。
///   布局 0 中两人站在窗口 2 上，0、1 让两人下落；2、3 不影响两人，因此改为 0、1（见 `effectiveOp`）。
///   布局 1 中 0 至 3 都让木板失效、两人悬挂。4 只暂停计时，不中止。
private struct PlantingCase: Sendable, CustomStringConvertible {
    var layout: Int
    var op: Int
    var progressFrames: Int
    var x1: Int
    var y1: Int
    var gap: Int
    var rise: Int
    var seed: Int

    var effectiveOp: Int { layout == 0 && (op == 2 || op == 3) ? op - 2 : op }

    var description: String {
        "layout \(layout) op \(effectiveOp) after \(progressFrames)f, w1 (\(x1), \(y1)) gap \(gap) rise \(rise) seed \(seed)"
    }
}

private extension Gen where Value == PlantingCase {
    static var plantingCase: Generator<PlantingCase, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...1),
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: 0...50),
            Gen<Int>.int(in: 8...38),
            Gen<Int>.int(in: 38...62),
            Gen<Int>.int(in: 5...15),
            Gen<Int>.int(in: -4...4),
            Gen<Int>.int(in: 0...1_000_000)
        ).map { layout, op, k, x, y, gap, rise, seed in
            // 坐标对齐 8pt：窗口 1 左上角 x 64…304、y 304…496；木板间隙 40…120pt、高差 −32…32pt。
            PlantingCase(layout: layout, op: op, progressFrames: k, x1: x * 8, y1: y * 8,
                         gap: gap * 8, rise: rise * 8, seed: seed)
        }
    }
}

struct PlantingInterruptTests {
    static let screen = StoryExampleTests.screen
    static let dt = StoryExampleTests.dt
    static let size = 200.0

    /// 加快行走，让 Giver 很快走到 Receiver 身边；种花动画保持默认 2 秒（60 帧），便于在动画中途打断。
    static var constants: Tunables {
        var c = Tunables()
        c.walkSpeed = 160
        return c
    }

    static func win(_ id: WindowID, x: Double, y: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: size, height: size), zIndex: 0)
    }

    /// 场上已附着（种下或放下）的 Flower 数量。
    static func attachedFlowers(_ w: WorldState) -> Int {
        w.items.items.values.filter { item in
            guard item.kind.isFlower else { return false }
            if case .attached = item.placement { return true }
            return false
        }.count
    }

    // Feature: v1, Property 29: 种花中断
    // **Validates: Requirements 16.13, 20.5**
    @Test func plantingInterruptedByHangOrFall() async {
        await propertyCheck(count: 100, input: Gen.plantingCase) { c in
            let x1 = Double(c.x1), y1 = Double(c.y1)
            let x2 = c.layout == 0 ? x1 + Self.size : x1 + Self.size + Double(c.gap)
            let y2 = c.layout == 0 ? y1 : y1 + Double(c.rise)
            var source = FakeWindowSource(snapshots: [Self.win(1, x: x1, y: y1), Self.win(2, x: x2, y: y2)])
            var now = Date(timeIntervalSince1970: 1_900_000_000)
            let engine = WorldEngine(
                constants: Self.constants, clockStart: now, screen: Self.screen,
                rng: RandomSource(seed: UInt64(c.seed)), story: true)

            var started = false
            func step() {
                now = now.addingTimeInterval(Self.dt)
                // V2：第一帧分配家后由「触发心愿」开始送花（design.md「v1 属性的调整」）。
                let commands: [Command] = started ? [] : [.triggerWish(.flower, nil)]
                started = true
                engine.step(FrameInput(poll: source.poll(), screen: Self.screen, commands: commands, now: now))
                let v = engine.invariantViolations()
                #expect(v.isEmpty, "\(c): \(v)")
            }
            func run(max frames: Int, until done: () -> Bool) -> Bool {
                for _ in 0 ..< frames {
                    if done() { return true }
                    step()
                }
                return done()
            }
            var story: StoryState { engine.state.story }

            // 1. 开局，布局 1 架木板并把嘟嘟放到木板中点。
            if c.layout == 1 {
                engine.insertPlank(.placed(PlacedPlank(
                    id: PlankID(0), endA: PlankEnd(window: 1, offset: Self.size),
                    endB: PlankEnd(window: 2, offset: 0))))
            }
            step()
            #expect(story.homes == [.a: 1, .b: 2], "\(c)")
            if c.layout == 1, let pid = engine.state.planks.placedPlanks.first?.id,
               var b = engine.state.residents[.b] {
                b.attachment = .plank(pid, t: 0.5)
                b.state = .idle
                b.route = nil
                b.traversal = nil
                b.fall = nil
                b.wander = WanderState()
                engine.place(b)
            }

            // 2. 推进到 Planting，再推进随机帧数（动画仍未结束）。
            guard run(max: 900, until: { story.stage == .planting }) else {
                Issue.record("\(c): never reached planting, stage \(String(describing: story.stage))"); return
            }
            for _ in 0 ..< c.progressFrames { step() }
            guard story.stage == .planting else {
                Issue.record("\(c): left planting early: \(String(describing: story.stage))"); return
            }
            let g = story.giver, r = story.receiver
            let flower = story.currentFlower
            #expect(flower != nil && engine.state.residents[g]?.heldItem == flower, "\(c)")
            #expect(Self.attachedFlowers(engine.state) == 0, "\(c)")

            // 3. 施加操作。
            let f2 = source.window(2)!.snapshot.frame
            switch c.effectiveOp {
            case 0:
                source.close(2)
            case 1:
                source.addInFront(WindowSnapshot(
                    id: 3, ownerName: "Cover", ownerPID: 1,
                    frame: Rect(minX: f2.minX - 16, minY: f2.minY - 40, width: f2.width + 32, height: 160),
                    zIndex: 0))
            case 2:
                source.close(1)
            case 3:
                source.move(2, to: Point(x: f2.minX + 200, y: f2.minY))
            default:
                source.hide(2)
            }

            if c.effectiveOp == 4 {
                // 隐藏窗口：暂停计时，不中止（Requirement 16.14）。
                step()
                let paused = story.plantingElapsed
                for _ in 0 ..< 30 {
                    step()
                    #expect(story.stage == .planting, "\(c)")
                    #expect(story.plantingElapsed == paused, "\(c)")
                    #expect(engine.state.residents[g]?.state == .planting, "\(c)")
                    #expect(engine.state.residents[r]?.state == .planting, "\(c)")
                    #expect(engine.state.residents[g]?.heldItem == flower, "\(c)")
                }
                source.show(2)
                #expect(run(max: 90, until: { story.stage == .growing }), "\(c): did not resume")
                return
            }

            // 中断：同一次 step 结束时回到 Travel，花仍是 Giver 手上未种下的花盆。
            step()
            let w = engine.state
            let states = [w.residents[g]?.state, w.residents[r]?.state]
            #expect(states.contains(.hanging) || states.contains(.falling), "\(c): states \(states)")
            #expect(story.stage == .travel, "\(c): stage \(String(describing: story.stage))")
            #expect(story.plantingElapsed == 0, "\(c)")
            #expect(story.currentFlower == flower, "\(c)")
            #expect(w.residents[g]?.heldItem == flower, "\(c)")
            if let id = flower, let item = w.items[id] {
                if case .held(g) = item.placement {} else { Issue.record("\(c): flower placement \(item.placement)") }
                #expect(item.growth?.plantedAt == nil, "\(c)")
                #expect(item.stage == .pot, "\(c)")
            } else {
                Issue.record("\(c): flower missing")
            }
            #expect(Self.attachedFlowers(w) == 0, "\(c): a flower got attached")
            for id in [g, r] {
                #expect(w.residents[id]?.state != .planting, "\(c): \(id) still planting")
            }
        }
    }
}

// MARK: - Property 31：快进

/// 场上一朵已有的花：种下时间相对 `now` 的偏移（毫秒，nil 为未种下）、已记录的阶段、所属轮次。
private struct FFFlower: Sendable, CustomStringConvertible {
    var plantedOffsetMs: Int?
    var reached: Int
    var round: Int

    var description: String {
        "flower(planted \(plantedOffsetMs.map { "\($0)ms" } ?? "nil"), reached \(reached), round \(round))"
    }
}

/// 快进的测试输入。`stageIndex` 0…7 取 `StoryStage.allCases` 下标，8 为未开局；
/// 9…12 为 `Growing`、13…14 为 `Done`，加重这两个会被快进改变的阶段的比重。
private struct FastForwardCase: Sendable, CustomStringConvertible {
    var stageIndex: Int
    var touching: Bool
    var round: Int
    var bloomIndex: Int
    var nowMs: Int
    var doneAtOffsetMs: Int
    var flowers: [FFFlower]
    var fruits: Int
    var currentIndex: Int

    static let bloomChoices: [Double] = [1, 60, 180, 600]

    var stage: StoryStage? {
        let n = StoryStage.allCases.count
        if stageIndex < n { return StoryStage.allCases[stageIndex] }
        if stageIndex == n { return nil }
        return stageIndex <= n + 4 ? .growing : .done
    }
    var bloom: Double { Self.bloomChoices[bloomIndex] }

    var description: String {
        "stage \(String(describing: stage)) touching \(touching) round \(round) B \(bloom) now +\(nowMs)ms "
            + "doneAt \(doneAtOffsetMs)ms flowers \(flowers) fruits \(fruits) current \(currentIndex)"
    }
}

private extension Gen where Value == FastForwardCase {
    static var fastForwardCase: Generator<FastForwardCase, some SendableSequenceType> {
        let flower = zip(
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: -900_000...1_000),
            Gen<Int>.int(in: 0...2),
            Gen<Int>.int(in: 1...6)
        ).map { planted, offset, reached, round in
            FFFlower(plantedOffsetMs: planted == 0 ? nil : offset, reached: reached, round: round)
        }
        return zip(
            Gen<Int>.int(in: 0...(StoryStage.allCases.count + 6)),
            Gen<Bool>.bool,
            Gen<Int>.int(in: 1...7),
            Gen<Int>.int(in: 0...(FastForwardCase.bloomChoices.count - 1)),
            Gen<Int>.int(in: 0...10_000_000),
            Gen<Int>.int(in: -300_000...60_000),
            flower.array(of: 0...6),
            Gen<Int>.int(in: 0...3),
            Gen<Int>.int(in: 0...10)
        ).map { s, t, r, b, now, done, flowers, fruits, cur in
            FastForwardCase(stageIndex: s, touching: t, round: r, bloomIndex: b, nowMs: now,
                            doneAtOffsetMs: done, flowers: flowers, fruits: fruits, currentIndex: cur)
        }
    }
}

struct FastForwardTests {
    static let screen = StoryExampleTests.screen

    /// 构造指定阶段的剧情状态和世界：两人在各自家窗口上（窗口相接时互相可达），
    /// 场上有任意数量、任意种下时间的花和若干果子（附着在 Ground 上）。
    /// `Growing` 时当前轮的花是其中一朵已种下的花；`Done` 时两人空手且 `doneAt` 为任意时间。
    fileprivate static func build(_ c: FastForwardCase, now: Date) -> (StoryState, WorldState, Tunables) {
        var constants = Tunables()
        constants.bloomDuration = c.bloom
        let windows = c.touching ? StoryExampleTests.touching : StoryExampleTests.apart
        var w = WorldState(screen: screen)
        StoryDirectorTests.setWindows(&w, windows, constants: constants)
        var s = StoryState(round: c.round)
        StoryDirector.tryBegin(&s, world: &w, constants: constants, now: now)

        func addItem(_ item: Item) { w.items[item.id] = item }
        var x = 40.0
        func groundSpot() -> CoreAttachment {
            x += 20
            return .ground(x: x)
        }
        var planted: [ItemID] = []
        for f in c.flowers {
            let at = f.plantedOffsetMs.map { now.addingTimeInterval(Double($0) / 1000) }
            var reached = GrowthStage(rawValue: f.reached)!
            if let at {
                // 与正常运行一致：update 每帧推进生长，已记录阶段不低于按时间算出的阶段。
                reached = max(reached, Growth.stage(elapsed: now.timeIntervalSince(at), bloomDuration: c.bloom))
            } else {
                reached = .pot
            }
            let item = Item(kind: .flower(storyRound: f.round), placement: .attached(groundSpot()),
                            growth: FlowerGrowth(plantedAt: at, reached: reached))
            addItem(item)
            if at != nil { planted.append(item.id) }
        }
        for _ in 0 ..< c.fruits { addItem(.fruit(placement: .attached(groundSpot()))) }

        func dropHeld() {
            for id in [ResidentID.a, .b] {
                if let held = w.residents[id]?.heldItem { w.items[held] = nil }
                w.residents[id]?.heldItem = nil
            }
            s.currentFlower = nil
        }

        let stage = c.stage
        switch stage {
        case .growing?:
            dropHeld()
            if planted.isEmpty {
                let at = now.addingTimeInterval(-Double(c.nowMs % 1000) / 1000 * c.bloom)
                let item = Item(kind: .flower(storyRound: s.round), placement: .attached(groundSpot()),
                                growth: FlowerGrowth(plantedAt: at, reached: Growth.stage(
                                    elapsed: now.timeIntervalSince(at), bloomDuration: c.bloom)))
                addItem(item)
                planted.append(item.id)
            }
            s.currentFlower = planted[c.currentIndex % planted.count]
            s.stage = .growing
        case .done?:
            dropHeld()
            s.stage = .done
            s.doneAt = now.addingTimeInterval(Double(c.doneAtOffsetMs) / 1000)
            s.currentFruit = w.items.sortedIDs.first { w.items[$0]?.kind == .fruit }
        case .returnGift?, .bloomed?:
            dropHeld()
            let fruit = Item.fruit(placement: .held(s.receiver))
            StoryDirector.forceGive(fruit, to: s.receiver, world: &w)
            s.currentFruit = fruit.id
            s.stage = stage
        case nil:
            dropHeld()
            s.stage = nil
        default:
            s.stage = stage
        }
        StoryDirector.assignGoals(s, world: &w)
        return (s, w, constants)
    }

    static func next(_ g: GrowthStage) -> GrowthStage {
        GrowthStage(rawValue: min(g.rawValue + 1, GrowthStage.bloom.rawValue))!
    }

    // Feature: v1, Property 31: 快进
    // **Validates: Requirements 17.5, 17.7**
    @Test func fastForward() async {
        await propertyCheck(count: 100, input: Gen.fastForwardCase) { c in
            let now = Date(timeIntervalSince1970: 1_800_000_000 + Double(c.nowMs) / 1000)
            var (s, w, constants) = Self.build(c, now: now)
            let before = s
            let itemsBefore = w.items.items
            let residentsBefore = w.residents
            let events = StoryDirector.fastForward(&s, world: &w, constants: constants, now: now)

            switch before.stage {
            case .growing?:
                let id = before.currentFlower!
                let old = itemsBefore[id]!.growth!
                let new = w.items[id]!.growth!
                let expected = Self.next(old.reached)
                // 恰好进入下一个阶段；已是 bloom 时不变。
                #expect(new.reached == expected, "\(c): \(old.reached) -> \(new.reached)")
                if old.reached == .bloom {
                    #expect(new == old, "\(c)")
                    #expect(events.isEmpty, "\(c)")
                } else {
                    // 快进后已生长时长等于新阶段的起点（时钟本身不变，只前移种下时间）。
                    let start = expected == .sprout ? 0.5 * c.bloom : c.bloom
                    let elapsed = now.timeIntervalSince(new.plantedAt!)
                    #expect(abs(elapsed - start) < 1e-3, "\(c): elapsed \(elapsed), expected \(start)")
                    #expect(Growth.stage(elapsed: elapsed, bloomDuration: c.bloom) == expected, "\(c)")
                    let event: StoryEvent = expected == .bloom ? .bloomed(flower: id) : .sprouted(flower: id)
                    #expect(events == [event], "\(c): \(events)")
                }
                // 剧情阶段不变，其他花和果子不受影响。
                #expect(s == before, "\(c)")
                var others = w.items.items
                var othersBefore = itemsBefore
                others[id] = nil
                othersBefore[id] = nil
                #expect(others == othersBefore, "\(c)")
                #expect(w.residents == residentsBefore, "\(c)")

                // 下一次 update（时钟不变）按正常路径推进：花已开则进入 Bloomed → ReturnGift，否则仍为 Growing。
                StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: 1.0 / 30)
                #expect(s.stage == (expected == .bloom ? .returnGift : .growing), "\(c): \(String(describing: s.stage))")
                #expect(w.items[id]?.growth?.reached == expected, "\(c)")

            case .done?:
                // 等待立即结束，按正常路径开始下一轮，角色互换。
                #expect(s.round == before.round + 1, "\(c)")
                #expect(s.giver == before.receiver && s.receiver == before.giver, "\(c)")
                #expect(events.contains(.roundStarted(round: before.round + 1, giver: before.receiver,
                                                      receiver: before.giver)), "\(c): \(events)")
                let ctx = StoryDirector.context(w, constants)
                let gl = StoryDirector.location(s.giver, world: w, ctx: ctx)!
                let rl = StoryDirector.location(s.receiver, world: w, ctx: ctx)!
                let reachable = w.nav.isReachable(from: gl.surface, to: rl.surface)
                #expect(s.stage == (reachable ? .travel : .waiting), "\(c): \(String(describing: s.stage))")
                // 新一轮的花盆在新 Giver 手上，尚未种下。
                let flower = s.currentFlower.flatMap { w.items[$0] }
                #expect(flower?.placement == .held(s.giver), "\(c)")
                #expect(flower?.growth == FlowerGrowth(), "\(c)")
                #expect(flower?.kind == .flower(storyRound: s.round), "\(c)")
                // 之前的花和果子全部保留，数量、位置和阶段不变。
                var rest = w.items.items
                if let f = s.currentFlower { rest[f] = nil }
                #expect(rest == itemsBefore, "\(c)")

            default:
                // 其他阶段（含未开局）：任何花的阶段和 Story_Stage 都不变。
                #expect(events.isEmpty, "\(c): \(events)")
                #expect(s == before, "\(c)")
                #expect(w.items.items == itemsBefore, "\(c)")
                #expect(w.residents == residentsBefore, "\(c)")
            }
        }
    }
}

// MARK: - Property 33：花数上限

/// 花数上限的测试输入：Max_Story_Flowers、轮数、每轮种下时间（相对基准的秒数，可乱序、可重复），
/// 以及场上预先放置的非剧情花（调试花盆，可带种下时间）数量。
private struct FlowerCapCase: Sendable, CustomStringConvertible {
    var maxFlowers: Int
    var plantOffsets: [Int]
    var debugPots: [Int?]

    var description: String {
        "max \(maxFlowers) rounds \(plantOffsets.count) plantedAt \(plantOffsets) debugPots \(debugPots)"
    }
}

private extension Gen where Value == FlowerCapCase {
    static var flowerCapCase: Generator<FlowerCapCase, some SendableSequenceType> {
        let debugPot = zip(Gen<Bool>.bool, Gen<Int>.int(in: -500...500)).map { has, t in has ? t : nil }
        return zip(
            Gen<Int>.int(in: 1...8),
            // 小范围制造相同种下时间，检验并列时的确定性。
            Gen<Int>.int(in: -40...40).array(of: 1...14),
            debugPot.array(of: 0...2)
        ).map { m, offsets, pots in
            FlowerCapCase(maxFlowers: m, plantOffsets: offsets, debugPots: pots)
        }
    }
}

struct FlowerCapTests {
    static let screen = StoryExampleTests.screen
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// 已种下的 Story_Flower 按（种下时间、ID）升序排列。
    static func plantedStoryFlowers(_ w: WorldState) -> [ItemID] {
        w.items.items.values
            .filter { $0.kind.isStoryFlower && $0.growth?.plantedAt != nil }
            .sorted { a, b in
                let ta = a.growth!.plantedAt!, tb = b.growth!.plantedAt!
                return ta != tb ? ta < tb : a.id < b.id
            }
            .map(\.id)
    }

    // Feature: v1, Property 33: 花数上限
    // **Validates: Requirements 19.3, 19.4**
    @Test func flowerCap() async {
        await propertyCheck(count: 100, input: Gen.flowerCapCase) { c in
            var constants = Tunables()
            constants.maxStoryFlowers = c.maxFlowers
            var w = WorldState(screen: Self.screen)
            StoryDirectorTests.setWindows(&w, StoryExampleTests.touching, constants: constants)
            var s = StoryState(round: 1)
            StoryDirector.tryBegin(&s, world: &w, constants: constants, now: Self.base)
            #expect(s.stage != nil, "\(c): story did not begin")

            // 非剧情花（调试花盆）不计入上限，也不会被移除。
            var debugIDs: [ItemID] = []
            for (i, t) in c.debugPots.enumerated() {
                let pot = Item(kind: .flower(storyRound: nil), placement: .attached(.ground(x: 60 + Double(i) * 24)),
                               growth: FlowerGrowth(plantedAt: t.map { Self.base.addingTimeInterval(Double($0)) }))
                w.items[pot.id] = pot
                debugIDs.append(pot.id)
            }

            // 参考模型：全部种下过的 Story_Flower（ID、种下时间）。
            var allPlanted: [(id: ItemID, at: Date)] = []
            var fruits: [ItemID] = []

            for (i, offset) in c.plantOffsets.enumerated() {
                let k = i + 1
                let now = Self.base.addingTimeInterval(Double(offset))

                // 送达后进入 Planting，动画结束时种下（正常路径 completePlanting，含移除最早的花）。
                guard let flowerID = s.currentFlower else {
                    Issue.record("\(c): round \(k) has no current flower")
                    return
                }
                s.stage = .planting
                let itemsBefore = w.items.items
                _ = StoryDirector.completePlanting(&s, world: &w, constants: constants, now: now)
                #expect(s.stage == .growing, "\(c): round \(k) stage \(String(describing: s.stage))")
                allPlanted.append((flowerID, now))

                // 场上 Story_Flower 数量为 min(k, Max)，保留的是种下时间最晚的那些。
                let expected = allPlanted
                    .sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
                    .suffix(c.maxFlowers)
                    .map(\.id)
                let actual = Self.plantedStoryFlowers(w)
                #expect(actual.count == min(k, c.maxFlowers), "\(c): round \(k) count \(actual.count)")
                #expect(actual == Array(expected), "\(c): round \(k) kept \(actual) expected \(Array(expected))")

                // 其余物件（未被移除的花、全部果子、调试花盆）不受影响。
                for (id, item) in itemsBefore where id != flowerID && w.items[id] != nil {
                    #expect(w.items[id] == item, "\(c): round \(k) item \(id) changed")
                }
                for id in fruits { #expect(w.items[id] != nil, "\(c): round \(k) fruit \(id) removed") }
                for id in debugIDs { #expect(w.items[id] == itemsBefore[id], "\(c): round \(k) debug pot changed") }

                // 花开后 Receiver 拿到果子，送到 Giver 处（这里直接放到 Ground 上），进入 Done。
                _ = StoryDirector.enterBloomed(&s, world: &w)
                guard let fruitID = s.currentFruit, var receiver = w.residents[s.receiver] else {
                    Issue.record("\(c): round \(k) no fruit")
                    return
                }
                _ = w.items.release(from: &receiver, to: .attached(.ground(x: 400 + Double(k) * 18)))
                w.residents[s.receiver] = receiver
                fruits.append(fruitID)
                s.stage = .done
                s.doneAt = now

                // 新一轮开始前后，已有 Story_Flower 和 Fruit 的数量、Attachment 和 Growth_Stage 都不变。
                let beforeRound = w.items.items
                StoryDirector.startRound(&s, round: s.round + 1, world: &w, constants: constants)
                #expect(s.round == k + 1, "\(c)")
                var rest = w.items.items
                if let f = s.currentFlower { rest[f] = nil }
                #expect(rest == beforeRound, "\(c): round \(k + 1) start changed existing items")
                #expect(w.items.items.values.filter { $0.kind == .fruit }.count == k, "\(c): fruits after round \(k)")
            }
        }
    }
}

// MARK: - Property 34：重新开始剧情

/// 场上一件物件：种类（0 Story_Flower、1 调试花盆、2 Fruit）、位置（0 Ground、1 窗沿、2 下落、3 拖动、4 居民持有）、
/// 是否已种下（只对花有效）。
private struct RestartItemSpec: Sendable, CustomStringConvertible {
    var kind: Int
    var placement: Int
    var planted: Bool

    var description: String { "item(k\(kind) p\(placement)\(planted ? " planted" : ""))" }
}

/// 重新开始之前的一种剧情与世界状态（窗口、木板、梯子由 `RestartCase` 共享）。
/// `stageIndex` 0…7 取 `StoryStage.allCases` 下标，8 为未开局。
private struct RestartPreState: Sendable, CustomStringConvertible {
    var stageIndex: Int
    var round: Int
    var items: [RestartItemSpec]
    var stateA: Int
    var stateB: Int
    var gesture: Int
    var elapsedMs: Int

    var stage: StoryStage? {
        stageIndex < StoryStage.allCases.count ? StoryStage.allCases[stageIndex] : nil
    }

    var description: String {
        "stage \(String(describing: stage)) round \(round) states \(stateA)/\(stateB) gesture \(gesture) "
            + "elapsed \(elapsedMs)ms items \(items)"
    }
}

/// 重新开始剧情的测试输入：窗口布局、木板和梯子，以及两种不同的事前状态。
private struct RestartCase: Sendable, CustomStringConvertible {
    var layout: Int
    var planks: [Int]
    var ladders: [Int]
    var first: RestartPreState
    var second: RestartPreState

    var description: String {
        "layout \(layout) planks \(planks) ladders \(ladders)\n  first: \(first)\n  second: \(second)"
    }
}

private extension Gen where Value == RestartCase {
    static var restartCase: Generator<RestartCase, some SendableSequenceType> {
        let item = zip(Gen<Int>.int(in: 0...2), Gen<Int>.int(in: 0...4), Gen<Bool>.bool)
            .map { k, p, planted in RestartItemSpec(kind: k, placement: p, planted: planted) }
        let pre = zip(
            Gen<Int>.int(in: 0...StoryStage.allCases.count),
            Gen<Int>.int(in: 1...9),
            item.array(of: 0...8),
            Gen<Int>.int(in: 0...(ResidentState.allCases.count - 1)),
            Gen<Int>.int(in: 0...(ResidentState.allCases.count - 1)),
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: 0...5_000)
        ).map { s, r, items, a, b, g, e in
            RestartPreState(stageIndex: s, round: r, items: items, stateA: a, stateB: b, gesture: g, elapsedMs: e)
        }
        return zip(
            Gen<Int>.int(in: 0...(RestartTests.layouts.count - 1)),
            // 木板：0 已架设（窗口 1、2 之间，只在有这两个窗口时）、1 落在 Ground 上、2 下落中。
            Gen<Int>.int(in: 0...2).array(of: 0...3),
            // 梯子：0 落在 Ground 上、1 下落中。
            Gen<Int>.int(in: 0...1).array(of: 0...2),
            pre, pre
        ).map { l, p, ld, a, b in RestartCase(layout: l, planks: p, ladders: ld, first: a, second: b) }
    }
}

struct RestartTests {
    static let screen = StoryExampleTests.screen
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func win(_ id: WindowID, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WindowSnapshot {
        StoryExampleTests.win(id, x: x, y: y, w: w, h: h)
    }

    /// 窗口布局：无窗口、一个窗口、两个分开的窗口、两个相接的窗口、三个窗口（其一过小、不能当家）。
    static let layouts: [[WindowSnapshot]] = [
        [],
        [win(1, 100, 400, 200, 200)],
        StoryExampleTests.apart,
        StoryExampleTests.touching,
        [win(1, 100, 400, 200, 200), win(2, 400, 300, 200, 200), win(3, 900, 500, 130, 100)],
    ]

    /// 木板和梯子：两种事前状态共用同一组，重新开始后应保持不变。
    fileprivate static func structures(_ c: RestartCase) -> (PlankStore, LadderStore) {
        let windows = layouts[c.layout]
        let hasPair = windows.contains { $0.id == 1 } && windows.contains { $0.id == 2 }
        var planks = PlankStore()
        for (i, kind) in c.planks.enumerated() {
            let id = PlankID(UInt64(i + 1))
            switch kind {
            case 0 where hasPair:
                planks.planks[id] = .placed(PlacedPlank(
                    id: id, endA: PlankEnd(window: 1, offset: 190), endB: PlankEnd(window: 2, offset: 10)))
            case 2:
                planks.planks[id] = .falling(FallState(position: Point(x: 500 + Double(i) * 30, y: 100), velocityY: 50))
            default:
                planks.planks[id] = .loose(.ground(x: 700 + Double(i) * 30))
            }
        }
        planks.nextID = UInt64(c.planks.count + 1)
        var ladders = LadderStore()
        for (i, kind) in c.ladders.enumerated() {
            let id = LadderID(UInt64(i + 1))
            ladders.ladders[id] = kind == 0
                ? .loose(.ground(x: 1000 + Double(i) * 30))
                : .falling(FallState(position: Point(x: 1100 + Double(i) * 30, y: 50), velocityY: 0))
        }
        ladders.nextID = UInt64(c.ladders.count + 1)
        return (planks, ladders)
    }

    /// 构造一种事前状态：先按当前窗口开局，再改成任意阶段、轮次、居民状态和物件分布。
    fileprivate static func build(
        _ c: RestartCase, _ p: RestartPreState, constants: Tunables
    ) -> (StoryState, WorldState) {
        let windows = layouts[c.layout]
        let (planks, ladders) = structures(c)
        var w = WorldState(screen: screen, planks: planks, ladders: ladders)
        w.windows.apply(.success(eligible: windows, existingIDs: Set(windows.map(\.id))))
        let placed = planks.placedPlanks
        w.surfaces = SurfaceBuilder.build(windows: windows, planks: placed, screen: screen)
        w.nav = NavGraph.build(surfaces: w.surfaces, planks: placed, constants: constants)

        var s = StoryState(round: p.round)
        StoryDirector.tryBegin(&s, world: &w, constants: constants, now: now)

        var x = 40.0
        var dragged: ItemID?
        for (i, spec) in p.items.enumerated() {
            let kind: ItemKind = spec.kind == 0 ? .flower(storyRound: 1 + i % 3)
                : spec.kind == 1 ? .flower(storyRound: nil) : .fruit
            let growth: FlowerGrowth? = kind.isFlower
                ? FlowerGrowth(plantedAt: spec.planted ? now.addingTimeInterval(-Double(i) * 50) : nil,
                               reached: spec.planted ? GrowthStage(rawValue: i % 3)! : .pot)
                : nil
            x += 24
            let placement: ItemPlacement
            switch spec.placement {
            case 1 where !windows.isEmpty:
                placement = .attached(.window(windows[0].id, offset: Double(10 + 12 * i)))
            case 2:
                placement = .falling(FallState(position: Point(x: x, y: 200), velocityY: 100))
            case 3 where dragged == nil:
                placement = .dragged(grabOffset: Point(x: 3, y: 4))
            default:
                placement = .attached(.ground(x: x))
            }
            let item = Item(kind: kind, placement: placement, growth: growth)
            if spec.placement == 4 {
                // 交给还空手的一位居民；两人都已持有时放在 Ground 上。
                if let rid = [ResidentID.a, .b].first(where: { w.residents[$0]?.heldItem == nil }),
                   var r = w.residents[rid] {
                    w.items.give(item, to: &r)
                    w.residents[rid] = r
                    if spec.kind == 0 { s.currentFlower = item.id }
                    if spec.kind == 2 { s.currentFruit = item.id }
                    continue
                }
            }
            if case .dragged = placement { dragged = item.id }
            w.items[item.id] = item
        }

        s.stage = p.stage
        s.plantingElapsed = Double(p.elapsedMs) / 1000
        s.celebrateElapsed = Double(p.elapsedMs) / 2000
        s.heartRemaining = Double(p.elapsedMs % 2000) / 1000
        s.doneAt = p.stage == .done ? now.addingTimeInterval(-Double(p.elapsedMs) / 1000) : nil
        for (id, idx) in [(ResidentID.a, p.stateA), (.b, p.stateB)] {
            guard var r = w.residents[id] else { continue }
            r.state = ResidentState.allCases[idx]
            if r.state == .hanging { r.hangElapsed = Double(p.elapsedMs % 1500) / 1000 }
            if r.state == .falling || r.state == .hanging {
                let pos = AttachmentResolver.screenPosition(
                    r.attachment, windows: w.windows, planks: w.planks.lookup(windows: w.windows),
                    ladders: w.ladders.lookup(windows: w.windows), screen: screen) ?? Point(x: 300, y: 100)
                r.attachment = .free(pos)
                if r.state == .falling { r.fall = FallState(position: pos, velocityY: 30) }
            }
            r.bubble = idx % 2 == 0 ? .dots : .heart
            r.poke = idx % 3 == 0 ? PokeState(jumpRemaining: 0.2, bubbleRemaining: 1) : nil
            w.residents[id] = r
        }
        StoryDirector.assignGoals(s, world: &w)

        switch p.gesture {
        case 1: w.gesture = dragged.map { .dragging(.item($0), grabOffset: Point(x: 3, y: 4), pointer: Point(x: 500, y: 300)) } ?? .none
        case 2: w.gesture = w.items.sortedIDs.first.map { .pressed(on: .item($0), at: Point(x: 50, y: 800)) } ?? .none
        case 3: w.gesture = .dragging(.newPlank, grabOffset: Point(x: 0, y: 0), pointer: Point(x: 600, y: 400))
        case 4: w.gesture = .swallowed
        default: w.gesture = .none
        }
        return (s, w)
    }

    /// 与物件 ID、戳的状态无关的剧情结果，用于比较两种事前状态重新开始后的结果。
    static func normalized(_ s: StoryState, _ w: WorldState) -> (StoryState, [ResidentID: Resident], [Item]) {
        var story = s
        story.currentFlower = nil
        var residents = w.residents
        for id in residents.keys {
            residents[id]?.poke = nil
            if residents[id]?.heldItem != nil { residents[id]?.heldItem = ItemID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))) }
        }
        let items = w.items.items.values.map { item -> Item in
            var it = item
            it.id = ItemID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
            return it
        }
        return (story, residents, items)
    }

    /// 单次重新开始的检查，返回重新开始后的剧情和世界。
    fileprivate static func restartAndCheck(
        _ c: RestartCase, _ p: RestartPreState, constants: Tunables, label: String
    ) -> (StoryState, WorldState) {
        var (s, w) = build(c, p, constants: constants)
        let planksBefore = w.planks
        let laddersBefore = w.ladders
        let itemsBefore = Set(w.items.items.keys)
        let gestureBefore = w.gesture
        StoryDirector.restart(&s, world: &w, constants: constants, now: now)
        let ctx = "\(label) \(c)"

        // Plank 和 Ladder 原样保留。
        #expect(w.planks == planksBefore, "\(ctx)")
        #expect(w.ladders == laddersBefore, "\(ctx)")

        // 轮次重置为 1，Giver 为都都，Receiver 为嘟嘟；本轮的其他记录清空。
        #expect(s.round == 1, "\(ctx)")
        #expect(s.giver == .a && s.receiver == .b, "\(ctx)")
        #expect(s.currentFruit == nil && s.doneAt == nil && s.plantingElapsed == 0, "\(ctx)")

        // 家按当前窗口重新选择，居民落位与首次开局一致。
        let windows = layouts[c.layout]
        StoryDirectorTests.checkBegin(s, w, windows: windows, minSize: constants.minWindowSize)

        // 之前的全部 Flower 和 Fruit 都被删除；开局时只有新的第 1 轮花盆在都都手上。
        #expect(itemsBefore.isDisjoint(with: w.items.items.keys), "\(ctx): old items survived")
        if s.stage == nil {
            #expect(w.items.items.isEmpty, "\(ctx): \(w.items.items.values)")
            #expect(s.currentFlower == nil, "\(ctx)")
        } else {
            #expect(w.items.items.count == 1, "\(ctx): \(w.items.items.values)")
            let flower = s.currentFlower.flatMap { w.items[$0] }
            #expect(flower?.kind == .flower(storyRound: 1), "\(ctx)")
            #expect(flower?.placement == .held(.a), "\(ctx)")
            #expect(flower?.growth == FlowerGrowth(), "\(ctx)")
            #expect(w.residents[.a]?.heldItem == s.currentFlower, "\(ctx)")
        }
        #expect(w.residents[.b]?.heldItem == nil, "\(ctx)")
        for r in w.residents.values {
            if let held = r.heldItem { #expect(w.items[held] != nil, "\(ctx): dangling held item") }
            #expect(r.state == .idle, "\(ctx): \(r.id) \(r.state)")
        }

        // 被拖动或按下的物件已删除时，本次手势被吞掉；其他手势不变。
        switch gestureBefore {
        case .dragging(.item, _, _), .pressed(.item, _):
            #expect(w.gesture == .swallowed, "\(ctx): \(w.gesture)")
        default:
            #expect(w.gesture == gestureBefore, "\(ctx): \(w.gesture)")
        }
        return (s, w)
    }

    // Feature: v1, Property 34: 重新开始剧情
    // **Validates: Requirements 20.6**
    @Test func restartStory() async {
        await propertyCheck(count: 100, input: Gen.restartCase) { c in
            let constants = Tunables()
            let (s1, w1) = Self.restartAndCheck(c, c.first, constants: constants, label: "first")
            let (s2, w2) = Self.restartAndCheck(c, c.second, constants: constants, label: "second")

            // 两种只在剧情阶段、轮次、物件和居民状态上不同的事前状态，重新开始后得到相同的剧情状态。
            let n1 = Self.normalized(s1, w1), n2 = Self.normalized(s2, w2)
            #expect(n1.0 == n2.0, "\(c)\n  \(n1.0)\n  \(n2.0)")
            #expect(n1.1 == n2.1, "\(c)\n  \(n1.1)\n  \(n2.1)")
            #expect(n1.2 == n2.2, "\(c)")
        }
    }
}

// MARK: - Property 32：送花方轮换

/// 推进剧情的一步操作：
/// - `kind` 0：把本轮推进到 `Done` 后用「快进」开始下一轮；
/// - `kind` 1：把本轮推进到 `Done` 后等待 Round_Interval 自然开始下一轮（超过 Round_Interval 不到 1 秒时检查）；
/// - `kind` 2：先把本轮推进到 `saveStage`（0 当前阶段、1 `Growing`、2 `ReturnGift`、3 `Done`），
///   再保存 → 编码 → 解码 → 恢复到新的世界（以及新的 WorldEngine）。
private struct RotationOp: Sendable, CustomStringConvertible {
    var kind: Int
    var saveStage: Int
    var jitterMs: Int

    var description: String {
        switch kind {
        case 0: return "fastForward"
        case 1: return "natural(+\(jitterMs)ms)"
        default: return "saveRestore(at \(saveStage))"
        }
    }
}

private struct RotationCase: Sendable, CustomStringConvertible {
    var startRound: Int
    var ops: [RotationOp]

    var description: String { "start round \(startRound) ops \(ops)" }
}

private extension Gen where Value == RotationCase {
    static var rotationCase: Generator<RotationCase, some SendableSequenceType> {
        let op = zip(Gen<Int>.int(in: 0...2), Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...999))
            .map { k, s, j in RotationOp(kind: k, saveStage: s, jitterMs: j) }
        return zip(Gen<Int>.int(in: 1...12), op.array(of: 1...8))
            .map { n, ops in RotationCase(startRound: n, ops: ops) }
    }
}

struct GiverRotationTests {
    static let screen = StoryExampleTests.screen
    static let windows = StoryExampleTests.touching
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static var constants: Tunables {
        var c = Tunables()
        c.roundInterval = 10
        c.bloomDuration = 6
        return c
    }

    /// 参考规则：奇数轮 Resident_A，偶数轮 Resident_B（Requirement 19.5）。
    static func expectedGiver(_ n: Int) -> ResidentID { n % 2 == 1 ? .a : .b }

    /// 阶段在推进顺序中的位置：Wish / Waiting / Travel 为 0，Growing 为 1，ReturnGift 为 2，Done 为 3。
    static func order(_ stage: StoryStage?) -> Int {
        switch stage {
        case .growing?: return 1
        case .bloomed?, .returnGift?: return 2
        case .done?: return 3
        default: return 0
        }
    }

    /// 按正常路径把本轮推进到 `target`（同上编号）：种下 → 开花并拿到果子 → 果子送到 → Done。
    static func advance(
        _ s: inout StoryState, _ w: inout WorldState, to target: Int, now: Date, label: String
    ) {
        let c = constants
        while order(s.stage) < target {
            switch order(s.stage) {
            case 0:
                s.stage = .planting
                _ = StoryDirector.completePlanting(&s, world: &w, constants: c, now: now)
                #expect(s.stage == .growing, "\(label): planting did not complete")
                if s.stage != .growing { return }
            case 1:
                _ = StoryDirector.enterBloomed(&s, world: &w)
            default:
                if var r = w.residents[s.receiver], r.heldItem != nil {
                    _ = w.items.release(from: &r, to: .attached(.ground(x: 500)))
                    w.residents[s.receiver] = r
                }
                s.stage = .done
                s.doneAt = now
            }
        }
    }

    /// 新一轮开始后的检查：轮次加 1，角色互换并符合奇偶规则，新花盆在新 Giver 手上。
    static func checkNewRound(
        _ s: StoryState, _ w: WorldState, previous: StoryState, events: [StoryEvent], label: String
    ) {
        let n = previous.round + 1
        #expect(s.round == n, "\(label): round \(s.round), expected \(n)")
        #expect(s.giver == previous.receiver && s.receiver == previous.giver, "\(label): roles not swapped")
        #expect(s.giver == expectedGiver(n), "\(label): round \(n) giver \(s.giver)")
        #expect(s.receiver == expectedGiver(n).other, "\(label)")
        #expect(events.contains(.roundStarted(round: n, giver: expectedGiver(n), receiver: expectedGiver(n).other)),
                "\(label): \(events)")
        #expect(s.stage == .wish || s.stage == .waiting || s.stage == .travel, "\(label): \(String(describing: s.stage))")
        let flower = s.currentFlower.flatMap { w.items[$0] }
        #expect(flower?.kind == .flower(storyRound: n), "\(label)")
        #expect(flower?.placement == .held(expectedGiver(n)), "\(label)")
        #expect(w.residents[expectedGiver(n)]?.heldItem == s.currentFlower, "\(label)")
    }

    /// 恢复后的世界：设好窗口，恢复存档，再把两人放回各自家窗口（替代下落落地，保留持有物）。
    static func restoredWorld(_ save: SaveFile, now: Date) -> WorldState {
        var w = WorldState(screen: screen)
        StoryDirectorTests.setWindows(&w, windows, constants: constants)
        SaveSnapshot.restore(save, into: &w, now: now, constants: constants)
        if let homes = StoryDirector.selectHomes(
            windows: w.windows.visibleSnapshots, ledges: w.surfaces, minSize: constants.minWindowSize) {
            for (id, home) in [(ResidentID.a, homes.a), (.b, homes.b)] {
                guard let at = StoryDirector.homeAttachment(window: home, world: w) else { continue }
                let held = w.residents[id]?.heldItem
                StoryDirector.place(id, at: at, world: &w)
                w.residents[id]?.heldItem = held
            }
        }
        StoryDirector.assignGoals(w.story, world: &w)
        return w
    }

    // Feature: v1, Property 32: 送花方轮换
    // **Validates: Requirements 15.5, 19.2, 19.5, 19.6**
    @Test func giverRotation() async {
        // 纯函数部分：任意 n ≥ 1。
        for n in 1...2_000 {
            #expect(StoryDirector.giver(round: n) == Self.expectedGiver(n))
            #expect(StoryDirector.receiver(round: n) == Self.expectedGiver(n).other)
            #expect(StoryDirector.giver(round: n + 1) == StoryDirector.receiver(round: n))
        }

        await propertyCheck(count: 100, input: Gen.rotationCase) { c in
            let constants = Self.constants
            var now = Self.base
            var w = WorldState(screen: Self.screen)
            StoryDirectorTests.setWindows(&w, Self.windows, constants: constants)
            var s = StoryState(round: c.startRound)
            let begin = StoryDirector.tryBegin(&s, world: &w, constants: constants, now: now)
            // 开局：本轮 Giver 按奇偶规则，抱着本轮的花盆（Requirement 15.5、16.1）。
            #expect(s.round == c.startRound, "\(c)")
            #expect(s.giver == Self.expectedGiver(c.startRound), "\(c)")
            #expect(begin.contains(.roundStarted(round: c.startRound, giver: Self.expectedGiver(c.startRound),
                                                 receiver: Self.expectedGiver(c.startRound).other)), "\(c)")
            #expect(w.residents[s.giver]?.heldItem == s.currentFlower && s.currentFlower != nil, "\(c)")

            for (i, op) in c.ops.enumerated() {
                let label = "\(c) op \(i) \(op)"
                now = now.addingTimeInterval(1)
                switch op.kind {
                case 0:
                    Self.advance(&s, &w, to: 3, now: now, label: label)
                    let before = s
                    let events = StoryDirector.fastForward(&s, world: &w, constants: constants, now: now)
                    Self.checkNewRound(s, w, previous: before, events: events, label: label)

                case 1:
                    Self.advance(&s, &w, to: 3, now: now, label: label)
                    let before = s
                    guard let doneAt = s.doneAt else {
                        Issue.record("\(label): no doneAt")
                        return
                    }
                    // Round_Interval 之前不开始下一轮。
                    let early = StoryDirector.update(
                        &s, world: &w, constants: constants,
                        now: doneAt.addingTimeInterval(constants.roundInterval - 0.5), dt: 1.0 / 30)
                    #expect(s.round == before.round && s.stage == .done, "\(label): started early \(early)")
                    // 达到 Round_Interval 后 1 秒内开始下一轮（Requirement 19.1）。
                    now = doneAt.addingTimeInterval(constants.roundInterval + Double(op.jitterMs) / 1000)
                    let events = StoryDirector.update(&s, world: &w, constants: constants, now: now, dt: 1.0 / 30)
                    Self.checkNewRound(s, w, previous: before, events: events, label: label)

                default:
                    Self.advance(&s, &w, to: op.saveStage, now: now, label: label)
                    w.story = s
                    let save = SaveSnapshot.snapshot(world: w, now: now)
                    guard let data = try? SaveCodec.encode(save), let decoded = try? SaveCodec.decode(data) else {
                        Issue.record("\(label): encode/decode failed")
                        return
                    }
                    #expect(decoded.story.round == s.round, "\(label)")

                    // 恢复到新世界：轮次不变，Giver / Receiver 按奇偶规则（Requirement 19.6、22.9）。
                    let before = s
                    w = Self.restoredWorld(decoded, now: now)
                    s = w.story
                    #expect(s.round == before.round, "\(label): round \(s.round) vs \(before.round)")
                    #expect(s.giver == before.giver && s.receiver == before.receiver, "\(label)")
                    #expect(s.giver == Self.expectedGiver(s.round), "\(label)")
                    #expect(s.stage == SavedStory.persistedStage(before.stage), "\(label): \(String(describing: s.stage))")
                    switch Self.order(s.stage) {
                    case 0:
                        let flower = s.currentFlower.flatMap { w.items[$0] }
                        #expect(flower?.kind == .flower(storyRound: s.round), "\(label)")
                        #expect(w.residents[s.giver]?.heldItem == s.currentFlower, "\(label)")
                    case 2:
                        #expect(w.residents[s.receiver]?.heldItem == s.currentFruit && s.currentFruit != nil, "\(label)")
                    default:
                        break
                    }

                    // 同一存档交给新的 WorldEngine：恢复那一帧的剧情视图与奇偶规则一致。
                    let engine = WorldEngine(
                        constants: constants, clockStart: now, screen: Self.screen, rng: RandomSource(seed: 1),
                        demoResident: false, story: true, restored: decoded)
                    var source = FakeWindowSource(snapshots: Self.windows)
                    let out = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: now))
                    #expect(out.view.story?.round == before.round, "\(label): engine round \(String(describing: out.view.story?.round))")
                    #expect(out.view.story?.giver == Self.expectedGiver(before.round), "\(label)")
                    #expect(out.view.story?.receiver == Self.expectedGiver(before.round).other, "\(label)")
                }
            }
        }
    }
}
