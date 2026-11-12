import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 任务 5.7：居民跟随窗口与掉落的单元测试。用 FakeWindowSource 和手动时钟驱动 WorldEngine.step，
/// 每次 step 后都检查无悬空不变量。
struct ResidentFollowAndFallTests {
    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    static let groundY = 825.0

    static func win(_ id: WindowID, x: Double, y: Double, w: Double, h: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: 0)
    }

    /// 测试驱动：持有引擎、假窗口源和手动时钟。
    final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now: Date

        init(_ windows: [WindowSnapshot]) {
            now = Date(timeIntervalSince1970: 1_000_000)
            engine = WorldEngine(clockStart: now, screen: ResidentFollowAndFallTests.screen,
                                 rng: RandomSource(seed: 7), demoResident: false)
            source = FakeWindowSource(windows: windows.map { FakeWindow(snapshot: $0) })
        }

        /// 放一位不会自己走动的居民（很长的停顿），使偏移量只因窗口变化而改变。
        /// 注：`Attachment` 与 Testing.Attachment 重名，模块里又有同名的 `WindowfolkCore` 枚举无法限定，
        /// 所以这里直接收窗口 ID 和偏移量。
        func placeIdle(_ id: ResidentID = .a, window: WindowID, offset: Double) {
            engine.place(Resident(id: id, attachment: .window(window, offset: offset),
                                  wander: WanderState(pauseRemaining: 10_000)))
        }

        @discardableResult
        func step(_ dt: Double = 1.0 / 30, sourceLocation: SourceLocation = #_sourceLocation) -> StepOutput {
            now = now.addingTimeInterval(dt)
            let out = engine.step(FrameInput(poll: source.poll(), screen: ResidentFollowAndFallTests.screen, now: now))
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())",
                    sourceLocation: sourceLocation)
            return out
        }

        /// 一直推进到居民不再下落，最多 `maxFrames` 帧（2 秒）。
        func stepUntilLanded(_ id: ResidentID = .a, maxFrames: Int = 60) {
            for _ in 0 ..< maxFrames where resident(id).state == .falling { step() }
        }

        func resident(_ id: ResidentID = .a) -> Resident { engine.state.residents[id]! }
        func view(_ id: ResidentID = .a, in out: StepOutput) -> ResidentView {
            out.view.residents.first { $0.id == id }!
        }
    }

    // MARK: - 跟随窗口（Requirement 4.4）

    @Test func residentFollowsMovedWindow() {
        let h = Harness([Self.win(1, x: 100, y: 200, w: 400, h: 300)])
        h.placeIdle(window: 1, offset: 150)
        var out = h.step()
        #expect(h.view(in: out).position == Point(x: 250, y: 200))

        h.source.move(1, to: Point(x: 300, y: 100))
        out = h.step()
        #expect(h.resident().attachment == .window(1, offset: 150))
        #expect(h.resident().state == .idle)
        #expect(h.view(in: out).position == Point(x: 450, y: 100))
    }

    // MARK: - 关闭后掉落（Requirement 5.1）

    @Test func closingWindowDropsResidentOntoLowerLedge() {
        let h = Harness([
            Self.win(1, x: 100, y: 100, w: 400, h: 150),   // 上方窗口，居民所在
            Self.win(2, x: 50, y: 400, w: 600, h: 300),    // 下方窗口
        ])
        h.placeIdle(window: 1, offset: 100)               // x = 200
        h.step()
        h.source.close(1)
        h.step()
        #expect(h.resident().state == .falling)
        h.stepUntilLanded()
        #expect(h.resident().state == .idle)
        #expect(h.resident().attachment == .window(2, offset: 150))
    }

    @Test func closingWindowDropsResidentToGround() {
        let h = Harness([Self.win(1, x: 100, y: 200, w: 400, h: 300)])
        h.placeIdle(window: 1, offset: 100)
        h.step()
        h.source.close(1)
        h.step()
        #expect(h.resident().state == .falling)
        h.stepUntilLanded()
        #expect(h.resident().state == .idle)
        #expect(h.resident().attachment == .ground(x: 200))
        let out = h.step()
        #expect(h.view(in: out).position == Point(x: 200, y: Self.groundY))
    }

    // MARK: - 最小化不掉落、恢复后回到原偏移（Requirement 5.2、5.3、5.4、5.6）

    @Test func hiddenWindowResidentStaysAndResumesWithSameOffset() {
        let h = Harness([Self.win(1, x: 100, y: 200, w: 400, h: 300)])
        h.placeIdle(window: 1, offset: 120)
        h.step()
        let before = h.resident()

        h.source.hide(1)
        for _ in 0 ..< 90 {
            let out = h.step(0.25)
            let v = h.view(in: out)
            #expect(v.isHidden)
            #expect(v.position == nil)
        }
        #expect(h.resident() == before)                     // 状态、Attachment、计时全部不变

        // 隐藏期间窗口被挪走，恢复后按新位置和原偏移出现。
        h.source.move(1, to: Point(x: 500, y: 150))
        h.source.show(1)
        let out = h.step()
        #expect(h.resident().attachment == .window(1, offset: 120))
        #expect(h.resident().state != .falling)
        #expect(h.view(in: out).isHidden == false)
        #expect(h.view(in: out).position == Point(x: 620, y: 150))
    }

    @Test func showingNarrowedHiddenWindowClampsResident() {
        let h = Harness([Self.win(1, x: 100, y: 200, w: 400, h: 300)])
        h.placeIdle(window: 1, offset: 350)
        h.step()
        h.source.hide(1)
        h.step()
        h.source.resize(1, to: (200, 300))
        h.step()
        #expect(h.resident().attachment == .window(1, offset: 350))   // 隐藏期间不改
        h.source.show(1)
        h.step()
        #expect(h.resident().attachment == .window(1, offset: 200))
    }

    // MARK: - 夹紧（Requirement 4.6）

    @Test func narrowingWindowClampsResidentToLedge() {
        let h = Harness([Self.win(1, x: 100, y: 200, w: 400, h: 300)])
        h.placeIdle(window: 1, offset: 350)
        h.step()
        h.source.resize(1, to: (200, 300))
        let out = h.step()
        #expect(h.resident().attachment == .window(1, offset: 200))
        #expect(h.resident().state == .idle)
        #expect(h.view(in: out).position == Point(x: 300, y: 200))
    }

    @Test func partiallyCoveredLedgeClampsToNearestRemainingSegment() {
        let h = Harness([Self.win(1, x: 100, y: 300, w: 600, h: 300)])
        h.placeIdle(window: 1, offset: 250)               // x = 350
        h.step()
        // 前方窗口遮住上沿 [300, 500]，剩余 [100, 300] 和 [500, 700]；x = 350 离 300 最近。
        h.source.addInFront(Self.win(2, x: 300, y: 250, w: 200, h: 200))
        h.step()
        #expect(h.resident().attachment == .window(1, offset: 200))
        #expect(h.resident().state == .idle)
    }

    // MARK: - 完全遮挡时下落（Requirement 4.7）

    @Test func fullyCoveredLedgeMakesResidentFall() {
        let h = Harness([Self.win(1, x: 100, y: 300, w: 400, h: 300)])
        h.placeIdle(window: 1, offset: 250)               // x = 350
        h.step()
        h.source.addInFront(Self.win(2, x: 50, y: 250, w: 800, h: 400))
        h.step()
        #expect(h.resident().state == .falling)
        #expect(h.resident().attachment.windowID == nil)
        h.stepUntilLanded()
        #expect(h.resident().attachment == .ground(x: 350))
    }

    // MARK: - 隐藏期间关闭：从最后可见位置下落（Requirement 5.8）

    @Test func closedWhileHiddenFallsFromLastVisiblePosition() {
        let h = Harness([Self.win(1, x: 100, y: 200, w: 400, h: 300)])
        h.placeIdle(window: 1, offset: 120)               // 最后可见位置 x = 220
        h.step()
        h.source.hide(1)
        h.step()
        h.source.move(1, to: Point(x: 700, y: 100))        // 隐藏期间的移动不可见
        h.step()
        h.source.close(1)
        h.step()
        let r = h.resident()
        #expect(r.state == .falling)
        guard case let .free(p) = r.attachment else {
            Issue.record("expected free attachment, got \(r.attachment)"); return
        }
        #expect(p.x == 220)
        #expect(p.y >= 200 && p.y < Self.groundY)
        h.stepUntilLanded()
        #expect(h.resident().attachment == .ground(x: 220))
    }
}

