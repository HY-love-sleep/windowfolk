import Foundation
import Testing
@testable import WindowfolkCore

/// v2 任务 12.9：ThoughtEngine 接入 WorldEngine（Requirement 12.5、14.1、14.3、14.6、14.8）与 Thought 气泡布局
/// （Requirement 14.4、16.6、16.7）。
struct ThoughtEngineIntegrationUnitTests {
    typealias H = BridgeHangTests

    /// 只有一个窗口、剧情和自主活动都关闭的世界。每次 step 可指定 Thought 相关输入。
    final class Harness {
        let engine: WorldEngine
        var source: FakeWindowSource
        var now = Date(timeIntervalSince1970: 2_000_000)

        init() {
            engine = WorldEngine(clockStart: now, screen: H.screen, rng: RandomSource(seed: 5), demoResident: false)
            source = FakeWindowSource(windows: [FakeWindow(snapshot: H.win(1, 100, 300, 300, 300))])
            engine.place(H.idle(.a, window: 1, offset: 100))
        }

        @discardableResult
        func step(enabled: Bool = true, hidden: Bool = false, results: [(UInt64, ThoughtResult)] = [],
                  dt: Double = H.dt) -> StepOutput {
            now = now.addingTimeInterval(dt)
            return engine.step(FrameInput(
                poll: source.poll(), screen: H.screen, now: now, timeZone: TimeZone(identifier: "UTC")!,
                worldHidden: hidden, thoughtsEnabled: enabled, thoughtResults: results))
        }

        /// 关掉窗口让都都掉到 Ground，返回落地那一帧的输出。
        func dropToGround(enabled: Bool = true) -> StepOutput? {
            step(enabled: enabled)
            source.close(1)
            for _ in 0 ..< 300 {
                let out = step(enabled: enabled)
                if out.events.contains(where: { $0.type == .landed }) { return out }
            }
            return nil
        }

        func thought(_ out: StepOutput) -> String? { out.view.residents.first { $0.id == .a }?.thought }
    }

    @Test func landingRequestsThoughtAndResultIsShownWithRecord() throws {
        let h = Harness()
        let landed = try #require(h.dropToGround())
        #expect(landed.thoughtRequests.count == 1)
        let req = try #require(landed.thoughtRequests.first)
        #expect(req.resident == .a)
        #expect(h.engine.state.thoughts.inFlight?.id == req.id)

        let out = h.step(results: [(req.id, .text("  落地啦\r\n好疼  "))])
        #expect(h.thought(out) == "落地啦 好疼")
        let shown = out.events.filter { $0.type == .thoughtShown }
        #expect(shown.count == 1)
        #expect(shown.first?.actor == "resident_a")
        #expect(shown.first?.target == nil)
        #expect(shown.first?.detail == ["text": "落地啦 好疼"])
        #expect(out.events.last?.type == .thoughtShown)

        // 显示到 Thought_Display_Duration 后移除。
        let gone = h.step(dt: h.engine.constants.thoughtDisplayDuration)
        #expect(h.thought(gone) == nil)
        #expect(!gone.events.contains { $0.type == .thoughtShown })
    }

    @Test func disabledThoughtsSendNoRequests() throws {
        let h = Harness()
        let landed = try #require(h.dropToGround(enabled: false))
        #expect(landed.thoughtRequests.isEmpty)
        #expect(h.engine.state.thoughts.inFlight == nil)
    }

    @Test func mismatchedResultIdIsIgnored() throws {
        let h = Harness()
        let req = try #require(h.dropToGround()?.thoughtRequests.first)
        let out = h.step(results: [(req.id &+ 7, .text("迟到的"))])
        #expect(h.thought(out) == nil)
        #expect(!out.events.contains { $0.type == .thoughtShown })
        #expect(h.engine.state.thoughts.inFlight?.id == req.id)
    }

    @Test func resultArrivingWhileWorldHiddenIsDroppedWithoutRecord() throws {
        let h = Harness()
        let req = try #require(h.dropToGround()?.thoughtRequests.first)
        let out = h.step(hidden: true, results: [(req.id, .text("看不见"))])
        #expect(h.engine.state.residents[.a]?.thought == nil)
        #expect(!out.events.contains { $0.type == .thoughtShown })
        #expect(h.engine.state.thoughts.lastShownAt == nil)
        #expect(h.engine.state.thoughts.inFlight == nil)
    }

    @Test func worldHiddenOrDisablingRemovesShownThoughtSameFrame() throws {
        for hide in [true, false] {
            let h = Harness()
            let req = try #require(h.dropToGround()?.thoughtRequests.first)
            #expect(h.thought(h.step(results: [(req.id, .text("嗨"))])) == "嗨")
            h.step(enabled: hide, hidden: hide)
            #expect(h.engine.state.residents[.a]?.thought == nil)
        }
    }

    @Test func seatLiftFollowsSittingState() {
        let h = Harness()
        var r = h.engine.state.residents[.a]!
        r.state = .sitting
        h.engine.place(r)
        let view = h.engine.makeView().residents.first { $0.id == .a }
        #expect(view?.seatLift == SpriteMetrics.chairSeatHeight)
        // 没有 Chair 的 `sitting` 在帧末被校正为 `idle`（Requirement 4.13），上移随之归零。
        let after = h.step().view.residents.first { $0.id == .a }
        #expect(after?.state == .idle)
        #expect(after?.seatLift == 0)
    }

    // MARK: - 布局

    @Test func thoughtWidthHasPaddingAndIconMinimum() {
        let icon = SpriteMetrics.bubble.width
        #expect(ThoughtLayout.width(textWidth: 0) == icon)
        #expect(ThoughtLayout.width(textWidth: -5) == icon)
        #expect(ThoughtLayout.width(textWidth: 100) == 100 + 2 * ThoughtLayout.horizontalPadding)
        #expect(ThoughtLayout.width(textWidth: .nan) == icon)
    }

    @Test func thoughtSitsAboveWishBubbleWithGap() {
        let head = Point(x: 200, y: 400)
        let wish = ThoughtLayout.iconBubbleRect(headTop: head)
        #expect(wish.maxY == head.y - ThoughtLayout.gap)
        #expect(wish.midX == head.x)
        let above = ThoughtLayout.thoughtRect(textWidth: 120, headTop: head, hasWishBubble: true)
        #expect(above.maxY == wish.minY - ThoughtLayout.gap)
        #expect(above.midX == head.x)
        #expect(above.height == SpriteMetrics.bubble.height)
        let alone = ThoughtLayout.thoughtRect(textWidth: 120, headTop: head, hasWishBubble: false)
        #expect(alone.maxY == head.y - ThoughtLayout.gap)
    }

    @Test func headTopAccountsForLifts() {
        let v = ResidentView(id: .a, state: .sitting, position: Point(x: 10, y: 500), facing: .right,
                             isHidden: false, jumpLift: 3, seatLift: 10)
        #expect(ThoughtLayout.headTop(of: v) == Point(x: 10, y: 500 - SpriteMetrics.resident.height - 13))
        let hidden = ResidentView(id: .a, state: .idle, position: nil, facing: .right, isHidden: true)
        #expect(ThoughtLayout.headTop(of: hidden) == nil)
    }
}
