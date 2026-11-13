import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// V2 任务 10.8：启动落位扩展到 Decor（Property 47）。
///
/// 参考实现独立于 `SaveSnapshot.restore` 和 `Physics.clampX`：
/// - Ground 水平范围 = 主显示器 frame 与 `visibleFrame` 的水平交集，Decor 落点是保存 x 夹紧到该范围；
/// - Decor 只落在 Ground 上，即使下落路径上有窗沿；落地是被动下落，不写 `decor_placed`；
/// - 居民恢复后处于下落状态，落地那一帧不处于 sitting、sleeping、running，Walk_Distance 等于保存值
///   （存档缺少的居民为 0）。落地之后居民会自行闲逛并累计 Walk_Distance，所以只在恢复帧和落地帧检查。
///
/// 每次迭代只用一个屏幕（引擎初始化与每帧输入相同），屏幕不变化，引擎不做 Ground 对象的屏幕变化夹紧。
struct RestoreLandingV2Tests {
    /// 把 x 夹紧到 Ground 水平范围内。
    fileprivate static func refClampToScreen(_ x: Double, _ s: ScreenInfo) -> Double {
        let lo = max(s.frame.minX, s.visibleFrame.minX), hi = min(s.frame.maxX, s.visibleFrame.maxX)
        return min(max(x, lo), hi)
    }

    /// 只保留中心点在主显示器内的窗口（Eligible_Window），并重新编号 zIndex。
    fileprivate static func eligible(_ layout: [WindowSnapshot], _ s: ScreenInfo) -> [WindowSnapshot] {
        layout.filter { w in
            let cx = w.frame.minX + w.frame.width / 2, cy = w.frame.minY + w.frame.height / 2
            return cx >= s.frame.minX && cx <= s.frame.maxX && cy >= s.frame.minY && cy <= s.frame.maxY
        }.enumerated().map { i, w in
            var w = w
            w.zIndex = i
            return w
        }
    }

    fileprivate static let busy: Set<ResidentState> = [.sitting, .sleeping, .running]

    // Feature: V2, Property 47: 启动落位扩展到 Decor
    // **Validates: Requirements 15.2, 15.10**
    @Test func restoredDecorsLandOnGroundAndResidentsKeepWalkDistance() async {
        await propertyCheck(count: 100, input: Gen.saveFile, Gen.windowLayout, Gen.screen) { save, layout, screen in
            let windows = Self.eligible(layout, screen)
            var source = FakeWindowSource(windows: windows.map { FakeWindow(snapshot: $0) })
            var now = Date(timeIntervalSince1970: 1_900_000_000)
            let engine = WorldEngine(clockStart: now, screen: screen, rng: RandomSource(seed: 11),
                                     demoResident: false, story: false, restored: save)
            func step() -> [EventRecord] {
                now = now.addingTimeInterval(0.1)
                return engine.step(FrameInput(poll: source.poll(), screen: screen, now: now)).events
            }

            let savedDecors = save.groundObjects.compactMap { o -> (DecorType, Double)? in
                switch o.kind {
                case .chair: return (.chair, Self.refClampToScreen(o.x, screen))
                case .lamp: return (.lamp, Self.refClampToScreen(o.x, screen))
                default: return nil
                }
            }
            var savedWalk: [ResidentID: Double] = [:]
            for r in save.residents where savedWalk[r.id] == nil { savedWalk[r.id] = r.walkDistance }

            // 恢复帧：居民在下落中、Walk_Distance 已恢复；仍在下落的 Decor 都受「只落 Ground」限制。
            var events = step()
            let first = engine.state
            #expect(first.decors.decors.count == savedDecors.count)
            for id in ResidentID.allCases {
                guard let r = first.residents[id] else {
                    Issue.record("resident \(id) missing after restore")
                    continue
                }
                #expect(!Self.busy.contains(r.state), "resident \(id) state \(r.state) after restore")
                #expect(r.walkDistance == (savedWalk[id] ?? 0),
                        "resident \(id) walk \(r.walkDistance) expected \(savedWalk[id] ?? 0)")
            }
            for (did, d) in first.decors.decors {
                if case .falling = d.placement {
                    #expect(engine.restoreLanding.decors.contains(did), "decor \(did) falling without Ground limit")
                }
            }

            // 推进到全部落地（每帧 0.1 秒，共 2.5 秒）；记录每位居民落地那一帧的状态和 Walk_Distance。
            var landed: [ResidentID: (ResidentState, Double)] = [:]
            for (id, r) in first.residents where r.state != .falling { landed[id] = (r.state, r.walkDistance) }
            for _ in 0..<24 {
                events += step()
                for (id, r) in engine.state.residents where landed[id] == nil && r.state != .falling {
                    landed[id] = (r.state, r.walkDistance)
                }
            }
            let state = engine.state

            for id in ResidentID.allCases {
                guard let (st, walk) = landed[id] else {
                    Issue.record("resident \(id) still falling")
                    continue
                }
                #expect(!Self.busy.contains(st), "resident \(id) landed in state \(st)")
                #expect(walk == (savedWalk[id] ?? 0), "resident \(id) landed with walk \(walk)")
            }

            // Decor：全部落在 Ground 上保存 x（夹紧到屏幕范围）处，与存档逐一对应（按 ID 顺序即存档顺序）。
            let actual = state.decors.sortedIDs.compactMap { did -> (DecorType, CoreAttachment?)? in
                guard let d = state.decors.decors[did] else { return nil }
                if case let .attached(a) = d.placement { return (d.type, a) }
                return (d.type, nil)
            }
            #expect(actual.count == savedDecors.count)
            for (i, (a, e)) in zip(actual, savedDecors).enumerated() {
                #expect(a.0 == e.0 && a.1 == .ground(x: e.1),
                        "decor #\(i) \(a.0) at \(String(describing: a.1)), expected \(e.0) on ground x \(e.1)")
            }
            #expect(engine.restoreLanding.decors.isEmpty)
            #expect(!events.contains { $0.type == .decorPlaced }, "decor_placed written during restore landing")
        }
    }
}