/// 任务 11.8 起：Attachment 相关的属性测试（Property 6 至 9）。
struct AttachmentPropertyTests {
    static let screen = ResidentFollowAndFallTests.screen
    static let groundY = ResidentFollowAndFallTests.groundY
    static let width = 300.0, height = 120.0

    /// 两个并排、等高、互不遮挡的窗口，中间架一块木板（窗口 1 右端 → 窗口 2 左端）。
    /// 坐标取整数，避免浮点误差干扰精确比较。
    struct Scene: Sendable, CustomStringConvertible {
        var gap: Int              // 两窗口之间的水平间隙（木板跨度），≤ Plank_Max_Span
        var residentOffset: Int   // 都都在窗口 1 上的偏移
        var ladderOffset: Int     // 梯子上端在窗口 1 上的偏移
        var itemOffset: Int       // 果子在窗口 2 上的偏移
        var groundResidentX: Int  // 嘟嘟在 Ground 上的 x
        var groundItemX: Int      // 花盆在 Ground 上的 x
        var description: String {
            "gap \(gap) a@\(residentOffset) ladder@\(ladderOffset) fruit@\(itemOffset) "
                + "b@ground \(groundResidentX) pot@ground \(groundItemX)"
        }
    }

    /// 一次平移：两个窗口一起移到新的左上角（窗口 1 的位置），宽高不变、相对位置不变，
    /// 因此木板和梯子保持有效、上沿不被遮挡。y 范围让梯子长度保持在 (0, Ladder_Length] 内。
    struct Move: Sendable, CustomStringConvertible {
        var x: Int
        var y: Int
        var description: String { "(\(x), \(y))" }
    }

