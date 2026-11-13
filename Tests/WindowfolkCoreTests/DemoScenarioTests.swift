import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 13.14：演示流程场景测试（Requirement 28.6、28.8、28.9）。
///
/// 用 FakeWindowSource、手动时钟和合成的鼠标事件驱动 `WorldEngine(story: true)`，命令只用「快进」。
///
/// V2（任务 7.4，design.md「v1 属性的调整」）：开局只分配家，送花由第一帧的 `triggerWish(.flower, nil)` 启动；
/// 进入 Done 的同一次更新中 Flower_Wish 完成、Story_Stage 清为 nil，两人庆祝后恢复自主活动。
///
/// 布局：屏幕 1440×900，Ground y = 825。两个窗口 300×150，上沿 y = 650（离 Ground 175pt，
/// 大于 Drop_Max_Height 所以不能直接跳下，小于 Ladder_Length 所以梯子够长）。
/// - 窗口 1（都都的家）x 100…400；窗口 2（嘟嘟的家）开始在 x 1000…1300，相距太远。
/// - 拉近：窗口 2 移到 x 500，两窗口相距 100pt，木板架在 (400, 650)–(500, 650)。
/// - 都都上桥后把窗口 2 拖到 x 900：跨度 500pt，木板失效，都都悬挂后落到 Ground。
/// - 从 Toolbox 拖梯子搭到窗口 2 上沿 x 1000，下端在 Ground，长 175pt。
struct DemoScenarioTests {
    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    static let dt = 1.0 / 30
    static let ledgeY = 650.0

