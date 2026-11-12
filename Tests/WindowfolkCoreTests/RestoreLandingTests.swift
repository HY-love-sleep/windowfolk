import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 任务 17.5：启动落位与屏幕夹紧（Property 39）。
///
/// 参考实现独立于 `SaveSnapshot.restore` 和 `WorldEngine.clampGroundX`：
/// - Ground 水平范围 = 主显示器 frame 与 `visibleFrame` 的水平交集；
/// - 居民的期望落点是离保存 x 水平距离最近的窗沿上的最近点（距离并列时任取其一）。只考虑下落能到达的
///   窗沿部分：x 在 Ground 水平范围内、y 在 Ground 上方（屏幕外或 Ground 下方的窗沿部分落不上去）；
/// - 屏幕变化后，宽为 w 的 Ground 对象移到离原 x 最近、`[x − w/2, x + w/2]` 完整位于新 Ground 内的位置。
struct RestoreLandingTests {
    // MARK: - 参考实现

    /// Ground 的水平范围（frame 与 visibleFrame 的交集）。
    static func groundSpan(_ s: ScreenInfo) -> (lo: Double, hi: Double) {
        (max(s.frame.minX, s.visibleFrame.minX), min(s.frame.maxX, s.visibleFrame.maxX))
    }

    /// 把 x 夹紧到 Ground 水平范围内。
    static func refClampToScreen(_ x: Double, _ s: ScreenInfo) -> Double {
        let (lo, hi) = groundSpan(s)
        return min(max(x, lo), hi)
    }

    /// 宽为 w 的对象完整位于 Ground 内时离 x 最近的位置；Ground 比对象窄时取 Ground 中点。
    static func refFullyInside(_ x: Double, width w: Double, _ s: ScreenInfo) -> Double {
        let (lo, hi) = groundSpan(s)
        if hi - lo < w { return (lo + hi) / 2 }
        return min(max(x, lo + w / 2), hi - w / 2)
    }

    /// 只保留中心点在主显示器内的窗口（Eligible_Window 的条件，Requirement 2.6），并重新编号 zIndex。
    static func eligible(_ layout: [WindowSnapshot], _ s: ScreenInfo) -> [WindowSnapshot] {
        layout.filter { w in
            let cx = w.frame.minX + w.frame.width / 2, cy = w.frame.minY + w.frame.height / 2
            return cx >= s.frame.minX && cx <= s.frame.maxX && cy >= s.frame.minY && cy <= s.frame.maxY
        }.enumerated().map { i, w in
            var w = w
            w.zIndex = i
            return w
        }
    }

    /// 窗沿集合：每个窗口上沿减去前方覆盖该 y 的窗口的 x 区间（独立于 SurfaceBuilder 的逐段实现）。
    static func refLedges(_ windows: [WindowSnapshot]) -> [(window: WindowID, y: Double, lo: Double, hi: Double)] {
        var out: [(WindowID, Double, Double, Double)] = []
        for w in windows {
            let y = w.frame.minY
            var segs: [(Double, Double)] = [(w.frame.minX, w.frame.maxX)]
            for f in windows where f.zIndex < w.zIndex && f.frame.minY <= y && y <= f.frame.maxY {
                segs = segs.flatMap { (a, b) -> [(Double, Double)] in
                    var r: [(Double, Double)] = []
                    if f.frame.minX > a { r.append((a, min(b, f.frame.minX))) }
                    if f.frame.maxX < b { r.append((max(a, f.frame.maxX), b)) }
                    return r.filter { $0.1 - $0.0 > 0 }
                }
            }
            out += segs.map { (w.id, y, $0.0, $0.1) }
        }
        return out
    }

    /// 存档的阶段要求某位居民持有特定物件（`Wish` 到 `Planting` 中 Giver 抱花盆，`ReturnGift` / `Bloomed` 中
    /// Receiver 带果子）。实际运行中不会出现持有物与阶段冲突的存档；生成器去掉这种冲突的持有物，
    /// 使「保存时持有的 Item 恢复后仍被持有」可以对每个存档检查。
    static func consistent(_ save: SaveFile) -> SaveFile {
        var s = save
        guard let stage = s.story.stage else { return s }
        let giver: ResidentID = s.story.round % 2 == 1 ? .a : .b
        let receiver: ResidentID = giver == .a ? .b : .a
        for i in s.residents.indices {
            guard let held = s.residents[i].heldItem else { continue }
            switch stage {
            case .wish, .waiting, .travel, .planting:
                if s.residents[i].id == giver, held.kind != .flower { s.residents[i].heldItem = nil }
            case .bloomed, .returnGift:
                if s.residents[i].id == receiver, held.kind != .fruit { s.residents[i].heldItem = nil }
            default:
                break
            }
        }
        return s
    }