    static var scenes: Generator<Scene, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 40...150),
            Gen<Int>.int(in: 0...300),
            Gen<Int>.int(in: 0...300),
            Gen<Int>.int(in: 0...300),
            Gen<Int>.int(in: 0...1440),
            Gen<Int>.int(in: 0...1440)
        ).map { Scene(gap: $0, residentOffset: $1, ladderOffset: $2, itemOffset: $3,
                      groundResidentX: $4, groundItemX: $5) }
    }

    /// 窗口 1 的 x 范围保证两个窗口完整位于屏幕内（gap ≤ 150）。
    static var moves: Generator<[Move], some SendableSequenceType> {
        zip(Gen<Int>.int(in: 0...690), Gen<Int>.int(in: 640...760))
            .map { Move(x: $0, y: $1) }
            .array(of: 1...6)
    }

    static func snapshot(_ id: WindowID, x: Double, y: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: Int32(400 + Int(id)),
                       frame: Rect(minX: x, minY: y, width: width, height: height), zIndex: Int(id) - 1)
    }

    // Feature: v1, Property 6: 平移跟随
    // **Validates: Requirements 4.4, 4.5, 9.7, 23.7**
    @Test func translationKeepsOffsetsAndFollows() async {
        await propertyCheck(count: 100, input: Self.scenes, Self.moves) { scene, moves in
            let gap = Double(scene.gap)
            let startX = 100.0, startY = 700.0
            var source = FakeWindowSource(snapshots: [
                Self.snapshot(1, x: startX, y: startY),
                Self.snapshot(2, x: startX + Self.width + gap, y: startY),
            ])
            var now = Date(timeIntervalSince1970: 6_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: 11), demoResident: false)

            let resOff = Double(scene.residentOffset), ladOff = Double(scene.ladderOffset)
            let itemOff = Double(scene.itemOffset)
            let groundResX = Double(scene.groundResidentX), groundItemX = Double(scene.groundItemX)

            engine.place(Resident(id: .a, attachment: .window(1, offset: resOff),
                                  wander: WanderState(pauseRemaining: 10_000)))
            engine.place(Resident(id: .b, attachment: .ground(x: groundResX),
                                  wander: WanderState(pauseRemaining: 10_000)))
            let fruit = ItemID(), pot = ItemID()
            engine.insertItem(.fruit(id: fruit, placement: .attached(.window(2, offset: itemOff))))
            engine.insertItem(.flowerPot(id: pot, placement: .attached(.ground(x: groundItemX))))
            let pid = engine.insertPlank(.placed(PlacedPlank(
                id: PlankID(0), endA: PlankEnd(window: 1, offset: Self.width),
                endB: PlankEnd(window: 2, offset: 0))))
            let lid = engine.insertLadder(.placed(PlacedLadder(
                id: LadderID(0), top: PlankEnd(window: 1, offset: ladOff),
                bottomSurface: .ground, bottom: Point(x: startX + ladOff, y: Self.groundY))))

            /// 一次 step 之后检查：窗口上的对象 offset 不变、屏幕坐标等于新窗口位置加 offset；Ground 上的对象不动。
            func stepAndCheck(x1: Double, y: Double, label: String) {
                now = now.addingTimeInterval(1.0 / 30)
                let out = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: now))
                let x2 = x1 + Self.width + gap
                let s = engine.state

                // 居民
                #expect(s.residents[.a]?.attachment == .window(1, offset: resOff), "\(label)")
                #expect(s.residents[.a]?.state == .idle, "\(label)")
                #expect(out.view.residents.first { $0.id == .a }?.position == Point(x: x1 + resOff, y: y),
                        "\(label)")
                #expect(s.residents[.b]?.attachment == .ground(x: groundResX), "\(label)")
                #expect(out.view.residents.first { $0.id == .b }?.position
                    == Point(x: groundResX, y: Self.groundY), "\(label)")

                // 物件
                #expect(s.items[fruit]?.placement == .attached(.window(2, offset: itemOff)), "\(label)")
                #expect(out.view.items.first { $0.id == fruit }?.position == Point(x: x2 + itemOff, y: y),
                        "\(label)")
                #expect(s.items[pot]?.placement == .attached(.ground(x: groundItemX)), "\(label)")
                #expect(out.view.items.first { $0.id == pot }?.position
                    == Point(x: groundItemX, y: Self.groundY), "\(label)")

                // 木板两端
                if case let .placed(p)? = s.planks.planks[pid] {
                    #expect(p.endA == PlankEnd(window: 1, offset: Self.width), "\(label)")
                    #expect(p.endB == PlankEnd(window: 2, offset: 0), "\(label)")
                } else {
                    Issue.record("木板应保持架设：\(label)")
                }
                #expect(out.view.planks.first { $0.id == pid }?.shape
                    == .placed(left: Point(x: x1 + Self.width, y: y), right: Point(x: x2, y: y)), "\(label)")

                // 梯子上端
                if case let .placed(l)? = s.ladders.ladders[lid] {
                    #expect(l.top == PlankEnd(window: 1, offset: ladOff), "\(label)")
                } else {
                    Issue.record("梯子应保持架设：\(label)")
                }
                #expect(out.view.ladders.first { $0.id == lid }?.shape
                    == .placed(top: Point(x: x1 + ladOff, y: y), bottom: Point(x: x1 + ladOff, y: Self.groundY)),
                    "\(label)")
            }

            stepAndCheck(x1: startX, y: startY, label: "initial")
            for (i, m) in moves.enumerated() {
                let x1 = Double(m.x), y = Double(m.y)
                source.move(1, to: Point(x: x1, y: y))
                source.move(2, to: Point(x: x1 + Self.width + gap, y: y))
                stepAndCheck(x1: x1, y: y, label: "move \(i) to \(m)")
            }
        }
    }

    // MARK: - Property 7

    /// 窗口 1 的初始几何：上沿 [100, 700]，y = 300。
    static let clampWinX = 100.0, clampWinY = 300.0, clampWinW = 600.0, clampWinH = 300.0

    /// 放在窗口 1 前方的窗口。坐标取 10 的倍数，制造边界恰好相等（上下边等于 y = 300、左右边相接）的情况。
    struct FrontRect: Sendable, CustomStringConvertible {
        var x: Int, y: Int, w: Int, h: Int
        var description: String { "front(\(x), \(y), \(w)×\(h))" }
    }

    struct ClampCase: Sendable, CustomStringConvertible {
        var newWidth: Int         // 窗口 1 的新宽度（≤ 原宽度）
        var fronts: [FrontRect]
        var offsets: [Int]        // 都都、嘟嘟、果子、花盆的初始偏移
        var viaHidden: Bool       // true：先隐藏窗口 1，在隐藏期间改动，再重新显示（Requirement 5.7）
        var description: String {
            "width \(newWidth) fronts \(fronts) offsets \(offsets) viaHidden \(viaHidden)"
        }
    }

    static var clampCases: Generator<ClampCase, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 12...60).map { $0 * 10 },
            zip(Gen<Int>.int(in: 0...80), Gen<Int>.int(in: 10...40),
                Gen<Int>.int(in: 12...40), Gen<Int>.int(in: 12...30))
                .map { FrontRect(x: $0 * 10, y: $1 * 10, w: $2 * 10, h: $3 * 10) }
                .array(of: 0...3),
            Gen<Int>.int(in: 0...600).array(of: 4),
            Gen<Bool>.bool
        ).map { ClampCase(newWidth: $0, fronts: $1, offsets: $2, viaHidden: $3) }
    }

    /// 参考实现：直接按矩形计算窗口 1 上沿的剩余闭区间（不经过 SurfaceBuilder）。
    static func remainingIntervals(minX: Double, maxX: Double, y: Double, fronts: [Rect]) -> [(Double, Double)] {
        var pieces = [(minX, maxX)]
        for f in fronts where f.minY <= y && y <= f.maxY {
            pieces = pieces.flatMap { lo, hi -> [(Double, Double)] in
                var out: [(Double, Double)] = []
                if f.minX > lo { out.append((lo, min(hi, f.minX))) }
                if f.maxX < hi { out.append((max(lo, f.maxX), hi)) }
                return out
            }
        }
        return pieces.filter { $0.1 - $0.0 > 0 }
    }

    // Feature: v1, Property 7: 夹紧或下落
    // **Validates: Requirements 4.6, 4.7, 5.7**
    @Test func clampOrFall() async {
        await propertyCheck(count: 100, input: Self.clampCases) { c in
            var source = FakeWindowSource(snapshots: [
                WindowSnapshot(id: 1, ownerName: "App1", ownerPID: 401,
                               frame: Rect(minX: Self.clampWinX, minY: Self.clampWinY,
                                           width: Self.clampWinW, height: Self.clampWinH), zIndex: 0),
            ])
            var now = Date(timeIntervalSince1970: 7_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: 13), demoResident: false)
            func step() {
                now = now.addingTimeInterval(1.0 / 30)
                _ = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: now))
            }

            let offs = c.offsets.map(Double.init)
            engine.place(Resident(id: .a, attachment: .window(1, offset: offs[0]),
                                  wander: WanderState(pauseRemaining: 10_000)))
            engine.place(Resident(id: .b, attachment: .window(1, offset: offs[1]),
                                  wander: WanderState(pauseRemaining: 10_000)))
            let fruit = ItemID(), pot = ItemID()
            engine.insertItem(.fruit(id: fruit, placement: .attached(.window(1, offset: offs[2]))))
            engine.insertItem(.flowerPot(id: pot, placement: .attached(.window(1, offset: offs[3]))))
            step()

            // 起点：窗口 1 独占上沿，全部对象原地不动。
            #expect(engine.state.residents[.a]?.attachment == .window(1, offset: offs[0]))
            #expect(engine.state.residents[.b]?.attachment == .window(1, offset: offs[1]))
            #expect(engine.state.items[fruit]?.placement == .attached(.window(1, offset: offs[2])))
            #expect(engine.state.items[pot]?.placement == .attached(.window(1, offset: offs[3])))

            if c.viaHidden {
                source.hide(1)
                step()
            }
            let newWidth = Double(c.newWidth)
            source.resize(1, to: (newWidth, Self.clampWinH))
            let frontRects = c.fronts.map {
                Rect(minX: Double($0.x), minY: Double($0.y), width: Double($0.w), height: Double($0.h))
            }
            for (i, f) in frontRects.enumerated() {
                source.addInFront(WindowSnapshot(id: WindowID(10 + i), ownerName: "Front\(i)",
                                                 ownerPID: Int32(500 + i), frame: f, zIndex: 0))
            }
            step()
            if c.viaHidden {
                // 隐藏期间 Attachment 不变（Requirement 5.4），重新显示后才处理。
                #expect(engine.state.residents[.a]?.attachment == .window(1, offset: offs[0]))
                #expect(engine.state.items[pot]?.placement == .attached(.window(1, offset: offs[3])))
                source.show(1)
                step()
            }

            let remaining = Self.remainingIntervals(
                minX: Self.clampWinX, maxX: Self.clampWinX + newWidth, y: Self.clampWinY, fronts: frontRects)

            /// 检查一个对象 step 之后的偏移：有剩余窗沿时必须返回 Some(新偏移)，否则返回 nil 表示应下落。
            func checkOffset(_ original: Double, _ actual: Double?, label: String) {
                let x = Self.clampWinX + original
                guard let actual else {
                    Issue.record("\(label) 应仍附着在窗口 1 上（剩余 \(remaining)）"); return
                }
                let newX = Self.clampWinX + actual
                let inside = remaining.contains { $0.0 <= x && x <= $0.1 }
                if inside {
                    #expect(actual == original, "\(label)：原偏移在窗沿内应不变，剩余 \(remaining)")
                } else {
                    let best = remaining.map { x < $0.0 ? $0.0 - x : x - $0.1 }.min()!
                    #expect(remaining.contains { $0.0 <= newX && newX <= $0.1 },
                            "\(label)：新偏移 \(actual) 不在剩余窗沿 \(remaining) 内")
                    #expect(abs(newX - x) == best,
                            "\(label)：新 x \(newX) 不是离 \(x) 最近的点（最近距离 \(best)），剩余 \(remaining)")
                }
            }

            for (rid, off) in [(ResidentID.a, offs[0]), (.b, offs[1])] {
                let r = engine.state.residents[rid]!
                if remaining.isEmpty {
                    #expect(r.state == .falling, "居民 \(rid) 应下落")
                    #expect(r.attachment.windowID != 1, "居民 \(rid) 不应再附着在窗口 1 上")
                } else {
                    #expect(r.state == .idle, "居民 \(rid) 应保持 idle，实际 \(r.state)")
                    var offset: Double?
                    if case let .window(1, o) = r.attachment { offset = o }
                    checkOffset(off, offset, label: "居民 \(rid)")
                }
            }
            for (iid, off, name) in [(fruit, offs[2], "果子"), (pot, offs[3], "花盆")] {
                let placement = engine.state.items[iid]!.placement
                if remaining.isEmpty {
                    if case .falling = placement {} else {
                        Issue.record("\(name) 应下落，实际 \(placement)")
                    }
                } else {
                    var offset: Double?
                    if case let .attached(.window(1, o)) = placement { offset = o }
                    checkOffset(off, offset, label: name)
                }
            }
        }
    }
}