    static func win(_ id: WindowID, x: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: ledgeY, width: 300, height: 150), zIndex: 0)
    }

    /// 在某个剧情阶段第一次出现时隐藏一组窗口若干帧再显示（模拟切换桌面空间或最小化）。
    struct HidePlan {
        var windows: [WindowID]
        var stage: StoryStage
        var frames: Int = 60
    }

    final class Demo {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var events: [EventRecord] = []
        var lastView: WorldView?
        var hidePlan: HidePlan?
        var hideDone = false
        var frameCount = 0

        init(hidePlan: HidePlan? = nil) {
            engine = WorldEngine(clockStart: now, screen: DemoScenarioTests.screen,
                                 rng: RandomSource(seed: 7), story: true)
            source = FakeWindowSource(snapshots: [DemoScenarioTests.win(1, x: 100),
                                                  DemoScenarioTests.win(2, x: 1000)])
            self.hidePlan = hidePlan
        }

        var story: StoryState { engine.state.story }
        func resident(_ id: ResidentID) -> Resident { engine.state.residents[id]! }

        @discardableResult
        func step(pointer: [PointerEvent] = [], commands: [Command] = [],
                  sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            let out = rawStep(pointer: pointer, commands: commands, sourceLocation: sourceLocation)
            maybeHide(sourceLocation: sourceLocation)
            return out
        }

        private func rawStep(pointer: [PointerEvent], commands: [Command],
                             sourceLocation: SourceLocation) -> StepOutput {
            now = now.addingTimeInterval(DemoScenarioTests.dt)
            frameCount += 1
            let out = engine.step(FrameInput(poll: source.poll(), screen: DemoScenarioTests.screen,
                                             pointer: pointer, commands: commands, now: now))
            let violations = engine.invariantViolations()
            #expect(violations.isEmpty, "\(violations)", sourceLocation: sourceLocation)
            events += out.events
            lastView = out.view
            return out
        }

        /// 跑到条件成立，最多 `limit` 帧；返回条件是否成立。
        @discardableResult
        func run(until cond: () -> Bool, limit: Int = 900) -> Bool {
            var n = 0
            while !cond(), n < limit { step(); n += 1 }
            return cond()
        }

        /// 附着在窗口上的居民和物件的 offset。
        func windowOffsets(_ ids: [WindowID]) -> [String: Double] {
            var result: [String: Double] = [:]
            for (rid, r) in engine.state.residents {
                if case let .window(w, offset) = r.attachment, ids.contains(w) { result[rid.rawValue] = offset }
            }
            for (iid, item) in engine.state.items.items {
                if case let .attached(.window(w, offset)) = item.placement, ids.contains(w) {
                    result[iid.rawValue.uuidString] = offset
                }
            }
            return result
        }

        private func maybeHide(sourceLocation: SourceLocation) {
            guard let plan = hidePlan, !hideDone, story.stage == plan.stage else { return }
            hideDone = true
            let before = windowOffsets(plan.windows)
            #expect(!before.isEmpty, "隐藏的窗口上应有居民或物件", sourceLocation: sourceLocation)
            let statesBefore = engine.state.residents.mapValues(\.state)
            let heldBefore = engine.state.residents.mapValues(\.heldItem)
            for w in plan.windows { source.hide(w) }
            for _ in 0 ..< plan.frames {
                _ = rawStep(pointer: [], commands: [], sourceLocation: sourceLocation)
                // 隐藏期间：附着在隐藏窗口上的对象 Attachment 不变，居民不下落、保持状态和持有物。
                #expect(windowOffsets(plan.windows) == before, sourceLocation: sourceLocation)
                for (rid, r) in engine.state.residents {
                    guard case let .window(w, _) = r.attachment, plan.windows.contains(w) else { continue }
                    #expect(r.state == statesBefore[rid], sourceLocation: sourceLocation)
                    #expect(r.heldItem == heldBefore[rid], sourceLocation: sourceLocation)
                }
            }
            for w in plan.windows { source.show(w) }
            _ = rawStep(pointer: [], commands: [], sourceLocation: sourceLocation)
            // 重新显示后偏移与隐藏前相差不超过 1pt；居民在显示的这一帧自己走动的距离不计入（Requirement 4.5）。
            let after = windowOffsets(plan.windows)
            let selfMotion = engine.constants.walkSpeed * DemoScenarioTests.dt
            for (key, offset) in before {
                guard let now = after[key] else {
                    Issue.record("\(key) 重新显示后不在原窗口上", sourceLocation: sourceLocation); continue
                }
                let isResident = ResidentID(rawValue: key) != nil
                #expect(abs(now - offset) <= 1 + (isResident ? selfMotion : 0), "\(key): \(offset) → \(now)",
                        sourceLocation: sourceLocation)
            }
        }

        /// 从 Toolbox 的取物区拖到 `target` 松开。最后一帧移动后检查预览为绿色。
        func drag(from zone: ToolboxZone, to target: Point, sourceLocation: SourceLocation = #_sourceLocation) {
            let z = ToolboxLayout.zoneFrame(zone, screen: DemoScenarioTests.screen)
            let start = Point(x: z.midX, y: z.midY)
            step(pointer: [.down(start)])
            let steps = 6
            for i in 1 ... steps {
                let t = Double(i) / Double(steps)
                let p = Point(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
                step(pointer: [.moved(p)])
            }
            #expect(lastView?.preview?.isValid == true, "预览应为绿色：\(String(describing: lastView?.preview))",
                    sourceLocation: sourceLocation)
            step(pointer: [.up(target)])
        }
    }

    // MARK: - 完整演示流程

    /// 跑完 Requirement 28.6 的全部流程。
    static func runDemo(_ d: Demo) {
        // 1. 两个窗口相距很远：都都住左边，嘟嘟住右边；触发送花后都都抱着花盆许愿，无通路而等待。
        d.step(commands: [.triggerWish(.flower, nil)])
        #expect(d.story.homes == [.a: 1, .b: 2])
        #expect(d.story.round == 1)
        let flower = d.story.currentFlower
        #expect(flower != nil)
        #expect(d.resident(.a).heldItem == flower)
        #expect(d.run(until: { d.story.stage == .waiting && d.resident(.a).state == .waiting }, limit: 120))
        #expect(d.resident(.a).bubble == .wish(receiver: .b))

        // 2. 拉近窗口，从 Toolbox 拖出木板架在两窗沿之间：进入 Travel，都都走上木板。
        d.source.move(2, to: Point(x: 500, y: ledgeY))
        d.step()
        d.drag(from: .plank, to: Point(x: 450, y: ledgeY - 10))
        #expect(d.engine.state.planks.planks.values.contains { $0.placed != nil })
        #expect(d.run(until: {
            if case .plank = d.resident(.a).attachment { return d.story.stage == .travel }
            return false
        }), "都都应走上木板：\(d.resident(.a).attachment) \(String(describing: d.story.stage))")
        // 再走几帧，离开木板端点。
        for _ in 0 ..< 10 { d.step() }
        guard case .plank = d.resident(.a).attachment else {
            Issue.record("都都应在木板上：\(d.resident(.a).attachment)"); return
        }

        // 3. 拖开窗口 2：木板失效，都都挂在桥边 Hang_Duration 后掉到 Ground，花盆仍在手上。
        d.source.move(2, to: Point(x: 900, y: ledgeY))
        d.step()
        #expect(d.resident(.a).state == .hanging)
        let hangStart = d.frameCount
        #expect(d.run(until: { d.resident(.a).state == .falling }, limit: 120))
        let hangSeconds = Double(d.frameCount - hangStart) * dt
        #expect(abs(hangSeconds - d.engine.constants.hangDuration) <= 0.1 + dt, "悬挂 \(hangSeconds) 秒")
        #expect(d.resident(.a).heldItem == flower)
        #expect(d.run(until: { d.resident(.a).state != .falling }, limit: 90))
        guard case .ground = d.resident(.a).attachment else {
            Issue.record("都都应落在 Ground 上：\(d.resident(.a).attachment)"); return
        }
        #expect(d.resident(.a).heldItem == flower)
        #expect(d.run(until: { d.story.stage == .waiting }, limit: 5))
        #expect(d.run(until: { d.resident(.a).state == .waiting }, limit: 60))
        #expect(d.resident(.a).bubble == .wish(receiver: .b))

        // 4. 都都在 Ground 上张望；从 Toolbox 拖梯子搭到嘟嘟的窗沿：都都爬上去把花送到。
        for _ in 0 ..< 30 { d.step() }
        d.drag(from: .ladder, to: Point(x: 1000, y: ledgeY - 10))
        #expect(d.engine.state.ladders.ladders.values.contains { $0.placed != nil })
        var climbed = false
        #expect(d.run(until: {
            if d.resident(.a).state == .climbing { climbed = true }
            return d.story.stage == .planting
        }), "应进入 Planting：\(String(describing: d.story.stage)) \(d.resident(.a).state)")
        #expect(climbed)
        #expect(d.resident(.a).state == .planting && d.resident(.b).state == .planting)

        // 5. 种花 → Growing；快进两次开花 → ReturnGift；嘟嘟带着果子找到都都 → Done，庆祝。
        #expect(d.run(until: { d.story.stage == .growing }, limit: 150))
        if let f = flower {
            #expect(d.engine.state.items.items[f]?.placement.isHeld == false)
        }
        d.step(commands: [.fastForward])
        d.step(commands: [.fastForward])
        let fruit = d.story.currentFruit
        #expect(fruit != nil)
        if d.hidePlan?.stage != .returnGift {
            // 隐藏变体会在进入 ReturnGift 的这一帧之后插入隐藏帧，这里只在普通流程中检查。
            #expect(d.story.stage == .returnGift)
            #expect(d.resident(.b).heldItem == fruit)
        }
        var celebrated = false
        #expect(d.run(until: {
            if d.resident(.a).state == .celebrating, d.resident(.b).state == .celebrating { celebrated = true }
            return d.events.contains { $0.type == .wishFulfilled }
        }))
        #expect(d.story.stage == nil && d.engine.state.wishes.active.isEmpty)
        if d.resident(.a).state == .celebrating, d.resident(.b).state == .celebrating { celebrated = true }
        #expect(celebrated)
        // 果子留在都都所在的 Surface 上。
        if let fr = fruit, let item = d.engine.state.items.items[fr] {
            guard case let .attached(att) = item.placement else {
                Issue.record("果子应放在 Surface 上：\(item.placement)"); return
            }
            #expect(sameSurface(att, d.resident(.a).attachment), "\(att) vs \(d.resident(.a).attachment)")
        } else {
            Issue.record("果子应还在场上")
        }
        // 庆祝结束后两人恢复自主活动（可能同一帧就开始走动，因此只检查已离开 celebrating）。
        #expect(d.run(until: {
            d.resident(.a).state != .celebrating && d.resident(.b).state != .celebrating
        }, limit: 300))

        // 事件记录按顺序包含演示中的关键事件。
        let expected: [EventType] = [.wishStarted, .roundStarted, .plankPlaced, .fell, .landed, .ladderPlaced,
                                     .climbedLadder, .planted, .sprouted, .bloomed, .giftDelivered,
                                     .wishFulfilled]
        #expect(isSubsequence(expected, of: d.events.map(\.type)), "\(d.events.map(\.type.rawValue))")
    }

    static func sameSurface(_ a: CoreAttachment, _ b: CoreAttachment) -> Bool {
        switch (a, b) {
        case let (.window(w1, _), .window(w2, _)): return w1 == w2
        case (.ground, .ground): return true
        case let (.plank(p1, _), .plank(p2, _)): return p1 == p2
        default: return false
        }
    }

    static func isSubsequence(_ needle: [EventType], of hay: [EventType]) -> Bool {
        var i = needle.startIndex
        for t in hay where i < needle.endIndex && t == needle[i] { i += 1 }
        return i == needle.endIndex
    }

    @Test func demoFlowCompletes() {
        Self.runDemo(Demo())
    }

    @Test func demoFlowIsDeterministicAcrossRuns() {
        // Requirement 28.7：三次独立运行都完成全部步骤。
        for _ in 0 ..< 3 { Self.runDemo(Demo()) }
    }

    // MARK: - 中途切换桌面空间或最小化（Requirement 28.8、28.9）

    @Test(arguments: [
        HidePlan(windows: [1], stage: .waiting),
        HidePlan(windows: [1, 2], stage: .travel),
        HidePlan(windows: [2], stage: .planting),
        HidePlan(windows: [1, 2], stage: .growing),
        HidePlan(windows: [2], stage: .returnGift),
    ])
    func demoFlowSurvivesHidingHomeWindow(_ plan: HidePlan) {
        let d = Demo(hidePlan: plan)
        Self.runDemo(d)
        #expect(d.hideDone)
    }
}

extension DemoScenarioTests.HidePlan: CustomTestStringConvertible {
    var testDescription: String { "hide \(windows) at \(stage)" }
}

extension DemoScenarioTests.HidePlan: Sendable {}

private extension ItemPlacement {
    var isHeld: Bool {
        if case .held = self { return true }
        return false
    }
}
