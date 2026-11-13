import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 任务 7.12：Visit_Flag 位置与箭头方向（design.md Property 25）。

/// 居民 x 的取法：nil（如在 Hidden_Window 上或不在任何 Surface 上）、恰好等于旗的 x、或随机。
fileprivate enum ResidentXKind: Sendable { case none, atFlag, random(Double) }

/// 纯函数场景：任意窗口布局中选一个 Visit_Target，可能隐藏；Wisher 的 x。
fileprivate struct FlagScene: Sendable {
    var layout: [WindowSnapshot]
    /// 对布局长度 + 1 取模；等于长度时 Visit_Target 不在布局中（如已关闭）。
    var targetPick: Int
    var hidden: Bool
    var residentX: ResidentXKind
}

fileprivate extension Gen where Value == FlagScene {
    static var flagScene: Generator<FlagScene, some SendableSequenceType> {
        let rx = zip(Gen<Int>.int(in: 0...3), Gen<Double>.double(in: -100...1800)).map { k, x -> ResidentXKind in
            switch k {
            case 0: return .none
            case 1: return .atFlag
            default: return .random(x)
            }
        }
        return zip(Gen<[WindowSnapshot]>.windowLayout, Gen<Int>.int(in: 0...999), Gen<Bool>.bool, rx)
            .map { FlagScene(layout: $0, targetPick: $1, hidden: $2, residentX: $3) }
    }
}

/// 引擎场景中对窗口的一次操作。
fileprivate enum FlagOp: Sendable {
    case moveTarget(x: Double, y: Double)
    case resizeTarget(w: Double, h: Double)
    case hideTarget
    case showTarget
    /// 把第 `pick % 窗口数` 个窗口提到最前（改变遮挡）。
    case bringToFront(pick: Int)
    case nothing
}

/// 引擎场景：若干窗口（坐标对齐 8pt），触发 Visit_Wish 后对 Visit_Target 做一串操作。
fileprivate struct FlagEngineScene: Sendable {
    var windows: [WindowSnapshot]
    var ops: [FlagOp]
}

fileprivate extension Gen where Value == FlagEngineScene {
    static var flagEngineScene: Generator<FlagEngineScene, some SendableSequenceType> {
        let frame = zip(
            Gen<Int>.int(in: 0...150), Gen<Int>.int(in: 12...80),   // minX 0 到 1200，minY 96 到 640
            Gen<Int>.int(in: 15...50), Gen<Int>.int(in: 15...30)    // 宽 120 到 400，高 120 到 240
        ).map { x, y, w, h in Rect(minX: Double(x) * 8, minY: Double(y) * 8, width: Double(w) * 8, height: Double(h) * 8) }
        let windows = frame.array(of: 3...6).map { frames in
            frames.enumerated().map { i, f in
                WindowSnapshot(id: WindowID(i + 1), ownerName: "App\(i + 1)", ownerPID: Int32(100 + i),
                               frame: f, zIndex: i)
            }
        }
        let op = zip(
            Gen<Int>.int(in: 0...5), Gen<Int>.int(in: 0...150), Gen<Int>.int(in: 12...80), Gen<Int>.int(in: 0...9)
        ).map { k, a, b, pick -> FlagOp in
            switch k {
            case 0: return .moveTarget(x: Double(a) * 8, y: Double(b) * 8)
            case 1: return .resizeTarget(w: Double(15 + a % 36) * 8, h: Double(15 + b % 16) * 8)
            case 2: return .hideTarget
            case 3: return .showTarget
            case 4: return .bringToFront(pick: pick)
            default: return .nothing
            }
        }
        return zip(windows, op.array(of: 1...8)).map { FlagEngineScene(windows: $0, ops: $1) }
    }
}