// MARK: - Property 8

extension AttachmentPropertyTests {
    /// 窗口 1（要隐藏的窗口）和窗口 2 并排、等高，中间架一块木板；窗口 3 在右上方，与两者都不重叠。
    /// 窗口 1 和 2 的上沿 y = 680，梯子从窗口 1 上沿到 Ground 长 145pt（≤ Ladder_Length）。
    static let hideY = 680.0, hideW1X = 100.0
    static let hideW3 = Rect(minX: 1000, minY: 100, width: 300, height: 200)

    /// 隐藏期间对其他窗口（2、3）的一次操作，之后推进若干帧。
    struct OtherOp: Sendable, CustomStringConvertible {
        var kind: Int             // 0 移动、1 缩放、2 移到最前、3 隐藏、4 显示
        var window: WindowID      // 2 或 3
        var a: Int, b: Int        // 移动的目标坐标或缩放的新尺寸
        var frames: Int           // 操作后推进的帧数
        var slow: Bool            // true：每帧 0.25 秒（dt 上限）；false：1/30 秒
        var description: String {
            let name = ["move", "resize", "front", "hide", "show"][kind]
            return "\(name)(w\(window), \(a), \(b)) ×\(frames)\(slow ? " slow" : "")"
        }
    }

    struct HideCase: Sendable, CustomStringConvertible {
        var gap: Int              // 窗口 1 与 2 的间隙（木板跨度）
        var walkerOffset: Int     // 都都（持有果子、走动中）在窗口 1 上的偏移
        var plankT: Int           // 嘟嘟（idle、长停顿）在木板上的位置，百分比
        var potOffset: Int        // 花盆在窗口 1 上的偏移
        var flowerT: Int          // 另一个花盆在木板上的位置，百分比
        var ladderOffset: Int     // 梯子上端在窗口 1 上的偏移
        var warmup: Int           // 隐藏前推进的帧数（让都都先走起来）
        var ops: [OtherOp]
        var description: String {
            "gap \(gap) walker@\(walkerOffset) b@plank \(plankT)% pot@\(potOffset) flower@plank \(flowerT)% "
                + "ladder@\(ladderOffset) warmup \(warmup) ops \(ops)"
        }
    }

