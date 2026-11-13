import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// 重置世界属性测试（design.md Property 50，任务 8.10）。
//
// 随机世界：1 至 3 个窗口，剧情与自主活动启用，居民由剧情开局放置；0 至 3 个 Chair 或 Lamp；Ground 上各有一块
// 落下的 Plank 和 Ladder。随机操作：逐帧等待、时钟跳跃、`triggerWish`（各类型、各居民，含 chase 与不指定
// Wisher）、切换昼夜覆盖、`unlockAllDecor`；最后可选地触发 Chase_Wish 并等待 0 至 120 帧（覆盖 `ready` 与
// `running`），然后执行 `resetWorld`。时区固定为 UTC。
//
// 「两个只在 Wish 和 Story_Stage 上不同的世界」：同一场景运行两次（引擎确定），第二次在重置前改写 Wish_State
// 与 Story_Stage，再比较两者重置后的状态。Item 的 ID 是随机 UUID，若两次运行在重置前已出现分歧（UUID 排序
// 影响了行为），该样例不做这项比较并计数。

// MARK: - 生成器

fileprivate struct WindowSpec: Sendable {
    var x: Int, y: Int, w: Int
}

fileprivate struct DecorSpec: Sendable {
    var isLamp: Bool
    /// 0 为 Ground，其余为窗口下标 + 1（超出窗口数时取模）。
    var surface: Int
    /// 位置比例（0...10）。
    var frac: Int
}

fileprivate struct Op: Sendable, CustomStringConvertible {
    var kind: Int
    var index: Int
    var a: Int
    var frames: Int

    static let names = ["wait", "jump", "trigger", "trigger", "trigger", "night", "day", "auto", "unlockAll"]
    var description: String { "\(Self.names[kind])(\(index), \(a)) + \(frames)f" }
}

/// 第二个世界在重置前的改写：Wish_State 与 Story_Stage。
fileprivate struct Alteration: Sendable, CustomStringConvertible {
    /// StoryStage.allCases 下标；等于 allCases.count 时为 nil。
    var stage: Int
    /// 保留第一个世界的 active Wish（否则清空）。
    var keepActive: Bool
    var flowerCount: Int
    /// 比特 0：都都有上一个 Wish 结束时间；比特 1：嘟嘟有。
    var lastEndedMask: Int
    var hasLastFlowerDone: Bool
    var offset: Int

    var description: String {
        "stage \(stage) keep \(keepActive) flowers \(flowerCount) ended \(lastEndedMask) "
            + "done \(hasLastFlowerDone) offset \(offset)"
    }
}

fileprivate struct Scenario: Sendable, CustomStringConvertible {
    var windows: [WindowSpec]
    var decors: [DecorSpec]
    var startHour: Int
    var seed: Int
    var ops: [Op]
    /// 重置前触发 Chase_Wish 后等待的帧数；-1 表示不触发。
    var chaseWait: Int
    var alteration: Alteration

    var description: String {
        "hour \(startHour) seed \(seed) windows \(windows.map { "(\($0.x),\($0.y),\($0.w))" }) "
            + "decors \(decors.map { "\($0.isLamp ? "lamp" : "chair")@\($0.surface):\($0.frac)" }) "
            + "ops \(ops) chaseWait \(chaseWait) alt \(alteration)"
    }
}

fileprivate var scenarioGen: Generator<Scenario, some SendableSequenceType> {
    let window = zip(Gen<Int>.int(in: 0...25), Gen<Int>.int(in: 5...14), Gen<Int>.int(in: 5...10))
        .map { WindowSpec(x: $0 * 40, y: $1 * 40, w: $2 * 40) }
    let decor = zip(Gen<Bool>.bool, Gen<Int>.int(in: 0...3), Gen<Int>.int(in: 0...10))
        .map { DecorSpec(isLamp: $0, surface: $1, frac: $2) }
    let op = zip(
        Gen<Int>.int(in: 0...(Op.names.count - 1)), Gen<Int>.int(in: 0...14), Gen<Int>.int(in: 0...2),
        Gen<Int>.int(in: 1...45)
    ).map { Op(kind: $0, index: $1, a: $2, frames: $3) }
    let alteration = zip(
        Gen<Int>.int(in: 0...StoryStage.allCases.count), Gen<Bool>.bool, Gen<Int>.int(in: 0...5),
        Gen<Int>.int(in: 0...3), Gen<Bool>.bool, Gen<Int>.int(in: 1...5000)
    ).map { Alteration(stage: $0, keepActive: $1, flowerCount: $2, lastEndedMask: $3, hasLastFlowerDone: $4,
                       offset: $5) }
    return zip(
        window.array(of: 1...3),
        decor.array(of: 0...3),
        Gen<Int>.int(in: 0...23),
        Gen<Int>.int(in: 0...1_000_000),
        op.array(of: 1...5),
        Gen<Int>.int(in: -40...120),
        alteration
    ).map { windows, decors, hour, seed, ops, chase, alt in
        Scenario(windows: windows, decors: decors, startHour: hour, seed: seed, ops: ops,
                 chaseWait: chase < 0 ? -1 : chase, alteration: alt)
    }
}

