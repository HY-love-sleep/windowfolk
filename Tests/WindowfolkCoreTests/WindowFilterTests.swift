import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

struct WindowFilterTests {
    /// 参考谓词，独立于 `WindowFilter.isEligible` 按 Property 1 的文字直接写出。
    static func referenceEligible(_ r: RawWindowInfo, ownPID: Int32, screen: ScreenInfo, minSize: Double) -> Bool {
        let b = r.bounds
        let cx = b.minX + b.width / 2
        let cy = b.minY + b.height / 2
        let f = screen.frame
        return r.layer == 0
            && r.alpha > 0
            && b.width >= minSize && b.height >= minSize
            && r.ownerPID != ownPID
            && cx >= f.minX && cx <= f.minX + f.width
            && cy >= f.minY && cy <= f.minY + f.height
    }

    // Feature: v1, Property 1: 窗口过滤
    // **Validates: Requirements 1.6, 2.1, 2.6, 2.7**
    @Test func windowFiltering() async {
        let minSize = Tunables().minWindowSize
        await propertyCheck(
            count: 100,
            input: Gen.screen,
            Gen.rawWindowList(firstID: 1),
            Gen.rawWindowList(firstID: 1000, count: 0...5)  // 最小化或其他桌面空间的窗口
        ) { screen, onScreen, offScreen in
            let all = onScreen + offScreen
            let result = WindowFilter.makeResult(
                onScreen: onScreen, all: all, ownPID: testOwnPID, screen: screen, minSize: minSize)

            guard case let .success(eligible, existingIDs) = result else {
                Issue.record("makeResult 应总是返回 .success")
                return
            }

            let expected = onScreen.filter {
                Self.referenceEligible($0, ownPID: testOwnPID, screen: screen, minSize: minSize)
            }
            // 恰好是满足条件的窗口，保持前后顺序
            #expect(eligible.map(\.id) == expected.map(\.id))
            // zIndex 从 0 连续编号
            #expect(eligible.map(\.zIndex) == Array(0..<eligible.count))
            // 其余字段原样保留
            for (snap, raw) in zip(eligible, expected) {
                #expect(snap.frame == raw.bounds)
                #expect(snap.ownerName == raw.ownerName)
                #expect(snap.ownerPID == raw.ownerPID)
            }
            // existingIDs 恰好是全部窗口列表的 ID 集合
            #expect(existingIDs == Set(all.map(\.id)))
        }
    }

    // MARK: - Property 2

    static let pollScreen = ResidentFollowAndFallTests.screen
    static let frameDT = 1.0 / 30

    /// 确定性的 ItemID，让同一输入总得到同一世界。
    static func itemID(_ n: Int) -> ItemID {
        ItemID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
    }

    /// 由窗口布局和一组整数参数搭一个随机世界：两位居民、若干物件（窗沿上或被持有）、
    /// 木板和梯子。参数不合理的对象（例如木板超长、窗沿被遮住）在热身阶段自然失效或下落。
    static func buildWorld(_ engine: WorldEngine, windows: [WindowSnapshot], params: [Int]) {
        func p(_ i: Int) -> Int { params[i % params.count] }
        func offset(_ w: WindowSnapshot, _ k: Int) -> Double { w.frame.width * Double(p(k) % 101) / 100 }
        guard !windows.isEmpty else {
            engine.place(Resident(id: .a, attachment: .ground(x: 300), wander: WanderState(pauseRemaining: 10_000)))
            return
        }
        func win(_ k: Int) -> WindowSnapshot { windows[p(k) % windows.count] }

        for (n, rid) in ResidentID.allCases.enumerated() {
            let w = win(n * 2)
            engine.place(BridgeHangTests.idle(rid, window: w.id, offset: offset(w, n * 2 + 1)))
        }
        // 一位居民可能持有一个物件。
        if p(4) % 2 == 0 {
            _ = engine.give(.flowerPot(id: itemID(100), placement: .attached(.ground(x: 0))), to: .a)
        }
        // 窗沿上的物件 0 到 3 个。
        for i in 0 ..< p(5) % 4 {
            let w = win(6 + i * 2)
            engine.insertItem(.fruit(id: itemID(i + 1), placement: .attached(.window(w.id, offset: offset(w, 7 + i * 2)))))
        }
        // 木板：两个不同窗口之间。
        if windows.count >= 2 {
            for i in 0 ..< p(14) % 3 {
                let a = win(15 + i * 4), b = win(16 + i * 4)
                guard a.id != b.id else { continue }
                engine.insertPlank(.placed(PlacedPlank(
                    id: PlankID(0),
                    endA: PlankEnd(window: a.id, offset: offset(a, 17 + i * 4)),
                    endB: PlankEnd(window: b.id, offset: offset(b, 18 + i * 4)))))
            }
        }
        // 梯子：上端在某个窗口上，下端在下一次 step 中按上端重新计算。
        for i in 0 ..< p(27) % 3 {
            let w = win(28 + i * 2)
            let top = PlankEnd(window: w.id, offset: offset(w, 29 + i * 2))
            engine.insertLadder(.placed(PlacedLadder(
                id: LadderID(0), top: top, bottomSurface: .ground,
                bottom: Point(x: w.frame.minX + top.offset, y: pollScreen.groundY))))
        }
    }

