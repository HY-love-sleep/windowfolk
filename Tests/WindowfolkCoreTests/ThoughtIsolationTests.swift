import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// v2 任务 12.11：Thought 请求不影响世界推进（Requirement 12.5）。
///
/// 两台相同配置、相同随机种子的完整 V2 世界（剧情与自主活动启用，时区 UTC）接受同一串输入：窗口移动、关闭、
/// 隐藏、显示、置前，调试「触发心愿」「快进」「昼夜覆盖」，世界因全屏隐藏，以及时间跳跃。
/// 一台打开「小心思」并在每帧注入随机的 `thoughtResults`（不返回、成功、失败、空白文本、迟到或不匹配的 id），
/// 另一台关闭「小心思」。每次 step 结束时，除 `state.thoughts`、`Resident.thought`、`ResidentView.thought`、
/// `thought_shown` 记录、`thoughtRequests` 和随画面变化的轮询频率之外，两台世界的状态和输出完全一致。
struct ThoughtIsolationTests {
    // Feature: V2, Property 36: LLM 请求不影响世界推进
    /// **Validates: Requirements 12.5**
    @Test func thoughtRequestsDoNotAffectWorldProgress() async {
        await propertyCheck(count: 100, input: isolationScenario) { s in
            let report = Self.run(s)
            #expect(report.mismatch == nil, "\(s)\n\(report.mismatch ?? "")")
        }
    }

    // MARK: - 运行

    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(identifier: "UTC")!
    /// UTC 08:00 起步；时间跳跃可跨过 Night。
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let dt = 1.0 / 30

    struct Report {
        var mismatch: String?
        /// 打开「小心思」的一台显示过的 Thought 数（用于确认场景确实覆盖了显示路径）。
        var shown = 0
        var requests = 0
    }

    static func constants() -> Tunables {
        var c = Tunables()
        // 让 Thought 更频繁地请求和显示，Wish 更快出现。两台世界使用同一组常量。
        c.thoughtMinInterval = 2
        c.thoughtDisplayDuration = 1
        c.wishCheckInterval = 1
        c.wishCooldown = 5
        c.wishSpawnChance = 0.5
        return c
    }

    fileprivate static func run(_ s: IsolationScenario) -> Report {
        let c = constants()
        let on = WorldEngine(constants: c, clockStart: t0, screen: screen, rng: RandomSource(seed: s.seed), story: true)
        let off = WorldEngine(constants: c, clockStart: t0, screen: screen, rng: RandomSource(seed: s.seed), story: true)
        var source = FakeWindowSource(snapshots: s.windows)
        var now = t0
        var hidden = false
        var issued: [UInt64] = []
        var frame = 0
        var report = Report()
        var ids = ItemIDMap()

        for op in s.ops {
            var commands: [Command] = []
            let windowIDs = source.windows.map(\.snapshot.id)
            let target = windowIDs.isEmpty ? nil : windowIDs[op.index % windowIDs.count]
            switch op.kind {
            case .move:
                if let t = target, let w = source.windows.first(where: { $0.snapshot.id == t }) {
                    source.move(t, to: Point(x: w.snapshot.frame.minX + Double(op.a * 10),
                                             y: w.snapshot.frame.minY + Double(op.b * 10)))
                }
            case .close: if let t = target { source.close(t) }
            case .hide: if let t = target { source.hide(t) }
            case .show: if let t = target { source.show(t) }
            case .front: if let t = target { source.bringToFront(t) }
            case .triggerWish:
                let type = WishType.allCases[abs(op.a) % WishType.allCases.count]
                commands.append(.triggerWish(type, op.b % 2 == 0 ? .a : .b))
            case .fastForward: commands.append(.fastForward)
            case .dayNight:
                commands.append(.setDayNight(DayNightOverride.allCases[abs(op.a) % DayNightOverride.allCases.count]))
            case .toggleHidden: hidden.toggle()
            case .wait: break
            }

            for f in 0 ..< op.frames {
                // 时间跳跃：让计时器、Night 判定和 Thought 显示时长都有机会跨过阈值。
                now = now.addingTimeInterval(op.jump && f == 0 ? Double(op.a + 25) * 2 : dt)
                let poll = source.poll()
                let cmds = f == 0 ? commands : []
                let choice = s.results[frame % s.results.count]
                let results = Self.results(choice, inFlight: on.state.thoughts.inFlight?.id, issued: issued)
                frame += 1

                let outOn = on.step(FrameInput(
                    poll: poll, screen: screen, commands: cmds, now: now, timeZone: utc,
                    worldHidden: hidden, thoughtsEnabled: true, thoughtResults: results))
                let outOff = off.step(FrameInput(
                    poll: poll, screen: screen, commands: cmds, now: now, timeZone: utc,
                    worldHidden: hidden, thoughtsEnabled: false, thoughtResults: []))
                issued += outOn.thoughtRequests.map(\.id)
                report.requests += outOn.thoughtRequests.count
                report.shown += outOn.events.filter { $0.type == .thoughtShown }.count

                ids.learn(on: on.state.items, off: off.state.items)
                if let m = Self.firstMismatch(on, outOn, off, outOff, ids: ids) {
                    report.mismatch = "frame \(frame): \(m)"
                    return report
                }
            }
        }
        return report
    }