    static var otherOps: Generator<[OtherOp], some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...4),
            Gen<Int>.int(in: 2...3),
            Gen<Int>.int(in: 0...1200),
            Gen<Int>.int(in: 120...700),
            Gen<Int>.int(in: 1...20),
            Gen<Bool>.bool
        ).map { OtherOp(kind: $0, window: WindowID($1), a: $2, b: $3, frames: $4, slow: $5) }
            .array(of: 0...8)
    }

    static var hideCases: Generator<HideCase, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 40...150),
            Gen<Int>.int(in: 20...280),
            Gen<Int>.int(in: 5...95),
            Gen<Int>.int(in: 0...300),
            Gen<Int>.int(in: 5...95),
            Gen<Int>.int(in: 0...300),
            Gen<Int>.int(in: 1...30),
            Self.otherOps
        ).map { HideCase(gap: $0, walkerOffset: $1, plankT: $2, potOffset: $3, flowerT: $4,
                         ladderOffset: $5, warmup: $6, ops: $7) }
    }

    // Feature: v1, Property 8: 隐藏再显示的往返
    // **Validates: Requirements 5.2, 5.3, 5.4, 5.6, 28.8, 28.9**
    @Test func hideShowRoundTrip() async {
        await propertyCheck(count: 100, input: Self.hideCases) { c in
            let gap = Double(c.gap)
            let w2X = Self.hideW1X + Self.width + gap
            let w2Original = Rect(minX: w2X, minY: Self.hideY, width: Self.width, height: Self.height)
            var source = FakeWindowSource(snapshots: [
                Self.snapshot(1, x: Self.hideW1X, y: Self.hideY),
                Self.snapshot(2, x: w2X, y: Self.hideY),
                WindowSnapshot(id: 3, ownerName: "App3", ownerPID: 403, frame: Self.hideW3, zIndex: 2),
            ])
            var now = Date(timeIntervalSince1970: 8_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: 17), demoResident: false)
            @discardableResult
            func step(_ dt: Double = 1.0 / 30) -> StepOutput {
                now = now.addingTimeInterval(dt)
                return engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: now))
            }

            let pid = engine.insertPlank(.placed(PlacedPlank(
                id: PlankID(0), endA: PlankEnd(window: 1, offset: Self.width),
                endB: PlankEnd(window: 2, offset: 0))))
            let ladOff = Double(c.ladderOffset)
            let lid = engine.insertLadder(.placed(PlacedLadder(
                id: LadderID(0), top: PlankEnd(window: 1, offset: ladOff),
                bottomSurface: .ground, bottom: Point(x: Self.hideW1X + ladOff, y: Self.groundY))))
            // 都都：在窗口 1 上走动（很长的行走时长），持有果子。
            engine.place(Resident(id: .a, state: .walking, attachment: .window(1, offset: Double(c.walkerOffset)),
                                  wander: WanderState(pauseRemaining: 0, walkRemaining: 10_000)))
            let fruit = ItemID(), pot = ItemID(), flower = ItemID()
            #expect(engine.give(.fruit(id: fruit, placement: .held(.a)), to: .a))
            // 嘟嘟：站在木板上，很长的停顿。
            engine.place(Resident(id: .b, attachment: .plank(pid, t: Double(c.plankT) / 100),
                                  wander: WanderState(pauseRemaining: 10_000)))
            engine.insertItem(.flowerPot(id: pot, placement: .attached(.window(1, offset: Double(c.potOffset)))))
            engine.insertItem(.flowerPot(id: flower, placement: .attached(.plank(pid, t: Double(c.flowerT) / 100))))

            for _ in 0 ..< c.warmup { step() }
            let before = engine.state
            #expect(before.residents[.a]?.state == .carrying, "都都隐藏前应在搬运中走动")
            #expect(before.residents[.a]?.attachment.windowID == 1)
            #expect(before.residents[.b]?.attachment == .plank(pid, t: Double(c.plankT) / 100))
            guard case .placed? = before.planks.planks[pid], case .placed? = before.ladders.ladders[lid] else {
                Issue.record("木板和梯子隐藏前应处于架设状态"); return
            }

            /// 隐藏期间的检查：所有对象原样不动、不绘制、不在 Nav_Graph 中。
            func checkHidden(_ out: StepOutput, label: String) {
                let s = engine.state
                for rid in [ResidentID.a, .b] {
                    #expect(s.residents[rid] == before.residents[rid], "居民 \(rid) 隐藏期间应保持不变：\(label)")
                    let v = out.view.residents.first { $0.id == rid }
                    #expect(v?.isHidden == true && v?.position == nil, "居民 \(rid) 隐藏期间不应绘制：\(label)")
                }
                for iid in [fruit, pot, flower] {
                    #expect(s.items[iid]?.placement == before.items[iid]?.placement, "物件隐藏期间应不变：\(label)")
                    #expect(!out.view.items.contains { $0.id == iid }, "物件隐藏期间不应绘制：\(label)")
                }
                #expect(s.planks.planks[pid] == before.planks.planks[pid], "木板隐藏期间不应失效：\(label)")
                #expect(s.ladders.ladders[lid] == before.ladders.ladders[lid], "梯子隐藏期间不应失效：\(label)")
                #expect(!out.view.planks.contains { $0.id == pid }, "木板隐藏期间不应绘制：\(label)")
                #expect(!out.view.ladders.contains { $0.id == lid }, "梯子隐藏期间不应绘制：\(label)")
                #expect(out.failedPlanks.isEmpty && out.failedLadders.isEmpty, "\(label)")
                // Nav_Graph 不含窗口 1 的窗沿、该木板和该梯子（Requirement 5.5）。
                #expect(!s.nav.nodes.keys.contains { $0.windowID == 1 || $0.plankID == pid },
                        "Nav_Graph 隐藏期间含窗口 1 或木板：\(label)")
                let ladderEdge = s.nav.edges.values.joined().contains { $0.kind == .ladder(lid) }
                #expect(!ladderEdge, "Nav_Graph 隐藏期间含爬梯边：\(label)")
            }

            source.hide(1)
            checkHidden(step(), label: "hide")
            for (i, op) in c.ops.enumerated() {
                switch op.kind {
                case 0: source.move(op.window, to: Point(x: Double(op.a), y: Double(op.b)))
                case 1: source.resize(op.window, to: (Double(max(op.a, 120)), Double(op.b)))
                case 2: source.bringToFront(op.window)
                case 3: source.hide(op.window)
                default: source.show(op.window)
                }
                for f in 0 ..< op.frames {
                    checkHidden(step(op.slow ? 0.25 : 1.0 / 30), label: "op \(i) \(op) frame \(f)")
                }
            }

            // 其他窗口回到原位后，窗口 1 在原位置重新显示。
            for (wid, frame) in [(WindowID(2), w2Original), (3, Self.hideW3)] {
                source.show(wid)
                source.move(wid, to: Point(x: frame.minX, y: frame.minY))
                source.resize(wid, to: (frame.width, frame.height))
            }
            checkHidden(step(), label: "restore others")

            // 重新显示的那一帧用 dt = 0，使居民不在本帧移动，便于逐项比较。
            source.show(1)
            let out = step(0)
            let s = engine.state
            for rid in [ResidentID.a, .b] {
                let r0 = before.residents[rid]!, r1 = s.residents[rid]!
                #expect(r1.attachment == r0.attachment, "居民 \(rid) Attachment 应与隐藏前相同")
                #expect(r1.state == r0.state, "居民 \(rid) 状态应与隐藏前相同")
                #expect(r1.heldItem == r0.heldItem && r1.hangElapsed == r0.hangElapsed, "居民 \(rid)")
                #expect(out.view.residents.first { $0.id == rid }?.isHidden == false, "居民 \(rid) 应重新绘制")
            }
            #expect(out.view.residents.first { $0.id == .a }?.position
                == Point(x: Self.hideW1X + (before.residents[.a]?.attachment.windowOffset ?? .nan), y: Self.hideY))
            for iid in [fruit, pot, flower] {
                #expect(s.items[iid]?.placement == before.items[iid]?.placement, "物件 Attachment 应与隐藏前相同")
                #expect(out.view.items.contains { $0.id == iid }, "物件应重新绘制")
            }
            #expect(s.planks.planks[pid] == before.planks.planks[pid], "木板应保持架设")
            #expect(s.ladders.ladders[lid] == before.ladders.ladders[lid], "梯子应保持架设")
            #expect(out.view.planks.contains { $0.id == pid } && out.view.ladders.contains { $0.id == lid })
            #expect(s.nav.nodes.keys.contains { $0.windowID == 1 } && s.nav.nodes[.plank(pid)] != nil,
                    "重新显示后窗口 1 的窗沿和木板应回到 Nav_Graph")
            #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())")

            // 之后居民从隐藏前的状态继续行动：都都继续搬运走动，嘟嘟仍在木板上停着。
            let offsetBefore = before.residents[.a]?.attachment.windowOffset
            for _ in 0 ..< 10 { step() }
            let a = engine.state.residents[.a]!
            #expect(a.state == .carrying && a.attachment.windowID == 1, "都都应继续走动：\(a.state) \(a.attachment)")
            #expect(a.attachment.windowOffset != offsetBefore, "都都重新显示后应继续移动")
            #expect(engine.state.residents[.b]?.attachment == before.residents[.b]?.attachment)
        }
    }
}