    /// 读取失败期间真实窗口可能发生的变化（失败的轮询看不到这些变化）。
    static func mutate(_ source: inout FakeWindowSource, ids: [WindowID], op: Int) {
        guard !ids.isEmpty else { return }
        let id = ids[(op / 4) % ids.count]
        switch op % 4 {
        case 0: source.close(id)
        case 1: source.hide(id)
        case 2: source.move(id, to: Point(x: Double(op % 900), y: Double(op % 600)))
        default: source.resize(id, to: (120, 120))
        }
    }

    // Feature: v1, Property 2: 读取失败不改变世界
    // **Validates: Requirements 2.8**
    @Test func failedPollLeavesWorldUnchanged() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen<Int>.int(in: 0...9_999).array(of: 40),
            Gen<Int>.int(in: 1...20),
            Gen<Int>.int(in: 0...9_999).array(of: 0...6)
        ) { layout, params, failures, ops in
            let windows = Array(layout.prefix(12))
            var source = FakeWindowSource(snapshots: windows)
            var now = Date(timeIntervalSince1970: 3_000_000)
            let engine = WorldEngine(clockStart: now, screen: Self.pollScreen,
                                     rng: RandomSource(seed: 7), demoResident: false)
            Self.buildWorld(engine, windows: windows, params: params)

            // 热身：用成功的轮询让木板、梯子校验完毕，下落的对象全部落地。
            for _ in 0 ..< 120 {
                now = now.addingTimeInterval(Self.frameDT)
                engine.step(FrameInput(poll: source.poll(), screen: Self.pollScreen, now: now))
            }
            let before = engine.state
            let knownIDs = Set(before.windows.records.keys)

            // 读取失败期间，真实窗口被关闭、隐藏、移动或缩放。
            let ids = windows.map(\.id)
            for op in ops { Self.mutate(&source, ids: ids, op: op) }

            // 失败轮询：dt = 0（时钟读数不变），把世界的变化完全归因于这些轮询。
            for _ in 0 ..< failures {
                let out = engine.step(FrameInput(poll: .failure, screen: Self.pollScreen, now: now))
                #expect(out.windowChanges == .none)
                #expect(out.failedPlanks.isEmpty)
                #expect(out.failedLadders.isEmpty)
            }
            let after = engine.state
            #expect(after.windows == before.windows)
            #expect(after.planks == before.planks)
            #expect(after.ladders == before.ladders)
            #expect(after.items == before.items)
            for id in ResidentID.allCases {
                let b = before.residents[id], a = after.residents[id]
                #expect(a?.attachment == b?.attachment)
                #expect(a?.state == b?.state)
                #expect(a?.heldItem == b?.heldItem)
                #expect(a?.hangElapsed == b?.hangElapsed)
            }
            #expect(engine.invariantViolations().isEmpty)

            // 下一次成功轮询照常处理：失败期间被关闭的已知窗口在这次报告为关闭。
            now = now.addingTimeInterval(Self.frameDT)
            let out = engine.step(FrameInput(poll: source.poll(), screen: Self.pollScreen, now: now))
            let stillExisting: Set<WindowID>
            if case let .success(_, existing) = source.poll() { stillExisting = existing } else { stillExisting = [] }
            #expect(Set(out.windowChanges.closed.map(\.id)) == knownIDs.subtracting(stillExisting))
        }
    }
}