// MARK: - 模拟

fileprivate final class Sim {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let dt = 1.0 / 30

    let engine: WorldEngine
    var source: FakeWindowSource
    var now: Date

    init(_ s: Scenario) {
        now = Date(timeIntervalSince1970: 23 * 86400 + Double(s.startHour) * 3600)
        let windows = s.windows.enumerated().map { i, w in
            StoryEngineTests.win(WindowID(i + 1), x: Double(w.x), y: Double(w.y), w: Double(w.w), h: 160)
        }
        engine = WorldEngine(clockStart: now, screen: Self.screen, rng: RandomSource(seed: UInt64(s.seed)))
        source = FakeWindowSource(snapshots: windows)
        for (i, d) in s.decors.enumerated() {
            let att: CoreAttachment
            if d.surface == 0 {
                att = .ground(x: 100 + Double(d.frac) * 120)
            } else {
                let w = windows[(d.surface - 1) % windows.count]
                att = .window(w.id, offset: w.frame.width * Double(d.frac) / 10)
            }
            engine.insertDecor(Decor(id: DecorID(UInt64(i + 1)), type: d.isLamp ? .lamp : .chair,
                                     placement: .attached(att)))
        }
        engine.insertPlank(.loose(.ground(x: 60)))
        engine.insertLadder(.loose(.ground(x: 1380)))
    }

    @discardableResult
    func step(_ commands: [Command] = [], advance: Double = Sim.dt) -> StepOutput {
        now = now.addingTimeInterval(advance)
        return engine.step(FrameInput(poll: source.poll(), screen: Self.screen, commands: commands, now: now,
                                      timeZone: Self.utc))
    }

    /// 运行到重置之前（不含重置那一帧）。
    func runUpToReset(_ s: Scenario) {
        step()
        for op in s.ops {
            var commands: [Command] = []
            var advance = Sim.dt
            switch Op.names[op.kind] {
            case "jump": advance = 10 + Double(op.index * 50)
            case "trigger":
                let type = WishType.allCases[op.index % WishType.allCases.count]
                commands = [.triggerWish(type, [ResidentID.a, .b, nil][op.a])]
            case "night": commands = [.setDayNight(.night)]
            case "day": commands = [.setDayNight(.day)]
            case "auto": commands = [.setDayNight(.auto)]
            case "unlockAll": commands = [.unlockAllDecor]
            default: break
            }
            for f in 0 ..< op.frames {
                step(f == 0 ? commands : [], advance: f == 0 ? advance : Sim.dt)
            }
        }
        if s.chaseWait >= 0 {
            step([.triggerWish(.chase, s.seed % 2 == 0 ? .a : nil)])
            for _ in 0 ..< s.chaseWait { step() }
        }
    }
}

// MARK: - 覆盖统计

/// 重置前的状态覆盖（只用于报告生成器是否到达了 Property 50 列出的各类状态）。
fileprivate final class Coverage: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func note(_ keys: [String]) {
        lock.lock()
        for k in keys { counts[k, default: 0] += 1 }
        lock.unlock()
    }

    subscript(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key, default: 0]
    }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