// MARK: - Property 9

extension AttachmentPropertyTests {
    /// 窗口 1（要关闭）和窗口 2 并排、等高，中间架一块木板；窗口 3 在窗口 1 下方、与其水平重叠，
    /// 提供一条较低的窗沿作为落点，水平范围之外的对象落到 Ground。梯子从窗口 1 上沿搭到窗口 3 上沿。
    /// 坐标全部取整数，落点可以精确比较。
    struct CloseCase: Sendable, CustomStringConvertible {
        var x1: Int               // 窗口 1 左边缘
        var y1: Int               // 窗口 1 与 2 的上沿
        var gap: Int              // 窗口 1 与 2 的间隙（木板跨度）
        var shift: Int            // 窗口 3 左边缘相对窗口 1 的水平偏移
        var drop: Int             // 窗口 3 上沿比窗口 1 上沿低多少（≤ Ladder_Length）
        var aOffset: Int          // 都都在窗口 1 上的偏移
        var aHolds: Bool          // 都都是否持有果子
        var bOnClosed: Bool       // 嘟嘟在窗口 1（true）还是窗口 2（false）上
        var bOffset: Int
        var potOffset: Int        // 窗口 1 上未被持有的花盆
        var loosePlankOffset: Int // 窗口 1 上一块落下的木板
        var hideFirst: Bool       // true：先隐藏窗口 1、隐藏期间移动它，再关闭（Requirement 5.8）
        var hiddenMove: Int       // 隐藏期间的水平位移
        var description: String {
            "w1(\(x1), \(y1)) gap \(gap) w3 shift \(shift) drop \(drop) a@\(aOffset)\(aHolds ? "+fruit" : "") "
                + "b@\(bOnClosed ? "w1" : "w2") \(bOffset) pot@\(potOffset) loosePlank@\(loosePlankOffset) "
                + "hideFirst \(hideFirst) move \(hiddenMove)"
        }
    }