    static func step(_ engine: WorldEngine, _ source: inout FakeWindowSource, _ screen: ScreenInfo,
                     _ now: inout Date, dt: Double = 1.0 / 30) {
        now = now.addingTimeInterval(dt)
        engine.step(FrameInput(poll: source.poll(), screen: screen, now: now))
    }

    // MARK: - 启动落位（Requirement 22.6、22.7、22.8）

    // Feature: v1, Property 39: 启动落位与屏幕夹紧
    @Test func restoredObjectsLandAtClampedSavedPositions() async {
        await propertyCheck(count: 100, input: Gen.saveFile, Gen.windowLayout, Gen.screen) { rawSave, layout, screen in
            let save = Self.consistent(rawSave)
            let windows = Self.eligible(layout, screen)
            var source = FakeWindowSource(windows: windows.map { FakeWindow(snapshot: $0) })
            var now = Date(timeIntervalSince1970: 1_900_000_000)
            let engine = WorldEngine(clockStart: now, screen: screen, rng: RandomSource(seed: 7),
                                     demoResident: false, story: false, restored: save)
            let (glo, ghi) = Self.groundSpan(screen)
            let groundY = screen.visibleFrame.maxY
            // 下落能到达的窗沿部分。
            let ledges = Self.refLedges(windows).compactMap { l -> (window: WindowID, lo: Double, hi: Double)? in
                let lo = max(l.lo, glo), hi = min(l.hi, ghi)
                return l.y < groundY && lo <= hi ? (l.window, lo, hi) : nil
            }
            let frames = Dictionary(windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })

            // 推进到全部落地；记录每位居民第一次不处于 falling 时的 Attachment（之后会自行闲逛）。
            var landed: [ResidentID: CoreAttachment] = [:]
            for _ in 0 ..< 25 {   // 每帧 0.1 秒，共 2.5 秒；Requirement 6.4 要求 2 秒内落地
                Self.step(engine, &source, screen, &now, dt: 0.1)
                for (id, r) in engine.state.residents where landed[id] == nil && r.state != .falling {
                    landed[id] = r.attachment
                }
            }
            let state = engine.state

            // 居民：最近窗沿上的最近点；没有窗沿时落在 Ground 上保存 x（夹紧后）。
            for saved in save.residents {
                guard let a = landed[saved.id] else {
                    Issue.record("resident \(saved.id) still falling")
                    continue
                }
                if ledges.isEmpty {
                    #expect(a == .ground(x: Self.refClampToScreen(saved.x, screen)),
                            "resident \(saved.id) saved x \(saved.x): \(a)")
                    continue
                }
                let best = ledges.map { abs(min(max(saved.x, $0.lo), $0.hi) - saved.x) }.min()!
                guard case let .window(wid, offset) = a, let f = frames[wid] else {
                    Issue.record("resident \(saved.id) saved x \(saved.x) expected on a ledge, got \(a)")
                    continue
                }
                let x = f.minX + offset
                let onNearest = ledges.contains { l in
                    l.window == wid && x >= l.lo - 1e-6 && x <= l.hi + 1e-6
                        && abs(abs(min(max(saved.x, l.lo), l.hi) - saved.x) - best) <= 1e-6
                }
                #expect(onNearest && abs(abs(x - saved.x) - best) <= 1e-6,
                        "resident \(saved.id) saved x \(saved.x) landed at x \(x) on window \(wid), best distance \(best)")