fileprivate func coverageKeys(_ st: WorldState) -> [String] {
    var keys: [String] = []
    for w in st.wishes.active {
        keys.append("wish.\(w.type.rawValue)")
        if let c = w.chase { keys.append("chase.\(c.phase.rawValue)") }
    }
    for r in st.residents.values where [.sitting, .sleeping, .running, .waiting].contains(r.state) {
        keys.append("state.\(r.state.rawValue)")
    }
    if st.decors.count > 0 { keys.append("decor") }
    if !st.decors.unlocked.isEmpty { keys.append("unlocked") }
    if st.dayNightOverride != .auto { keys.append("override") }
    if st.story.stage != nil { keys.append("stage") }
    if !st.items.items.isEmpty { keys.append("items") }
    if st.residents.values.contains(where: { $0.walkDistance > 0 }) { keys.append("walked") }
    return keys
}

// MARK: - 检查

fileprivate let placeholderItem = ItemID(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)

/// 两个世界重置前「其余部分相同」的检查：居民（持有物只比较有无，Item ID 是随机 UUID）、随机数状态、
/// Decor、Plank、Ladder、Item 数量。
fileprivate func sameApartFromWishes(_ x: WorldState, _ xr: RandomSource, _ y: WorldState, _ yr: RandomSource)
    -> Bool {
    func norm(_ rs: [ResidentID: Resident]) -> [ResidentID: Resident] {
        rs.mapValues { r in
            var r = r
            r.heldItem = r.heldItem.map { _ in placeholderItem }
            return r
        }
    }
    return xr == yr && norm(x.residents) == norm(y.residents) && x.decors == y.decors && x.planks == y.planks
        && x.ladders == y.ladders && x.items.items.count == y.items.items.count
}

/// 重置后两个世界的状态差异（空表示相同）。
fileprivate func resetDiff(_ e1: WorldEngine, _ e2: WorldEngine) -> [String] {
    let x = e1.state, y = e2.state
    var d: [String] = []
    if x.residents != y.residents { d.append("residents \(x.residents) vs \(y.residents)") }
    if x.decors != y.decors { d.append("decors") }
    if x.items != y.items { d.append("items \(x.items.items.count) vs \(y.items.items.count)") }
    if x.planks != y.planks { d.append("planks") }
    if x.ladders != y.ladders { d.append("ladders") }
    if x.story != y.story { d.append("story \(x.story) vs \(y.story)") }
    if x.wishes != y.wishes { d.append("wishes \(x.wishes) vs \(y.wishes)") }
    if x.activities != y.activities { d.append("activities \(x.activities) vs \(y.activities)") }
    if x.dayNightOverride != y.dayNightOverride || x.isNight != y.isNight { d.append("dayNight") }
    if x.gesture != y.gesture { d.append("gesture") }
    if x.toolboxShake != y.toolboxShake { d.append("toolboxShake") }
    if e1.rng != e2.rng { d.append("rng") }
    return d
}

