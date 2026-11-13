import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 Property 14（任务 7.14）：成为 Busy_Resident 的同一次 step 结束时 Activity 已结束。
// 通过 WorldEngine 驱动：剧情启用的完整 V2 世界（三扇窗口，都都和嘟嘟住在窗口 1 和 3，窗口 2 可作 Visit_Target），
// 让居民各自处于自由活动、坐在 Chair 上或在 Lamp 旁睡着，随机帧之后触发各类 Wish。时区固定为 UTC。

// MARK: - 生成器

/// 一次模拟的参数。
fileprivate struct BusyScenario: Sendable, CustomStringConvertible {
    /// 每位居民的准备方式：0 交给 Activity_Planner，1 坐到身旁的 Chair 上，2 在身旁的 Lamp 旁睡觉。
    var modeA: Int, modeB: Int
    /// 准备之前先自由推进的帧数；准备完成后再推进的帧数。
    var preFrames: Int, extraFrames: Int
    var wishType: WishType
    var wisherIsB: Bool
    /// Chair / Lamp 放在居民左侧（false）还是右侧（true）。
    var decorRight: Bool
    var seed: UInt64

    var description: String {
        "modeA=\(modeA) modeB=\(modeB) pre=\(preFrames) extra=\(extraFrames) wish=\(wishType) "
            + "wisher=\(wisherIsB ? "b" : "a") right=\(decorRight) seed=\(seed)"
    }
}

fileprivate extension Gen where Value == BusyScenario {
    static var busyScenario: Generator<BusyScenario, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...2), Gen<Int>.int(in: 0...2),
            Gen<Int>.int(in: 0...20), Gen<Int>.int(in: 0...45),
            Gen<Int>.int(in: 0...(WishType.allCases.count - 1)), Gen<Bool>.bool,
            Gen<Bool>.bool, Gen<Int>.int(in: 0...1_000_000)
        ).map {
            BusyScenario(modeA: $0, modeB: $1, preFrames: $2, extraFrames: $3,
                         wishType: WishType.allCases[$4], wisherIsB: $5, decorRight: $6, seed: UInt64($7))
        }
    }
}

/// 统计属性检查中「原为 sitting / sleeping 的居民成为 Busy」各发生了多少次，确认生成器覆盖到这两种情形。
fileprivate final class BusyCoverage: @unchecked Sendable {
    private let lock = NSLock()
    private var sitting = 0, sleeping = 0
    func add(sitting s: Int, sleeping z: Int) {
        lock.lock(); sitting += s; sleeping += z; lock.unlock()
    }
    var counts: (sitting: Int, sleeping: Int) {
        lock.lock(); defer { lock.unlock() }
        return (sitting, sleeping)
    }
}