    /// 按选择构造本帧送回的结果。`inFlight` 取自打开「小心思」那一台当前进行中的请求。
    fileprivate static func results(_ choice: ResultChoice, inFlight: UInt64?, issued: [UInt64]) -> [(UInt64, ThoughtResult)] {
        switch choice {
        case .none: return []
        case .success(let text): return inFlight.map { [($0, .text(text))] } ?? []
        case .failure: return inFlight.map { [($0, .failure)] } ?? []
        case .blank(let text): return inFlight.map { [($0, .text(text))] } ?? []
        case .stale(let k):
            // 已经结束的旧请求 id，或从未发出的 id。
            let old = issued.filter { $0 != inFlight }
            let id = old.isEmpty ? (inFlight ?? 0) &+ UInt64(k + 1) : old[k % old.count]
            return [(id, .text("迟到的"))]
        }
    }

    // MARK: - 比较

    /// 物件 ID 是 `UUID()`（design.md），两台世界各自生成的 ID 不同。按出现的帧把「小心思打开」一台的 ID
    /// 一一对应到另一台，比较前把打开一台的值中的物件 ID 换成对应的 ID。同一帧出现多个新物件时，
    /// 按去掉 ID 后的内容排序配对。
    struct ItemIDMap {
        var onToOff: [ItemID: ItemID] = [:]

        mutating func learn(on: ItemStore, off: ItemStore) {
            let mappedOff = Set(onToOff.values)
            let newOn = on.items.values.filter { onToOff[$0.id] == nil }
            let newOff = off.items.values.filter { !mappedOff.contains($0.id) }
            guard !newOn.isEmpty, newOn.count == newOff.count else { return }
            func key(_ item: Item) -> String {
                var item = item
                item.id = ItemID(UUID(uuid: UUID_NULL))
                return "\(item)"
            }
            let a = newOn.sorted { key($0) < key($1) }, b = newOff.sorted { key($0) < key($1) }
            for (x, y) in zip(a, b) { onToOff[x.id] = y.id }
        }

        func id(_ i: ItemID) -> ItemID { onToOff[i] ?? i }
        func id(_ i: ItemID?) -> ItemID? { i.map(id) }

        func text(_ s: String) -> String {
            var s = s
            for (a, b) in onToOff { s = s.replacingOccurrences(of: a.rawValue.uuidString, with: b.rawValue.uuidString) }
            return s
        }
        func text(_ s: String?) -> String? { s.map(text) }

        func residents(_ rs: [ResidentID: Resident]) -> [ResidentID: Resident] {
            rs.mapValues { r in var r = r; r.thought = nil; r.heldItem = id(r.heldItem); return r }
        }

        func items(_ store: ItemStore) -> ItemStore {
            ItemStore(items: Dictionary(uniqueKeysWithValues: store.items.values.map { item in
                var item = item
                item.id = id(item.id)
                return (item.id, item)
            }))
        }

        func story(_ s: StoryState) -> StoryState {
            var s = s
            s.currentFlower = id(s.currentFlower)
            s.currentFruit = id(s.currentFruit)
            return s
        }

        func activities(_ acts: [ResidentID: Activity]) -> [ResidentID: Activity] {
            acts.mapValues { a in
                var a = a
                if case let .flower(i) = a.target { a.target = .flower(id(i)) }
                return a
            }
        }

