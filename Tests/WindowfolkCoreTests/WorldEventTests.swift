import Foundation
import Testing
@testable import WindowfolkCore

/// 任务 14.3：WorldEngine 产生的事件记录（Requirement 21.1、21.5 至 21.8）。
struct WorldEventTests {
    typealias H = BridgeHangTests

    /// 运行若干帧，收集全部事件。
    static func run(_ h: H.Harness, frames: Int, _ commands: [Command] = []) -> [EventRecord] {
        var events = h.step(commands).events
        for _ in 1 ..< max(frames, 1) { events += h.step().events }
        return events
    }

    @Test func crossingBridgeRecordsCrossedBridgeWithAppNames() {
        let (h, pid) = H.bridgeScene()
        h.engine.place(H.idle(.a, window: 1, offset: 100))
        h.engine.place(H.idle(.b, window: 2, offset: 150))
        h.step()
        let events = Self.run(h, frames: 600, [.debugSeek])
        let crossed = events.filter { $0.type == .crossedBridge }
        #expect(crossed.count == 1)
        #expect(crossed.first?.actor == "resident_a")
        #expect(crossed.first?.target == "plank:\(pid.rawValue)")
        #expect(crossed.first?.detail == ["from": "app:App1", "to": "app:App2"])
        #expect(!events.contains { $0.type == .fell || $0.type == .waitingStarted })
    }

    @Test func collapsedPlankRecordsDropFallAndLanding() {
        let (h, pid) = H.bridgeScene()
        h.engine.place(H.idle(.a, plank: pid, t: 0.5))
        h.step()
        h.source.move(2, to: Point(x: 900, y: 300))
        let first = h.step()
        #expect(first.events.map(\.type) == [.plankDropped])
        #expect(first.events.first?.actor == nil)
        #expect(first.events.first?.target == "plank:\(pid.rawValue)")
        #expect(first.events.first?.detail["cause"] == "collapsed")

        let later = Self.run(h, frames: 150)
        let fell = later.filter { $0.type == .fell }
        let landed = later.filter { $0.type == .landed }
        #expect(fell.count == 1 && fell.first?.actor == "resident_a")
        #expect(fell.first?.detail["from_state"] == "hanging")
        #expect(landed.count == 1 && landed.first?.target == "ground")
        // 落地在下落之后。
        if let fi = later.firstIndex(where: { $0.type == .fell }),
           let li = later.firstIndex(where: { $0.type == .landed }) {
            #expect(fi < li)
        }
    }

    @Test func unreachableSeekRecordsWaitingStartedOnce() {
        let h = H.Harness([H.win(1, 100, 300, 300, 300), H.win(2, 900, 300, 300, 300)])
        h.engine.place(H.idle(.a, window: 1, offset: 100))
        h.engine.place(H.idle(.b, window: 2, offset: 100))
        let events = Self.run(h, frames: 30, [.debugSeek])
        let waiting = events.filter { $0.type == .waitingStarted }
        #expect(waiting.count == 1)
        #expect(waiting.first?.actor == "resident_a")
        #expect(waiting.first?.target == "resident_b")
        #expect(waiting.first?.detail == ["on": "app:App1"])
    }

    @Test func closingWindowRecordsFallFromItsApp() {
        let h = H.Harness([H.win(1, 100, 300, 300, 300)])
        h.engine.place(H.idle(.a, window: 1, offset: 100))
        h.step()
        h.source.close(1)
        let out = h.step()
        let fell = out.events.filter { $0.type == .fell }
        #expect(fell.count == 1)
        #expect(fell.first?.target == "app:App1")
        #expect(fell.first?.detail["from_state"] == "idle")
    }

    @Test func storyStartRecordsRoundStartedWithNullActorAndTruncatedTime() throws {
        var now = Date(timeIntervalSince1970: 3_000_000.75)
        let engine = WorldEngine(clockStart: now, screen: H.screen, rng: RandomSource(seed: 3), story: true)
        let source = FakeWindowSource(windows: [
            FakeWindow(snapshot: H.win(1, 100, 300, 300, 300)),
            FakeWindow(snapshot: H.win(2, 900, 300, 300, 300)),
        ])
        var s = source
        now = now.addingTimeInterval(0.1)
        // V2：送花由「触发心愿」启动（design.md「v1 属性的调整」）；wish_started 写在 round_started 之前。
        let out = engine.step(FrameInput(poll: s.poll(), screen: H.screen,
                                         commands: [.triggerWish(.flower, nil)], now: now))
        let types = out.events.map(\.type)
        let started = try #require(types.firstIndex(of: .wishStarted))
        #expect(types.firstIndex(of: .roundStarted).map { $0 > started } == true)
        let wish = out.events[started]
        #expect(wish.actor == "resident_a" && wish.target == "resident_b")
        #expect(wish.detail == ["wish_type": "flower", "wish_state": "active"])
        let round = out.events.filter { $0.type == .roundStarted }
        #expect(round.count == 1)
        #expect(round.first?.actor == nil)
        #expect(round.first?.target == nil)
        #expect(round.first?.detail["round"] == "1")
        #expect(round.first?.time == Date(timeIntervalSince1970: 3_000_000))
        // 所有记录都能编码为恰好五个字段的一行 JSON。
        for e in out.events {
            #expect(try EventCodec.decodeLine(EventCodec.encodeLine(e)) == e)
        }
    }
}