                // 保存时持有的 Item 仍由该居民持有，且不作为 Ground_Object 出现。
                if let held = saved.heldItem, let iid = UUID(uuidString: held.id).map(ItemID.init) {
                    #expect(state.residents[saved.id]?.heldItem == iid)
                    #expect(state.items[iid]?.placement == .held(saved.id))
                }
            }
            for saved in save.residents where ledges.isEmpty {
                if let held = saved.heldItem, let iid = UUID(uuidString: held.id).map(ItemID.init) {
                    #expect(state.residents[saved.id]?.heldItem == iid)
                }
            }

            // Ground_Object：全部落在 Ground 上保存 x（夹紧到屏幕范围）处。
            var expectedPlanks: [Double] = [], expectedLadders: [Double] = []
            for obj in save.groundObjects {
                let x = Self.refClampToScreen(obj.x, screen)
                switch obj.kind {
                case .flower, .fruit:
                    guard let iid = UUID(uuidString: obj.id).map(ItemID.init) else { continue }
                    #expect(state.items[iid]?.placement == .attached(.ground(x: x)),
                            "item saved x \(obj.x): \(String(describing: state.items[iid]?.placement))")
                case .plank: expectedPlanks.append(x)
                case .ladder: expectedLadders.append(x)
                }
            }
            let planks = state.planks.planks.values.compactMap { p -> Double? in
                if case let .loose(.ground(x)) = p { return x }
                return nil
            }
            let ladders = state.ladders.ladders.values.compactMap { l -> Double? in
                if case let .loose(.ground(x)) = l { return x }
                return nil
            }
            #expect(state.planks.planks.count == expectedPlanks.count)
            #expect(planks.sorted() == expectedPlanks.sorted(), "planks \(planks) expected \(expectedPlanks)")
            #expect(state.ladders.ladders.count == expectedLadders.count)
            #expect(ladders.sorted() == expectedLadders.sorted(), "ladders \(ladders) expected \(expectedLadders)")
        }
    }

    // MARK: - 屏幕变化（Requirement 23.8）

    // Feature: v1, Property 39: 启动落位与屏幕夹紧
    @Test func groundObjectsClampedIntoNewGroundAfterScreenChange() async {
        let xs = Gen<Double>.double(in: 0...1).array(of: 0...6)
        await propertyCheck(count: 100, input: Gen.screen, Gen.screen, xs, xs, xs, Gen<Double>.double(in: 0...1).array(of: 2)) {
            old, new, itemXs, plankXs, ladderXs, residentXs in
            let (lo, hi) = Self.groundSpan(old)
            func onOld(_ u: Double) -> Double { lo + (hi - lo) * u }

            var source = FakeWindowSource(windows: [])
            var now = Date(timeIntervalSince1970: 1_900_000_000)
            let engine = WorldEngine(clockStart: now, screen: old, rng: RandomSource(seed: 3),
                                     demoResident: false, story: false)
            for (id, u) in zip(ResidentID.allCases, residentXs) {
                engine.place(Resident(id: id, attachment: .ground(x: onOld(u)),
                                      wander: WanderState(pauseRemaining: 10_000)))
            }
            var items: [(ItemID, Double, Double)] = []
            for (i, u) in itemXs.enumerated() {
                let item = i % 2 == 0
                    ? Item.fruit(placement: .attached(.ground(x: onOld(u))))
                    : Item.flowerPot(storyRound: nil, placement: .attached(.ground(x: onOld(u))))
                engine.insertItem(item)
                items.append((item.id, onOld(u), SpriteMetrics.itemSize(item.kind).width))
            }
            let planks = plankXs.map { (engine.insertPlank(.loose(.ground(x: onOld($0)))), onOld($0)) }
            let ladders = ladderXs.map { (engine.insertLadder(.loose(.ground(x: onOld($0)))), onOld($0)) }

            Self.step(engine, &source, old, &now)
            let before = engine.state
            Self.step(engine, &source, new, &now)
            let after = engine.state
            #expect(engine.invariantViolations().isEmpty)

            func check(_ a: CoreAttachment?, was: CoreAttachment?, width: Double, label: String) {
                guard case let .ground(x0)? = was else { return }
                let expected = Self.refFullyInside(x0, width: width, new)
                #expect(a == .ground(x: expected), "\(label) x \(x0) → \(String(describing: a)), expected \(expected)")
                let (nlo, nhi) = Self.groundSpan(new)
                if nhi - nlo >= width {
                    #expect(expected - width / 2 >= nlo - 1e-9 && expected + width / 2 <= nhi + 1e-9)
                }
            }
            for id in ResidentID.allCases {
                check(after.residents[id]?.attachment, was: before.residents[id]?.attachment,
                      width: SpriteMetrics.resident.width, label: "resident \(id)")
            }
            for (iid, _, w) in items {
                guard case let .attached(a)? = after.items[iid]?.placement,
                      case let .attached(b)? = before.items[iid]?.placement else {
                    Issue.record("item \(iid) not attached")
                    continue
                }
                check(a, was: b, width: w, label: "item")
            }
            for (pid, _) in planks {
                guard case let .loose(a)? = after.planks.planks[pid],
                      case let .loose(b)? = before.planks.planks[pid] else {
                    Issue.record("plank \(pid) not loose")
                    continue
                }
                check(a, was: b, width: SpriteMetrics.loosePlankLength, label: "plank")
            }
            for (lid, _) in ladders {
                guard case let .loose(a)? = after.ladders.ladders[lid],
                      case let .loose(b)? = before.ladders.ladders[lid] else {
                    Issue.record("ladder \(lid) not loose")
                    continue
                }
                check(a, was: b, width: SpriteMetrics.looseLadderLength, label: "ladder")
            }
        }
    }
}