        func events(_ es: [EventRecord]) -> [EventRecord] {
            es.filter { $0.type != .thoughtShown }.map { e in
                var e = e
                e.actor = text(e.actor)
                e.target = text(e.target)
                e.detail = e.detail.mapValues(text)
                return e
            }
        }

        func view(_ v: WorldView) -> WorldView {
            var v = v
            v.residents = v.residents.map { r in var r = r; r.thought = nil; r.heldItem = id(r.heldItem); return r }
            v.items = v.items.map { i in var i = i; i.id = id(i.id); return i }
            v.hitRegions = v.hitRegions.map { h in
                var h = h
                if case let .item(i) = h.target { h.target = .item(id(i)) }
                return h
            }
            if var story = v.story {
                story.currentFlower = id(story.currentFlower)
                story.currentFruit = id(story.currentFruit)
                v.story = story
            }
            return v
        }
    }

    /// 返回第一处不一致的字段名和两边的值；完全一致时为 nil。
    /// 打开「小心思」一台的值先去掉 Thought 相关字段、换好物件 ID；关闭一台的值只去掉 Thought（本应为空）。
    static func firstMismatch(
        _ a: WorldEngine, _ oa: StepOutput, _ b: WorldEngine, _ ob: StepOutput, ids: ItemIDMap
    ) -> String? {
        let same = ItemIDMap()
        func diff<T: Equatable>(_ name: String, _ x: T, _ y: T) -> String? {
            x == y ? nil : "\(name) differs\n  on:  \(x)\n  off: \(y)"
        }
        /// 顺序可能取决于物件 ID 的数组（按 ID 排序生成），按多重集比较。
        func bag<T: Hashable>(_ name: String, _ x: [T], _ y: [T]) -> String? {
            func counts(_ v: [T]) -> [T: Int] { v.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
            return counts(x) == counts(y) ? nil : "\(name) differs\n  on:  \(x)\n  off: \(y)"
        }
        func orderFree(_ v: WorldView) -> WorldView {
            var v = v
            v.items = []
            v.hitRegions = []
            return v
        }
        let sa = a.state, sb = b.state
        let va = ids.view(oa.view), vb = same.view(ob.view)
        let checks: [() -> String?] = [
            { diff("state.screen", sa.screen, sb.screen) },
            { diff("state.windows", sa.windows, sb.windows) },
            { diff("state.surfaces", sa.surfaces, sb.surfaces) },
            { diff("state.showSurfaces", sa.showSurfaces, sb.showSurfaces) },
            { diff("state.residents", ids.residents(sa.residents), same.residents(sb.residents)) },
            { diff("state.planks", sa.planks, sb.planks) },
            { diff("state.gesture", sa.gesture, sb.gesture) },
            { diff("state.nav", sa.nav, sb.nav) },
            { diff("state.ladders", sa.ladders, sb.ladders) },
            { diff("state.items", ids.items(sa.items), sb.items) },
            { diff("state.story", ids.story(sa.story), sb.story) },
            { diff("state.decors", sa.decors, sb.decors) },
            { diff("state.toolboxShake", sa.toolboxShake, sb.toolboxShake) },
            { diff("state.activities", ids.activities(sa.activities), sb.activities) },
            { diff("state.dayNightOverride", sa.dayNightOverride, sb.dayNightOverride) },
            { diff("state.isNight", sa.isNight, sb.isNight) },
            { diff("state.wishes", sa.wishes, sb.wishes) },
            { diff("engine.rng", a.rng, b.rng) },
            { diff("engine.lastNow", a.lastNow, b.lastNow) },
            { diff("engine.navVersion", a.navVersion, b.navVersion) },
            { diff("view", orderFree(va), orderFree(vb)) },
            { bag("view.items", va.items, vb.items) },
            { bag("view.hitRegions", va.hitRegions, vb.hitRegions) },
            { diff("windowChanges", oa.windowChanges, ob.windowChanges) },
            { diff("interactions", oa.interactions, ob.interactions) },
            { diff("failedPlanks", oa.failedPlanks, ob.failedPlanks) },
            { diff("failedLadders", oa.failedLadders, ob.failedLadders) },
            { diff("storyEvents", ids.text("\(oa.storyEvents)"), "\(ob.storyEvents)") },
            { diff("events (without thought_shown)", ids.events(oa.events), same.events(ob.events)) },
            { ob.thoughtRequests.isEmpty ? nil : "disabled world sent thought requests" },
        ]
        for check in checks {
            if let m = check() { return m }
        }
        return nil
    }

    // MARK: - 覆盖检查

    /// 确认生成的场景确实走到了「发请求」与「显示 Thought」两条路径（否则属性比较只覆盖了不返回的情形）。
    @Test func scenariosExerciseRequestsAndShownThoughts() {
        var rng = Xoshiro(seed: (12, 34, 56, 78))
        var requests = 0, shown = 0
        for _ in 0 ..< 10 {
            let report = Self.run(isolationScenario.run(using: &rng))
            #expect(report.mismatch == nil)
            requests += report.requests
            shown += report.shown
        }
        #expect(requests > 0)
        #expect(shown > 0)
    }
}

// MARK: - 生成器

fileprivate enum OpKind: CaseIterable, Sendable {
    case move, close, hide, show, front, triggerWish, fastForward, dayNight, toggleHidden, wait
}

fileprivate struct IsolationOp: Sendable, CustomStringConvertible {
    var kind: OpKind
    var index: Int
    var a: Int
    var b: Int
    var frames: Int
    var jump: Bool
    var description: String { "\(kind)(\(index), \(a), \(b)) ×\(frames)\(jump ? " +jump" : "")" }
}

fileprivate enum ResultChoice: Sendable, CustomStringConvertible {
    case none
    case success(String)
    case failure
    case blank(String)
    case stale(Int)
    var description: String {
        switch self {
        case .none: "none"
        case .success(let t): "ok(\(t.debugDescription))"
        case .failure: "fail"
        case .blank(let t): "blank(\(t.debugDescription))"
        case .stale(let k): "stale(\(k))"
        }
    }
}

fileprivate struct IsolationScenario: Sendable, CustomStringConvertible {
    var seed: UInt64
    var windows: [WindowSnapshot]
    var ops: [IsolationOp]
    var results: [ResultChoice]
    var description: String {
        "seed \(seed), windows \(windows.map { ($0.id, $0.frame) }), ops \(ops), results \(results)"
    }
}

fileprivate let opGen = zip(
    Gen<Int>.int(in: 0 ... OpKind.allCases.count - 1),
    Gen<Int>.int(in: 0 ... 7),
    Gen<Int>.int(in: -12 ... 12),
    Gen<Int>.int(in: -12 ... 12),
    Gen<Int>.int(in: 1 ... 12),
    Gen<Bool>.bool
).map { IsolationOp(kind: OpKind.allCases[$0], index: $1, a: $2, b: $3, frames: $4, jump: $5) }

fileprivate let resultGen = zip(
    Gen<Int>.int(in: 0 ... 9),
    Gen<Int>.int(in: 0 ... 5)
).map { kind, k -> ResultChoice in
    let texts = ["落地啦", "  好开心\r\n呀  ", "今天的窗子真高真高真高真高真高真高真高真高真高", "🌸é"]
    let blanks = ["", "   ", "\n\r\n", " \t "]
    switch kind {
    case 0 ... 3: return .none
    case 4, 5: return .success(texts[k % texts.count])
    case 6: return .failure
    case 7: return .blank(blanks[k % blanks.count])
    default: return .stale(k)
    }
}

fileprivate let windowGen = zip(
    Gen<Int>.int(in: 0 ... 120),
    Gen<Int>.int(in: 10 ... 70),
    Gen<Int>.int(in: 15 ... 35)
).map { x, y, w in (x * 10, y * 10, w * 10) }
    .array(of: 2 ... 4)
    .map { specs in
        specs.enumerated().map { i, s in
            StoryEngineTests.win(WindowID(i + 1), x: Double(s.0), y: Double(s.1), w: Double(s.2))
        }
    }

fileprivate let isolationScenario = zip(
    Gen<UInt64>.uint64(in: 0 ... 1_000_000),
    windowGen,
    opGen.array(of: 3 ... 18),
    resultGen.array(of: 1 ... 24)
).map { IsolationScenario(seed: $0, windows: $1, ops: $2, results: $3) }