struct VisitWishTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 参考实现：窗口 `target` 上沿未被前方窗口遮挡的各段（按 minX 升序），用断点逐段判定覆盖。
    static func visibleTopSegments(of target: WindowSnapshot, in windows: [WindowSnapshot]) -> [(lo: Double, hi: Double)] {
        let y = target.frame.minY
        let lo = target.frame.minX, hi = target.frame.maxX
        let cuts = windows.filter { $0.zIndex < target.zIndex && $0.frame.minY <= y && y <= $0.frame.maxY }
            .map { (lo: $0.frame.minX, hi: $0.frame.maxX) }
        let points = Set([lo, hi] + cuts.flatMap { [$0.lo, $0.hi] }.filter { $0 > lo && $0 < hi }).sorted()
        var segments: [(lo: Double, hi: Double)] = []
        for (a, b) in zip(points, points.dropFirst()) where b > a {
            guard !cuts.contains(where: { $0.lo <= a && b <= $0.hi }) else { continue }
            if let last = segments.last, last.hi == a {
                segments[segments.count - 1].hi = b
            } else {
                segments.append((a, b))
            }
        }
        return segments
    }

    /// 参考实现：最长一段（长度相等取左边那段）的中点，y 为窗口上沿。
    static func expectedFlag(_ segments: [(lo: Double, hi: Double)], y: Double) -> Point? {
        var best: (lo: Double, hi: Double)?
        for s in segments where best == nil || s.hi - s.lo > best!.hi - best!.lo { best = s }
        return best.map { Point(x: ($0.lo + $0.hi) / 2, y: y) }
    }

    /// 参考实现：在给定 Surface 中取窗口 `window` 最长一段 Window_Ledge（长度相等取段序号小者）的中点。
    static func expectedFlag(window: WindowID, surfaces: [Surface]) -> Point? {
        let ledges = surfaces.filter { $0.id.windowID == window }.sorted { $0.id < $1.id }
        var best: Surface?
        for s in ledges where best == nil || s.end.x - s.start.x > best!.end.x - best!.start.x { best = s }
        return best.map { Point(x: ($0.start.x + $0.end.x) / 2, y: $0.start.y) }
    }

    // Feature: V2, Property 25: Visit_Flag 位置与箭头方向
    /// **Validates: Requirements 9.2, 9.3, 9.7**
    ///
    /// 纯函数部分：任意遮挡下，可见的 Visit_Target 的旗在最长一段窗沿中点（窗口上沿上），隐藏或不在场时没有旗；
    /// 「小旗」箭头在旗 x 小于 Wisher x 时朝左，其余朝右；只有 Wisher 显示。
    @Test func visitFlagPointAndArrow() async {
        await propertyCheck(count: 200, input: Gen.flagScene) { s in
            let index = s.targetPick % (s.layout.count + 1)
            let targetWindow = index < s.layout.count ? s.layout[index] : nil
            let target = targetWindow?.id ?? WindowID(s.layout.count + 1)
            let visible = s.hidden ? s.layout.filter { $0.id != target } : s.layout
            let surfaces = SurfaceBuilder.build(windows: visible, screen: Self.screen)

            let point = WishDirector.visitFlagPoint(window: target, surfaces: surfaces)
            var expected: Point?
            if let w = targetWindow, !s.hidden {
                expected = Self.expectedFlag(Self.visibleTopSegments(of: w, in: s.layout), y: w.frame.minY)
            }
            #expect(point == expected)
            #expect(WishDirector.visitFlagX(window: target, surfaces: surfaces) == expected?.x)

            let rx: Double?
            switch s.residentX {
            case .none: rx = nil
            case .atFlag: rx = point?.x
            case let .random(x): rx = x
            }
            let wish = Wish(id: WishID(1), type: .visit, wisher: .a, createdAt: Self.t0,
                            visitTarget: VisitTarget(window: target, ownerName: "App\(target)"))
            let arrow: Facing = {
                if let fx = point?.x, let rx, fx < rx { return .left }
                return .right
            }()
            #expect(WishDirector.wishIcon(for: wish, resident: .a, residentX: rx, flagX: point?.x)
                == .flag(arrow: arrow))
            #expect(WishDirector.wishIcon(for: wish, resident: .b, residentX: rx, flagX: point?.x) == nil)
        }
    }

    // Feature: V2, Property 25: Visit_Flag 位置与箭头方向
    /// **Validates: Requirements 9.2, 9.3, 9.7**
    ///
    /// 引擎部分：触发 Visit_Wish 后任意移动、缩放、隐藏、显示 Visit_Target 或改变遮挡，每一帧的
    /// `WorldView.visitFlags` 都是 Visit_Target 当前最长一段窗沿的中点（跟到新位置），隐藏时为空；
    /// Wisher 的「小旗」箭头按同一帧旗与 Wisher 的 x 决定方向。
    @Test func worldViewVisitFlagFollowsTarget() async {
        await propertyCheck(count: 100, input: Gen.flagEngineScene) { s in
            var source = FakeWindowSource(snapshots: s.windows)
            var now = Self.t0
            let engine = WorldEngine(clockStart: now, screen: Self.screen, rng: RandomSource(seed: 7))
            func step(_ commands: [Command] = []) -> StepOutput {
                now = now.addingTimeInterval(1.0 / 30)
                return engine.step(FrameInput(poll: source.poll(), screen: Self.screen, commands: commands,
                                              now: now, timeZone: Self.utc))
            }
            _ = step()
            var out = step([.triggerWish(.visit, .a)])
            // 没有可作为 Visit_Target 的窗口时不生成 Visit_Wish，本例无可检查内容。
            guard let target = engine.state.wishes.active.first(where: { $0.type == .visit })?.visitTarget?.window
            else { return }

            for op in [FlagOp.nothing] + s.ops {
                switch op {
                case let .moveTarget(x, y): source.move(target, to: Point(x: x, y: y))
                case let .resizeTarget(w, h): source.resize(target, to: (w, h))
                case .hideTarget: source.hide(target)
                case .showTarget: source.show(target)
                case let .bringToFront(pick): source.bringToFront(WindowID(pick % s.windows.count + 1))
                case .nothing: break
                }
                out = step()
                guard let wish = engine.state.wishes.active.first(where: { $0.type == .visit }) else { break }
                #expect(wish.visitTarget?.window == target)
                let fake = source.window(target)!
                if fake.isHidden {
                    #expect(out.view.visitFlags.isEmpty)
                } else {
                    let expected = Self.expectedFlag(window: target, surfaces: engine.state.surfaces)
                    #expect(out.view.visitFlags == (expected.map { [$0] } ?? []))
                    if let p = expected { #expect(p.y == fake.snapshot.frame.minY) }
                }

                // 箭头：Wisher 不在 Hidden_Window 上且站在某个 Surface 上时取其 x，否则朝右。
                let r = engine.state.residents[wish.wisher]!
                let rx = engine.isOnHiddenWindow(r)
                    ? nil : ResidentController.currentSurface(of: r, world: engine.movementContext())?.position.x
                let fx = out.view.visitFlags.first?.x
                let arrow: Facing = (fx != nil && rx != nil && fx! < rx!) ? .left : .right
                if case let .wishIcon(icon)? = out.view.residents.first(where: { $0.id == wish.wisher })?.bubble {
                    #expect(icon == .flag(arrow: arrow))
                }
            }
        }
    }
}