struct WishBusyTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    /// UTC 08:00，不是 Night。
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let windows = [
        StoryEngineTests.win(1, x: 100, y: 400),
        StoryEngineTests.win(2, x: 400, y: 400),
        StoryEngineTests.win(3, x: 900, y: 400),
    ]

    fileprivate final class Harness {
        let engine: WorldEngine
        var source = FakeWindowSource(snapshots: WishBusyTests.windows)
        var now = WishBusyTests.t0
        var sittingBusy = 0, sleepingBusy = 0

        init(seed: UInt64) {
            engine = WorldEngine(clockStart: now, screen: WishBusyTests.screen, rng: RandomSource(seed: seed))
        }

        /// 推进一帧，并对本帧新成为 Busy_Resident 的居民断言 Property 14。
        func step(_ commands: [Command] = [], _ s: BusyScenario) {
            let before = engine.state.residents
            let busyBefore = engine.state.wishes.busy
            now = now.addingTimeInterval(1.0 / 30)
            let out = engine.step(FrameInput(poll: source.poll(), screen: WishBusyTests.screen,
                                             commands: commands, now: now, timeZone: WishBusyTests.utc))
            let newlyBusy = engine.state.wishes.busy.subtracting(busyBefore)
            for id in newlyBusy.sorted() {
                guard let prev = before[id], let r = engine.state.residents[id] else { continue }
                #expect(engine.state.activities[id] == nil, "\(id) keeps Activity; \(s)")
                let woke = out.events.filter { $0.type == .woke && $0.actor == id.rawValue }
                // 结束 Activity 时转为 idle；同一帧随后的移动阶段按 Wish 的 Goal 行动，step 结束时可能已是
                // walking / waiting 等，因此断言不再 sitting / sleeping（与任务 7.4 的例子一致）。
                #expect(r.state != .sitting && r.state != .sleeping, "\(id) still \(r.state); \(s)")
                #expect(r.seat == nil, "\(id) still holds Chair; \(s)")
                if let seat = prev.seat {
                    #expect(!engine.state.residents.values.contains { $0.seat == seat }, "Chair still taken; \(s)")
                }
                switch prev.state {
                case .sitting:
                    sittingBusy += 1
                    #expect(woke.isEmpty, "\(s)")
                case .sleeping:
                    sleepingBusy += 1
                    #expect(woke.count == 1, "\(id) woke count \(woke.count); \(s)")
                    #expect(woke.first?.detail["reason"] == "became_busy", "\(s)")
                default:
                    #expect(woke.isEmpty, "\(s)")
                }
            }
        }

        /// 在居民当前位置旁放一件 Decor，返回其 ID；居民不在窗沿或 Ground 上时返回 nil。
        func insertDecor(_ id: UInt64, _ type: DecorType, beside r: ResidentID, right: Bool) -> DecorID? {
            guard let res = engine.state.residents[r] else { return nil }
            let shift = right ? 20.0 : -20.0
            let placement: CoreAttachment
            switch res.attachment {
            case let .window(w, offset):
                guard let width = WishBusyTests.windows.first(where: { $0.id == w })?.frame.width else { return nil }
                placement = .window(w, offset: min(max(offset + shift, 10), width - 10))
            case let .ground(x):
                placement = .ground(x: x + shift)
            default:
                return nil
            }
            let did = DecorID(id)
            engine.insertDecor(Decor(id: did, type: type, placement: .attached(placement)))
            return did
        }
    }

    // Feature: V2, Property 14: 成为 Busy 时同帧结束 Activity
    /// **Validates: Requirements 4.12**
    @Test func becomingBusyEndsActivityInSameStep() async {
        let coverage = BusyCoverage()
        await propertyCheck(count: 100, input: Gen.busyScenario) { s in
            let h = Harness(seed: s.seed)
            h.step([], s)                                   // 首帧：分配家并放置两位居民
            for _ in 0 ..< s.preFrames { h.step([], s) }

            // 准备：坐下或睡觉的居民身旁放 Chair / Lamp，并直接给出对应 Activity。
            var nextDecor: UInt64 = 1
            var targets: [ResidentID: ResidentState] = [:]
            var commands: [Command] = []
            for (id, mode) in [(ResidentID.a, s.modeA), (.b, s.modeB)] where mode != 0 {
                guard h.engine.state.wishes.busy.isEmpty else { break }
                let type: DecorType = mode == 1 ? .chair : .lamp
                guard let did = h.insertDecor(nextDecor, type, beside: id, right: s.decorRight) else { continue }
                nextDecor += 1
                if mode == 1 {
                    h.engine.state.activities[id] = Activity(kind: .rest, target: .chair(did), startedAt: h.now)
                    targets[id] = .sitting
                } else {
                    h.engine.state.activities[id] = Activity(kind: .sleep, target: .lamp(did), startedAt: h.now)
                    targets[id] = .sleeping
                    commands = [.setDayNight(.night)]
                }
            }
            h.step(commands, s)
            for _ in 0 ..< 90 where !targets.allSatisfy({ h.engine.state.residents[$0.key]?.state == $0.value }) {
                h.step([], s)
            }
            for _ in 0 ..< s.extraFrames { h.step([], s) }

            // 触发 Wish 的那一帧，以及之后几帧（Wish 也可能由 WishDirector 自行生成）。
            h.step([.triggerWish(s.wishType, s.wisherIsB ? .b : .a)], s)
            for _ in 0 ..< 3 { h.step([], s) }
            coverage.add(sitting: h.sittingBusy, sleeping: h.sleepingBusy)
        }
        let counts = coverage.counts
        #expect(counts.sitting > 0, "no sitting resident became busy")
        #expect(counts.sleeping > 0, "no sleeping resident became busy")
    }
}