    static var closeCases: Generator<CloseCase, some SendableSequenceType> {
        zip(
            zip(Gen<Int>.int(in: 220...690), Gen<Int>.int(in: 100...400), Gen<Int>.int(in: 40...150),
                Gen<Int>.int(in: -200...200), Gen<Int>.int(in: 140...200)),
            zip(Gen<Int>.int(in: 0...300), Gen<Bool>.bool, Gen<Bool>.bool, Gen<Int>.int(in: 0...300)),
            zip(Gen<Int>.int(in: 0...300), Gen<Int>.int(in: 0...300), Gen<Bool>.bool,
                Gen<Int>.int(in: -200...200))
        ).map { w, r, o in
            CloseCase(x1: w.0, y1: w.1, gap: w.2, shift: w.3, drop: w.4,
                      aOffset: r.0, aHolds: r.1, bOnClosed: r.2, bOffset: r.3,
                      potOffset: o.0, loosePlankOffset: o.1, hideFirst: o.2, hiddenMove: o.3)
        }
    }

    // Feature: v1, Property 9: 关闭即下落
    // **Validates: Requirements 5.1, 5.8, 14.9, 14.10, 20.3**
    // Story_Stage 部分在剧情接入 WorldEngine（任务 13）后补充；这里断言居民、物件、Plank、Ladder。
    @Test func closingDropsEverythingAttached() async {
        await propertyCheck(count: 100, input: Self.closeCases) { c in
            let x1 = Double(c.x1), y1 = Double(c.y1)
            let w2X = x1 + Self.width + Double(c.gap)
            let w3 = Rect(minX: x1 + Double(c.shift), minY: y1 + Double(c.drop), width: Self.width, height: Self.height)
            var source = FakeWindowSource(snapshots: [
                Self.snapshot(1, x: x1, y: y1),
                Self.snapshot(2, x: w2X, y: y1),
                WindowSnapshot(id: 3, ownerName: "App3", ownerPID: 403, frame: w3, zIndex: 2),
            ])
            var now = Date(timeIntervalSince1970: 9_000_000)
            let engine = WorldEngine(
                clockStart: now, screen: Self.screen, rng: RandomSource(seed: 19), demoResident: false)
            @discardableResult
            func step() -> StepOutput {
                now = now.addingTimeInterval(1.0 / 30)
                return engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: now))
            }

            // 木板：窗口 1 右端 → 窗口 2 左端。梯子上端位于窗口 1 与窗口 3 水平重叠区的中点，下端在窗口 3 上沿。
            let pid = engine.insertPlank(.placed(PlacedPlank(
                id: PlankID(0), endA: PlankEnd(window: 1, offset: Self.width),
                endB: PlankEnd(window: 2, offset: 0))))
            let overlapLo = max(x1, w3.minX), overlapHi = min(x1 + Self.width, w3.maxX)
            let ladOff = ((overlapLo + overlapHi) / 2).rounded() - x1
            let lid = engine.insertLadder(.placed(PlacedLadder(
                id: LadderID(0), top: PlankEnd(window: 1, offset: ladOff),
                bottomSurface: .ledge(3, index: 0), bottom: Point(x: x1 + ladOff, y: w3.minY))))
            let loosePid = engine.insertPlank(.loose(.window(1, offset: Double(c.loosePlankOffset))))