/// 第一个世界重置那一帧之后的检查。`before` 为重置前的状态。
fileprivate func checkReset(before: WorldState, sim: Sim, out: StepOutput) -> [String] {
    let st = sim.engine.state
    let c = sim.engine.constants
    var v: [String] = []
    if st.decors.count != 0 || !out.view.decors.isEmpty { v.append("decors remain \(st.decors.count)") }
    if !st.items.items.isEmpty || !out.view.items.isEmpty { v.append("items remain \(st.items.items.count)") }
    if !st.wishes.active.isEmpty { v.append("wishes remain \(st.wishes.active.map(\.type))") }
    if !st.wishes.busy.isEmpty || !sim.engine.busyResidents().isEmpty {
        v.append("busy \(st.wishes.busy) / \(sim.engine.busyResidents())")
    }
    if !st.wishes.celebrations.isEmpty || !st.wishes.celebrationHearts.isEmpty { v.append("celebrations remain") }
    if !out.view.visitFlags.isEmpty { v.append("visit flags \(out.view.visitFlags)") }
    if !st.decors.unlocked.isEmpty || !out.view.unlockedDecor.isEmpty { v.append("unlocked \(st.decors.unlocked)") }
    if st.wishes.flowerCount != 0 { v.append("flowerCount \(st.wishes.flowerCount)") }
    if !st.wishes.lastEnded.isEmpty { v.append("lastEnded \(st.wishes.lastEnded)") }
    if st.wishes.lastFlowerDoneAt != nil { v.append("lastFlowerDoneAt \(st.wishes.lastFlowerDoneAt!)") }
    if st.story.stage != nil { v.append("story stage \(st.story.stage!)") }
    // 重置之后同一帧居民还会移动一次：Walk_Distance 至多是本帧以正常速度走过的距离。
    let maxStep = c.walkSpeed * Sim.dt + 1e-6
    for r in st.residents.values.sorted(by: { $0.id < $1.id }) {
        if r.walkDistance > maxStep { v.append("\(r.id) walkDistance \(r.walkDistance)") }
        if [.sitting, .sleeping, .running, .celebrating].contains(r.state) { v.append("\(r.id) state \(r.state)") }
        if r.seat != nil { v.append("\(r.id) seat \(r.seat!)") }
        if r.speedFactor != 1 { v.append("\(r.id) speedFactor \(r.speedFactor)") }
        switch r.bubble {
        case .wishIcon?, .wish?, .heart?: v.append("\(r.id) bubble \(r.bubble!)")
        default: break
        }
    }
    for r in out.view.residents {
        switch r.bubble {
        case .wishIcon?, .wish?, .heart?: v.append("view \(r.id) bubble \(r.bubble!)")
        default: break
        }
    }
    if st.planks != before.planks { v.append("planks changed") }
    if st.ladders != before.ladders { v.append("ladders changed") }
    let wishRecords = out.events.filter { $0.type == .wishFulfilled || $0.type == .wishDropped }
    if !wishRecords.isEmpty { v.append("wish records \(wishRecords.map(\.type))") }
    if st.dayNightOverride != before.dayNightOverride {
        v.append("dayNight override \(before.dayNightOverride) -> \(st.dayNightOverride)")
    }
    // 同一帧重新分配 Home_Window：窗口没有变化，重置前能分配的，重置后同样分配，并开始 Wish 调度。
    if !before.story.homes.isEmpty {
        if st.story.homes.isEmpty { v.append("homes not reassigned") }
        if st.wishes.nextCheckAt == nil { v.append("nextCheckAt nil") }
    }
    v += sim.engine.invariantViolations()
    return v
}

/// 按 `alt` 改写 `engine` 的 Wish_State 与 Story_Stage。
fileprivate func alter(_ engine: WorldEngine, _ alt: Alteration, now: Date) {
    let t = now.addingTimeInterval(-Double(alt.offset))
    var ended: [ResidentID: Date] = [:]
    if alt.lastEndedMask & 1 != 0 { ended[.a] = t }
    if alt.lastEndedMask & 2 != 0 { ended[.b] = t.addingTimeInterval(-7) }
    let old = engine.state.wishes
    engine.state.wishes = WishBook(
        active: alt.keepActive ? old.active : [], lastEnded: ended, flowerCount: alt.flowerCount,
        lastFlowerDoneAt: alt.hasLastFlowerDone ? t : nil, nextCheckAt: t.addingTimeInterval(Double(alt.offset * 2)),
        nextID: old.nextID + UInt64(alt.offset))
    engine.state.story.stage = alt.stage < StoryStage.allCases.count ? StoryStage.allCases[alt.stage] : nil
}

// MARK: - 属性

struct WorldResetTests {
    // Feature: V2, Property 50: 重置世界
    // **Validates: Requirements 1.6, 17.6, 22.7**
    @Test func resetWorldClearsWishesAndDecorIndependentOfWishState() async {
        let coverage = Coverage()
        await propertyCheck(count: 100, input: scenarioGen) { s in
            let sim = Sim(s)
            sim.runUpToReset(s)
            let before = sim.engine.state
            let rngBefore = sim.engine.rng
            coverage.note(coverageKeys(before))
            let out = sim.step([.resetWorld])
            let violations = checkReset(before: before, sim: sim, out: out)
            #expect(violations.isEmpty, "\(violations.prefix(4))")

            // 只在 Wish 和 Story_Stage 上不同的第二个世界，重置后状态相同。
            let twin = Sim(s)
            twin.runUpToReset(s)
            if !sameApartFromWishes(before, rngBefore, twin.engine.state, twin.engine.rng) {
                coverage.note(["twinDiverged"])
                return
            }
            alter(twin.engine, s.alteration, now: twin.now)
            twin.step([.resetWorld])
            let diff = resetDiff(sim.engine, twin.engine)
            #expect(diff.isEmpty, "\(diff.prefix(3))")
            coverage.note(["twinCompared"])
        }
        #expect(coverage["chase.ready"] + coverage["chase.running"] > 0, "\(coverage.summary)")
    }
}