            engine.place(Resident(id: .a, attachment: .window(1, offset: Double(c.aOffset)),
                                  wander: WanderState(pauseRemaining: 10_000)))
            let bWindow: WindowID = c.bOnClosed ? 1 : 2
            engine.place(Resident(id: .b, attachment: .window(bWindow, offset: Double(c.bOffset)),
                                  wander: WanderState(pauseRemaining: 10_000)))
            let fruit = ItemID(), pot = ItemID()
            if c.aHolds { #expect(engine.give(.fruit(id: fruit, placement: .held(.a)), to: .a)) }
            engine.insertItem(.flowerPot(id: pot, placement: .attached(.window(1, offset: Double(c.potOffset)))))

            step()
            guard case .placed? = engine.state.planks.planks[pid],
                  case .placed? = engine.state.ladders.ladders[lid] else {
                Issue.record("木板和梯子关闭前应处于架设状态"); return
            }
            let bBefore = engine.state.residents[.b]!

            // 关闭前最后一次可见的窗口 1 位置就是初始位置；隐藏期间的移动不可见。
            if c.hideFirst {
                source.hide(1)
                step()
                source.move(1, to: Point(x: x1 + Double(c.hiddenMove), y: y1))
                step()
            }
            source.close(1)
            let out = step()
            let s = engine.state

            /// 预期起点（最后可见快照 + 原 offset）和落点（窗口 3 窗沿或 Ground）。
            func startX(_ offset: Int) -> Double { x1 + Double(offset) }
            func expectedLanding(_ x: Double) -> CoreAttachment {
                w3.minX <= x && x <= w3.maxX ? .window(3, offset: x - w3.minX) : .ground(x: x)
            }
            func checkFallStart(_ p: Point?, x: Double, label: String) {
                guard let p else { Issue.record("\(label) 应处于下落中"); return }
                #expect(p.x == x, "\(label)：下落起点 x 应为 \(x)，实际 \(p.x)")
                #expect(p.y >= y1 && p.y < y1 + 5, "\(label)：下落起点 y 应在 \(y1) 附近，实际 \(p.y)")
            }

            // 居民：附着在窗口 1 上的进入 falling，起点为最后可见位置；持有物不脱手（Requirement 14.10）。
            var closedResidents: [(ResidentID, Double)] = [(.a, startX(c.aOffset))]
            if c.bOnClosed { closedResidents.append((.b, startX(c.bOffset))) }
            for (rid, x) in closedResidents {
                let r = s.residents[rid]!
                #expect(r.state == .falling, "居民 \(rid) 应下落，实际 \(r.state)")
                checkFallStart(r.fall?.position, x: x, label: "居民 \(rid)")
            }
            if !c.bOnClosed {
                #expect(s.residents[.b]?.attachment == bBefore.attachment && s.residents[.b]?.state == bBefore.state,
                        "窗口 2 上的嘟嘟不应受影响")
            }
            if c.aHolds {
                #expect(s.items[fruit]?.placement == .held(.a) && s.residents[.a]?.heldItem == fruit,
                        "果子应仍由都都持有")
            }

            // 未被持有的物件开始下落（Requirement 14.9）。
            if case let .falling(fs)? = s.items[pot]?.placement {
                checkFallStart(fs.position, x: startX(c.potOffset), label: "花盆")
            } else {
                Issue.record("花盆应下落，实际 \(String(describing: s.items[pot]?.placement))")
            }

            // 端点在窗口 1 上的已架设木板和梯子失效并下落；窗口 1 上落下的木板也下落。
            #expect(out.failedPlanks == [pid], "木板应在关闭这次 step 中失效：\(out.failedPlanks)")
            #expect(out.failedLadders == [lid], "梯子应在关闭这次 step 中失效：\(out.failedLadders)")
            for (id, name) in [(pid, "架设的木板"), (loosePid, "落下的木板")] {
                if case .falling? = s.planks.planks[id] {} else {
                    Issue.record("\(name)应下落，实际 \(String(describing: s.planks.planks[id]))")
                }
            }
            if case .falling? = s.ladders.ladders[lid] {} else {
                Issue.record("梯子应下落，实际 \(String(describing: s.ladders.ladders[lid]))")
            }
            #expect(!s.nav.nodes.keys.contains { $0.windowID == 1 || $0.plankID == pid })
            #expect(!s.nav.edges.values.joined().contains { $0.kind == .ladder(lid) })

            // 推进到全部落地，记录每个对象第一次落地时的 Attachment。
            var landed: [ResidentID: CoreAttachment] = [:]
            var potLanding: CoreAttachment?
            for _ in 0 ..< 90 {
                step()
                for (rid, _) in closedResidents where landed[rid] == nil {
                    let r = engine.state.residents[rid]!
                    if r.state != .falling { landed[rid] = r.attachment }
                }
                if potLanding == nil, case let .attached(a)? = engine.state.items[pot]?.placement {
                    potLanding = a
                }
                if c.aHolds {
                    #expect(engine.state.items[fruit]?.placement == .held(.a), "果子在下落和落地过程中应不脱手")
                }
                #expect(engine.invariantViolations().isEmpty, "\(engine.invariantViolations())")
            }
            for (rid, x) in closedResidents {
                #expect(landed[rid] == expectedLanding(x), "居民 \(rid) 落点：\(String(describing: landed[rid]))")
            }
            #expect(potLanding == expectedLanding(startX(c.potOffset)),
                    "花盆落点：\(String(describing: potLanding))")
            for (id, name) in [(pid, "架设的木板"), (loosePid, "落下的木板")] {
                if case .loose? = engine.state.planks.planks[id] {} else {
                    Issue.record("\(name)应已落地，实际 \(String(describing: engine.state.planks.planks[id]))")
                }
            }
            if case .loose? = engine.state.ladders.ladders[lid] {} else {
                Issue.record("梯子应已落地，实际 \(String(describing: engine.state.ladders.ladders[lid]))")
            }
        }
    }
}

private extension CoreAttachment {
    /// `window` 取值的偏移量；其他取值为 nil。
    var windowOffset: Double? {
        if case let .window(_, offset) = self { return offset }
        return nil
    }
}
