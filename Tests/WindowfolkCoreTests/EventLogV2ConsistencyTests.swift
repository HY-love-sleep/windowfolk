import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// v2 任务 16.3：Property 52（事件记录一致）。
//
// 通过 WorldEngine（剧情启用、时区 UTC、小心思开启）随机驱动操作序列：触发各类 Wish、从 Toolbox 拖出 Decor、
// 拖动或收回已有 Decor、测试钩子直接放入 Decor、昼夜切换、窗口移动/关闭/隐藏/显示/新增、时间推进、
// 「重置世界」、「解锁全部物件」，以及按存档重启（启动落位）。每次 step 前后各取一次世界快照，只根据状态迁移
// 和测试自己记下的玩家操作独立推导本帧应写的 v2 事件，再与 `StepOutput.events` 比较：
// - Wish：`wish_started` 条数等于本帧新分配的 WishID 个数，每个新 Wish 一条且字段符合「EventType 扩充」表；
//   离开 active 的每个 Wish 恰好一条 `wish_fulfilled` 或 `wish_dropped`（Chair_Wish / Lamp_Wish 完成时 Wisher 本帧
//   进入 `sitting` / `sleeping`，放弃时 `sat` / `slept` 不早于 `wish_dropped`）；「重置世界」清除的 Wish 不写记录；
// - 顺序：`wish_started` 在由它引起的 `decor_unlocked` 之前；`sat`、`slept`、Visit_Wish 的 `visited` 在由它们
//   引起的 `wish_fulfilled` 之前；
// - `sat` / `slept` / `woke` 条数分别等于进入 `sitting`、进入 `sleeping`、离开 `sleeping` 的居民数，`woke.reason`
//   按「成为 Busy_Resident → 下落（Surface 消失）→ Night 结束 → Lamp 移走或下落」推导；
// - `decor_placed` 只在测试自己松手的 Decor 附着或（松手下落后）落地时写入，被动下落、测试钩子放入和启动落位
//   都不写；`decor_removed` 只在已放置过的 Decor 被拖回 Toolbox 时写入；
// - `thought_shown` 条数等于本帧开始显示的 Thought 数（失败、过长的结果不显示，也不写）；
// - 任何记录的 `detail` 键都属于该类型允许的键集合（没有表示帮助哪一方的键）。
// 「重置世界」与按存档重启的那一帧世界被整体重建，只检查记录字段，不检查条数。

// MARK: - 生成器

fileprivate struct ConsistencyOp: Sendable, CustomStringConvertible {
    enum Kind: Int, CaseIterable, Sendable {
        /// Debug「触发心愿」：类型取 `arg % 5`。
        case trigger
        /// 从 Decor_Slot 拖出一件新 Decor，放到 `target` 选定的位置。
        case dragFromSlot
        /// 拖动场上一件 Decor 到 `target` 选定的位置（含 Toolbox，即收回）。
        case dragDecor
        /// 测试钩子：在 active Chair_Wish / Lamp_Wish 的 Wisher 脚下（或 Ground 上）直接放入 Decor，不是玩家操作。
        case insertNear
        /// 「昼夜」子菜单。
        case dayNight
        /// 普通推进若干帧。
        case frames
        /// 长时间行走（6 秒），让 Visit_Wish、拜访邻居和追逐有机会完成。
        case walk
        /// 时钟一次跳过较长时间，再推进一帧。
        case timeJump
        /// 窗口移动、关闭、隐藏、显示或新增。
        case window
        /// Debug「重置世界」。
        case resetWorld
        /// 保存后用存档重建 WorldEngine（启动落位）。
        case restart
        /// Debug「解锁全部物件」。
        case unlockAll
    }

    var kind: Kind
    var wisherB: Bool
    var arg: Int
    var target: Int

    var description: String { "\(kind)(\(wisherB ? "b" : "a"), \(arg), t\(target))" }
}

fileprivate struct ConsistencyScenario: Sendable, CustomStringConvertible {
    var seed: UInt64
    /// 开局后先「解锁全部物件」，使 Decor_Slot 从一开始就可用。
    var unlock: Bool
    var ops: [ConsistencyOp]
    var description: String { "seed=\(seed) unlock=\(unlock) ops=\(ops)" }
}

fileprivate extension Gen where Value == ConsistencyScenario {
    static var op: Generator<ConsistencyOp, some SendableSequenceType> {
        let kinds: [ConsistencyOp.Kind] = [
            .trigger, .trigger, .trigger, .dragFromSlot, .dragFromSlot, .dragDecor, .dragDecor, .insertNear,
            .insertNear, .dayNight, .dayNight, .frames, .frames, .walk, .timeJump, .window, .window,
            .resetWorld, .restart, .unlockAll,
        ]
        return zip(
            Gen<Int>.int(in: 0...(kinds.count - 1)), Gen<Bool>.bool, Gen<Int>.int(in: 0...29),
            Gen<Int>.int(in: 0...9)
        ).map { ConsistencyOp(kind: kinds[$0], wisherB: $1, arg: $2, target: $3) }
    }

    static var scenario: Generator<ConsistencyScenario, some SendableSequenceType> {
        zip(Gen<UInt64>.uint64(), Gen<Bool>.bool, op.array(of: 1...16))
            .map { ConsistencyScenario(seed: $0, unlock: $1, ops: $2) }
    }
}

// MARK: - 测试

struct EventLogV2ConsistencyTests {
    static let screen = StoryEngineTests.screen
    static let utc = TimeZone(secondsFromGMT: 0)!
    /// UTC 08:00，不是 Night。
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let windows = WishEngineUnitTests.windows

    /// 缩短的时长，使 Thought、追逐、坐下和 Wish 调度在短序列内也能发生。
    static let constants: Tunables = {
        var c = Tunables()
        c.thoughtMinInterval = 3
        c.chaseDuration = 8
        c.sitDuration = 4
        c.wishCheckInterval = 2
        c.wishCooldown = 6
        c.wishSpawnChance = 0.5
        return c
    }()

    /// 各事件类型允许的 `detail` 键（design.md「EventType 扩充」与 v1 事件表）。
    static let allowedKeys: [EventType: Set<String>] = [
        .decorUnlocked: ["decor_type"], .decorPlaced: ["decor_type", "surface"], .decorRemoved: ["decor_type"],
        .wishStarted: ["wish_type", "wish_state"], .wishDropped: ["wish_type", "wish_state"],
        .wishFulfilled: ["wish_type", "wish_state", "chase_outcome"], .visited: ["source"], .sat: [], .slept: [],
        .woke: ["reason"], .thoughtShown: ["text"],
        .fell: ["from_state"], .landed: [], .waitingStarted: ["on"], .crossedBridge: ["from", "to"],
        .climbedLadder: ["from", "to", "direction"], .plankPlaced: ["from", "to"],
        .plankDropped: ["from", "to", "cause"], .ladderPlaced: ["top", "bottom"],
        .ladderDropped: ["top", "bottom", "cause"], .roundStarted: ["round", "giver", "receiver"],
        .planted: ["flower", "round"], .sprouted: [], .bloomed: [], .giftDelivered: ["fruit", "round"],
    ]

    /// 一次 step 前或后的世界快照。
    fileprivate struct Snap {
        var residents: [ResidentID: Resident]
        var active: [Wish]
        var nextWishID: UInt64
        var decors: [DecorID: Decor]
        var unlocked: Set<DecorType>
        var isNight: Bool
        /// 不由 Activity_Planner 控制的居民：参与 active Wish 的居民和庆祝中的居民。
        var busy: Set<ResidentID>
        var activities: [ResidentID: Activity]

        init(_ e: WorldEngine) {
            residents = e.state.residents
            active = e.state.wishes.active
            nextWishID = e.state.wishes.nextID
            decors = e.state.decors.decors
            unlocked = e.state.decors.unlocked
            isNight = e.state.isNight
            busy = e.state.wishes.busy.union(e.state.wishes.celebrations.keys)
            activities = e.state.activities
        }

        func entered(_ s: ResidentState, from before: Snap) -> [ResidentID] {
            ResidentID.allCases.filter { residents[$0]?.state == s && before.residents[$0]?.state != s }
        }

        func left(_ s: ResidentState, from before: Snap) -> [ResidentID] {
            ResidentID.allCases.filter { before.residents[$0]?.state == s && residents[$0]?.state != s }
        }
    }

    /// 本帧由测试执行的玩家松手（用于推导 `decor_placed` / `decor_removed`）。
    fileprivate struct Release {
        var id: DecorID
        var fromSlot: Bool
    }

    fileprivate final class Sim {
        var engine: WorldEngine
        var source = FakeWindowSource(snapshots: EventLogV2ConsistencyTests.windows)
        var now = EventLogV2ConsistencyTests.t0
        let seed: UInt64
        var restarts: UInt64 = 0
        var violations: [String] = []
        /// 测试直接放入的 Decor 的下一个 ID（与 Toolbox 新建的 ID 错开）。
        var nextDecorID: UInt64 = 10_000
        var nextWindowID: WindowID = 10
        /// 玩家松手后仍在下落的 Decor：落地时应写 `decor_placed`。
        var playerFalling: Set<DecorID> = []
        /// 上一帧发出、本帧返回结果的 Thought 请求。
        var pendingRequests: [ThoughtRequest] = []
        var lastOut: StepOutput?

        init(seed: UInt64) {
            self.seed = seed
            engine = WorldEngine(
                constants: EventLogV2ConsistencyTests.constants, clockStart: now,
                screen: EventLogV2ConsistencyTests.screen, rng: RandomSource(seed: seed),
                demoResident: false, story: true)
        }

        /// 对上一帧的 Thought 请求给出结果：失败、过长或合法文本。
        func thoughtResults() -> [(UInt64, ThoughtResult)] {
            pendingRequests.map { req in
                switch req.id % 4 {
                case 0: return (req.id, .failure)
                case 1: return (req.id, .text(String(repeating: "长", count: 60)))
                default: return (req.id, .text("想看看窗外\(req.id % 10)"))
                }
            }
        }

        @discardableResult
        func step(
            _ commands: [Command] = [], pointer: [PointerEvent] = [], advance: TimeInterval = 1.0 / 30,
            release: Release? = nil, restore: SaveFile? = nil, label: String
        ) -> StepOutput {
            let before = Snap(engine)
            now = now.addingTimeInterval(advance)
            if let restore {
                restarts += 1
                engine = WorldEngine(
                    constants: EventLogV2ConsistencyTests.constants, clockStart: now,
                    screen: EventLogV2ConsistencyTests.screen, rng: RandomSource(seed: seed &+ restarts),
                    demoResident: false, story: true, restored: restore)
                pendingRequests = []
                playerFalling = []
            }
            let results = thoughtResults()
            let out = engine.step(FrameInput(
                poll: source.poll(), screen: EventLogV2ConsistencyTests.screen, pointer: pointer,
                commands: commands, now: now, timeZone: EventLogV2ConsistencyTests.utc,
                thoughtsEnabled: true, thoughtResults: results))
            pendingRequests = out.thoughtRequests
            lastOut = out
            let after = Snap(engine)
            check(before: before, after: after, out: out, commands: commands, release: release,
                  isRestore: restore != nil, label: label)
            return out
        }

        // MARK: 检查

        func fail(_ label: String, _ msg: String) { violations.append("\(label): \(msg)") }

        func wishTarget(_ w: Wish) -> String? {
            switch w.type {
            case .flower, .chase: return EventRecord.residentRef(w.wisher.other)
            case .visit: return w.visitTarget.map { EventRecord.appRef($0.ownerName) }
            case .chair, .lamp: return nil
            }
        }

        /// 只根据类型能判断的 Wish 记录字段（用于无法对应到具体 Wish 的记录）。
        func checkWishForm(_ e: EventRecord, label: String) {
            guard let raw = e.detail["wish_type"], let t = WishType(rawValue: raw),
                  let actor = e.actor, let wisher = ResidentID(rawValue: actor) else {
                fail(label, "malformed wish record \(e)")
                return
            }
            switch t {
            case .flower, .chase:
                if e.target != EventRecord.residentRef(wisher.other) { fail(label, "wish target \(e)") }
            case .visit:
                if !(e.target?.hasPrefix("app:") ?? false) { fail(label, "visit wish target \(e)") }
            case .chair, .lamp:
                if e.target != nil { fail(label, "chair/lamp wish target \(e)") }
            }
            let state: String
            switch e.type {
            case .wishStarted: state = "active"
            case .wishFulfilled: state = "fulfilled"
            default: state = "dropped"
            }
            if e.detail["wish_state"] != state { fail(label, "wish_state \(e)") }
            let wantsOutcome = e.type == .wishFulfilled && t == .chase
            if wantsOutcome {
                if !["caught", "escaped"].contains(e.detail["chase_outcome"] ?? "") { fail(label, "outcome \(e)") }
            } else if e.detail["chase_outcome"] != nil {
                fail(label, "unexpected chase_outcome \(e)")
            }
        }

        func check(
            before: Snap, after: Snap, out: StepOutput, commands: [Command], release: Release?, isRestore: Bool,
            label: String
        ) {
            let ev = out.events
            let isReset = commands.contains(.resetWorld)
            let rebuilt = isReset || isRestore
            func indices(_ p: (EventRecord) -> Bool) -> [Int] { ev.indices.filter { p(ev[$0]) } }

            // detail 键集合（Requirement 18.1、21.7），v2 类型的必需键。
            for e in ev {
                guard let allowed = EventLogV2ConsistencyTests.allowedKeys[e.type] else {
                    fail(label, "unknown type \(e.type)")
                    continue
                }
                if !Set(e.detail.keys).isSubset(of: allowed) { fail(label, "detail keys \(e)") }
            }

            // MARK: Wish 记录（Requirement 6.8、6.10、18.2、22.9）
            let wishEnd: Set<EventType> = [.wishFulfilled, .wishDropped]
            var started = indices { $0.type == .wishStarted }
            var ends = indices { wishEnd.contains($0.type) }
            for i in started + ends { checkWishForm(ev[i], label: label) }

            let base: UInt64 = isReset ? 1 : before.nextWishID
            let created = Int(after.nextWishID) - Int(base)
            let newWishes = after.active.filter { $0.id.rawValue >= base }
            let afterIDs = Set(after.active.map(\.id))
            let endedWishes = rebuilt ? [] : before.active.filter { !afterIDs.contains($0.id) }
            // 「重置世界」：清除的 Wish 不写结束记录（Property 50），本帧结束记录只可能属于重置后新建的 Wish。
            // 按存档重启：重建前后的 WishID 不可比，不比较条数。
            if !isRestore {
                if started.count != created { fail(label, "wish_started \(started.count) != created \(created)") }
                let createdEnded = created - newWishes.count
                if ends.count != endedWishes.count + createdEnded {
                    fail(label, "end records \(ends.count) != ended \(endedWishes.count)+\(createdEnded)")
                }
            }
            for w in newWishes {
                guard let k = started.firstIndex(where: {
                    ev[$0].actor == EventRecord.residentRef(w.wisher) && ev[$0].target == wishTarget(w)
                        && ev[$0].detail == ["wish_type": w.type.rawValue, "wish_state": "active"]
                }) else {
                    fail(label, "no wish_started for \(w.type) by \(w.wisher)")
                    continue
                }
                started.remove(at: k)
            }
            for w in endedWishes {
                guard let k = ends.firstIndex(where: {
                    ev[$0].actor == EventRecord.residentRef(w.wisher) && ev[$0].target == wishTarget(w)
                        && ev[$0].detail["wish_type"] == w.type.rawValue
                }) else {
                    fail(label, "no end record for \(w.type) by \(w.wisher)")
                    continue
                }
                let i = ends.remove(at: k)
                let e = ev[i]
                let wisher = w.wisher
                func precededBy(_ p: (EventRecord) -> Bool) -> Bool { ev[..<i].contains(where: p) }
                switch w.type {
                case .chair, .lamp:
                    // fulfilled：Wisher 本帧进入 `sitting` / `sleeping`，且 `sat` / `slept` 写在 `wish_fulfilled` 之前。
                    // dropped：放弃之前 Wisher 没有因该 Wish 坐下或入睡；放弃后同帧由 Activity_Planner 坐下或入睡是允许的，
                    // 对应记录必须写在 `wish_dropped` 之后。
                    let (st, act): (ResidentState, EventType) = w.type == .chair ? (.sitting, .sat) : (.sleeping, .slept)
                    let ref = EventRecord.residentRef(wisher)
                    let entered = after.entered(st, from: before).contains(wisher)
                    if e.type == .wishFulfilled {
                        if !entered { fail(label, "\(w.type) wish fulfilled but wisher not \(st)") }
                        if !precededBy({ $0.type == act && $0.actor == ref }) {
                            fail(label, "\(act) not before \(w.type) wish_fulfilled")
                        }
                    } else if precededBy({ $0.type == act && $0.actor == ref }) {
                        fail(label, "\(act) before \(w.type) wish_dropped")
                    }
                case .visit:
                    if e.type == .wishFulfilled, !precededBy({
                        $0.type == .visited && $0.actor == EventRecord.residentRef(wisher)
                            && $0.target == self.wishTarget(w) && $0.detail == ["source": "visit_wish"]
                    }) {
                        fail(label, "visited not before visit wish_fulfilled")
                    }
                case .flower, .chase:
                    break
                }
            }

            // wish_started 在由它引起的 decor_unlocked 之前（Requirement 18.2）。
            var checkedOrder: Set<String> = []
            for (i, e) in ev.enumerated() where e.type == .wishStarted {
                guard let wt = e.detail["wish_type"], DecorType(rawValue: wt) != nil,
                      checkedOrder.insert(wt).inserted, !commands.contains(.unlockAllDecor) else { continue }
                if let j = ev.firstIndex(where: { $0.type == .decorUnlocked && $0.detail["decor_type"] == wt }), j < i {
                    fail(label, "decor_unlocked(\(wt)) at \(j) before wish_started at \(i)")
                }
            }

            // MARK: decor_unlocked
            let unlockTypes = ev.filter { $0.type == .decorUnlocked }.compactMap { e -> DecorType? in
                if e.actor != nil || e.target != nil { fail(label, "decor_unlocked actor/target \(e)") }
                guard e.detail.count == 1, let t = e.detail["decor_type"].flatMap(DecorType.init) else {
                    fail(label, "decor_unlocked detail \(e)")
                    return nil
                }
                return t
            }
            if !rebuilt, Set(unlockTypes) != after.unlocked.subtracting(before.unlocked)
                || unlockTypes.count != Set(unlockTypes).count {
                fail(label, "decor_unlocked \(unlockTypes) vs new \(after.unlocked.subtracting(before.unlocked))")
            }

            // MARK: sat / slept / woke（Requirement 18.3、18.5、18.6）
            let satIdx = indices { $0.type == .sat }
            let sleptIdx = indices { $0.type == .slept }
            let wokeIdx = indices { $0.type == .woke }
            for i in satIdx + sleptIdx {
                let e = ev[i]
                let kind: DecorType = e.type == .sat ? .chair : .lamp
                let ok = e.actor.flatMap(ResidentID.init) != nil && e.detail.isEmpty
                    && (after.decors.values.contains { EventRef.decor($0.id) == e.target && $0.type == kind })
                if !ok { fail(label, "malformed \(e.type) \(e)") }
            }
            for i in wokeIdx where ev[i].target != nil || ev[i].actor.flatMap(ResidentID.init) == nil {
                fail(label, "malformed woke \(ev[i])")
            }
            if !rebuilt {
                // 进入 `sitting`：每次恰好一条 `sat`。离开 `sitting` 不写记录，因此首尾都在 `sitting` 时只允许两种
                // 同帧「离开再坐下」：坐着的居民被触发新 Wish 成为 Busy_Resident 而起身，随即完成 Chair_Wish 坐回；
                // 或所坐 Chair 被玩家拖走而起身（Requirement 3.8），同帧选中旁边另一把 Chair 的 `rest` 并立即坐下
                // （此时所坐 Chair 变了）。
                for r in ResidentID.allCases {
                    let ref = EventRecord.residentRef(r)
                    let mine = satIdx.filter { ev[$0].actor == ref }
                    let entered = after.entered(.sitting, from: before).contains(r)
                    let stayed = before.residents[r]?.state == .sitting && after.residents[r]?.state == .sitting
                    let oldSeat = before.residents[r]?.seat
                    let oldSeatTaken = oldSeat.map { id -> Bool in
                        guard let d = after.decors[id] else { return true }
                        if case .attached = d.placement { return false }
                        return true
                    } ?? false
                    let seatChanged = oldSeat != after.residents[r]?.seat && oldSeatTaken
                    let resat = stayed && mine.count == 1 && (seatChanged || ev[..<mine[0]].contains {
                        $0.type == .wishStarted && $0.actor == ref
                    })
                    if mine.count != (entered ? 1 : 0), !resat {
                        fail(label, "sat \(mine.count) for \(r): entered=\(entered) stayed=\(stayed)")
                    }
                    if entered || resat {
                        let want = after.residents[r]?.seat.map(EventRef.decor)
                        if !mine.contains(where: { ev[$0].target == want }) {
                            fail(label, "no sat for \(r) on \(String(describing: want))")
                        }
                    }
                }
                // 进入、离开 `sleeping`：按本帧记录顺序逐条重放每位居民的 sleeping 标志。`slept` 只能在不睡时出现，
                // `woke` 只能在睡着时出现，重放结果必须等于 step 结束时的状态。同一帧内可以先离开再进入（例如睡着的
                // 居民被触发 Lamp_Wish：成为 Busy_Resident 而 `woke`，随即在旁边的 Lamp 完成心愿而 `slept`），
                // 因此 `slept` 条数等于进入次数、`woke` 条数等于离开次数，而不只是首尾状态之差。
                for r in ResidentID.allCases {
                    let ref = EventRecord.residentRef(r)
                    var asleep = before.residents[r]?.state == .sleeping
                    var startedWish = false
                    for e in ev where e.actor == ref {
                        switch e.type {
                        case .wishStarted: startedWish = true
                        case .slept:
                            if asleep { fail(label, "slept while already sleeping: \(r)") }
                            asleep = true
                        case .woke:
                            if !asleep { fail(label, "woke while not sleeping: \(r)") }
                            asleep = false
                            // 同帧又睡回去的那次离开：只可能是成为 Busy_Resident（其余原因下不会立刻再入睡）。
                            if after.residents[r]?.state == .sleeping,
                               e.detail != ["reason": "became_busy"] || !startedWish {
                                fail(label, "woke-then-slept for \(r) without new wish: \(e)")
                            }
                        default: break
                        }
                    }
                    if asleep != (after.residents[r]?.state == .sleeping) {
                        fail(label, "sleep replay \(asleep) != state \(String(describing: after.residents[r]?.state)) for \(r)")
                    }
                }
                for r in after.entered(.sleeping, from: before)
                where !sleptIdx.contains(where: { ev[$0].actor == EventRecord.residentRef(r) }) {
                    fail(label, "no slept for \(r)")
                }
                let wakers = after.left(.sleeping, from: before)
                for r in wakers {
                    let state = after.residents[r]?.state
                    let reason: String
                    if after.busy.contains(r), !before.busy.contains(r) {
                        reason = "became_busy"
                    } else if state == .falling || state == .hanging {
                        reason = "surface_gone"
                    } else if !after.isNight {
                        reason = "night_ended"
                    } else {
                        reason = "lamp_moved"
                        if case let .lamp(l)? = before.activities[r]?.target,
                           case .attached? = after.decors[l]?.placement {
                            fail(label, "\(r) woke with lamp \(l) still placed")
                        }
                    }
                    if !wokeIdx.contains(where: {
                        ev[$0].actor == EventRecord.residentRef(r) && ev[$0].detail == ["reason": reason]
                    }) {
                        fail(label, "no woke(\(reason)) for \(r): \(wokeIdx.map { ev[$0] })")
                    }
                }
            }

            // MARK: visited（Requirement 18.5）
            for (i, e) in ev.enumerated() where e.type == .visited {
                guard let actor = e.actor, let v = ResidentID(rawValue: actor) else {
                    fail(label, "visited actor \(e)")
                    continue
                }
                switch e.detail["source"] {
                case "visit_neighbor"?:
                    guard let host = e.target.flatMap(ResidentID.init), host != v, !rebuilt else {
                        if !rebuilt { fail(label, "visit_neighbor target \(e)") }
                        continue
                    }
                    let a = before.activities[v]
                    var staying = false
                    if case .staying? = a?.phase { staying = true }
                    if a?.kind != .visitNeighbor || a?.target != .resident(host) || !staying {
                        fail(label, "visit_neighbor without staying activity: \(String(describing: a))")
                    }
                case "visit_wish"?:
                    guard !rebuilt else { continue }
                    // 对应的 Visit_Wish 可能是上一帧起 active 的，也可能在本帧刚开始（Wisher 已站在 Visit_Target 上，
                    // 同帧即完成）。
                    let w = before.active.first { $0.type == .visit && $0.wisher == v }
                    let startedHere = ev[..<i].contains {
                        $0.type == .wishStarted && $0.actor == actor && $0.detail["wish_type"] == "visit"
                            && $0.target == e.target
                    }
                    if !startedHere, w == nil || e.target != w.flatMap(wishTarget) {
                        fail(label, "visit_wish visited without matching wish \(e)")
                    }
                    if !ev[(i + 1)...].contains(where: {
                        $0.type == .wishFulfilled && $0.actor == actor && $0.detail["wish_type"] == "visit"
                    }) {
                        fail(label, "visit_wish visited without later wish_fulfilled")
                    }
                default:
                    fail(label, "visited source \(e)")
                }
            }

            // MARK: decor_placed / decor_removed（Requirement 3.10、18.4）
            func surfaceTag(_ d: Decor) -> String? {
                guard case let .attached(a) = d.placement else { return nil }
                switch a {
                case .window: return "window_ledge"
                case .plank: return "plank"
                case .ground: return "ground"
                default: return nil
                }
            }
            var expectedPlaced: [DecorID] = []
            var expectedRemoved: [Decor] = []
            if isReset { playerFalling = [] }
            for id in playerFalling.sorted() {
                guard let d = after.decors[id] else { playerFalling.remove(id); continue }
                switch d.placement {
                case .attached: expectedPlaced.append(id); playerFalling.remove(id)
                case .dragged: playerFalling.remove(id)
                case .falling: break
                }
            }
            if let r = release, !isReset {
                if let d = after.decors[r.id] {
                    switch d.placement {
                    case .attached: expectedPlaced.append(r.id)
                    case .falling: playerFalling.insert(r.id)
                    case .dragged: fail(label, "decor \(r.id) still dragged after release")
                    }
                } else if !r.fromSlot, let d = before.decors[r.id] {
                    expectedRemoved.append(d)
                }
            }
            var placed = indices { $0.type == .decorPlaced }
            for id in expectedPlaced {
                guard let d = after.decors[id],
                      let k = placed.firstIndex(where: {
                          ev[$0].target == EventRef.decor(id) && ev[$0].actor == EventRecord.playerActor
                              && ev[$0].detail == ["decor_type": d.type.rawValue, "surface": surfaceTag(d) ?? "?"]
                      }) else {
                    fail(label, "missing decor_placed for \(id)")
                    continue
                }
                placed.remove(at: k)
            }
            if !placed.isEmpty { fail(label, "unexpected decor_placed \(placed.map { ev[$0] })") }
            var removed = indices { $0.type == .decorRemoved }
            for d in expectedRemoved {
                guard let k = removed.firstIndex(where: {
                    ev[$0].target == EventRef.decor(d.id) && ev[$0].actor == EventRecord.playerActor
                        && ev[$0].detail == ["decor_type": d.type.rawValue]
                }) else {
                    fail(label, "missing decor_removed for \(d.id)")
                    continue
                }
                removed.remove(at: k)
            }
            if !removed.isEmpty { fail(label, "unexpected decor_removed \(removed.map { ev[$0] })") }

            // MARK: thought_shown（Requirement 18.5）
            let shown = ev.filter { $0.type == .thoughtShown }
            let newThoughts = ResidentID.allCases.compactMap { r -> (ResidentID, String)? in
                guard let t = after.residents[r]?.thought, t != before.residents[r]?.thought else {
                    return nil
                }
                return (r, t.text)
            }
            if shown.count != newThoughts.count {
                fail(label, "thought_shown \(shown.count) != shown \(newThoughts.count)")
            }
            for (r, text) in newThoughts where !shown.contains(where: {
                $0.actor == EventRecord.residentRef(r) && $0.target == nil && $0.detail == ["text": text]
            }) {
                fail(label, "missing thought_shown for \(r)")
            }
        }

        // MARK: 操作

        func insert(_ type: DecorType, at a: CoreAttachment) {
            guard engine.state.decors.count < engine.constants.maxDecorCount else { return }
            // `insertDecor` 遇到已有 ID 会替换原 Decor；插入第一件后 DecorStore 从 10001 起分配，Toolbox 新建的
            // Decor 可能占用测试计数器的下一个 ID，因此取两者较大者，避免把场上物件悄悄换掉。
            nextDecorID = max(nextDecorID, engine.state.decors.nextID)
            engine.insertDecor(Decor(id: DecorID(nextDecorID), type: type, placement: .attached(a)))
            nextDecorID += 1
        }

        /// 拖放目标：窗沿上（按 Decor 尺寸换算成抓取点）、Toolbox（收回）、半空。
        func dropPoint(_ sel: Int, arg: Int, type: DecorType) -> Point {
            let ws = source.windows.filter { !$0.isHidden }
            switch sel {
            case 0...4 where !ws.isEmpty:
                let f = ws[(sel + arg) % ws.count].snapshot.frame
                let bottom = Point(x: f.minX + f.width * Double(arg % 10 + 1) / 11, y: f.minY - Double(arg % 3) * 3)
                return SpriteMetrics.decorRect(type: type, bottomCenter: bottom).center
            case 5, 6:
                let tb = ToolboxLayout.frame(screen: EventLogV2ConsistencyTests.screen,
                                             unlocked: engine.state.decors.unlocked)
                return Point(x: tb.midX, y: tb.minY - 10)
            default:
                return Point(x: 200 + Double(arg) * 40, y: 150 + Double(sel) * 20)
            }
        }

        /// 按下、移动两次、松开，共 4 帧；松开那一帧带上被拖动的 Decor 供检查。之后推进若干帧让松手下落的 Decor 落地。
        func drag(from p: Point, to q: Point, fromSlot: Bool, label: String) {
            step(pointer: [.down(p)], label: "\(label) down")
            step(pointer: [.moved(Point(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2))], label: "\(label) move")
            step(pointer: [.moved(q)], label: "\(label) move")
            let dragged = engine.state.decors.decors.values.first { $0.placement.isDragged }
            step(pointer: [.up(q)], release: dragged.map { Release(id: $0.id, fromSlot: fromSlot) },
                 label: "\(label) up")
            for _ in 0 ..< 40 { step(label: "\(label) settle") }
        }

        func run(_ op: ConsistencyOp) {
            let label = "\(op)"
            let wisher: ResidentID = op.wisherB ? .b : .a
            switch op.kind {
            case .trigger:
                let t = WishType.allCases[op.arg % WishType.allCases.count]
                step([.triggerWish(t, t == .flower ? nil : wisher)], label: label)
            case .dragFromSlot:
                let t: DecorType = op.wisherB ? .lamp : .chair
                guard let z = ToolboxLayout.zoneFrame(
                    .decor(t), screen: EventLogV2ConsistencyTests.screen, unlocked: engine.state.decors.unlocked)
                else { step(label: label); return }
                drag(from: Point(x: z.midX, y: z.midY), to: dropPoint(op.target, arg: op.arg, type: t),
                     fromSlot: true, label: label)
            case .dragDecor:
                // 选一个确实命中 Decor 的抓取点（居民和物件的命中优先级更高）。
                let regions = (lastOut ?? step(label: label)).view.hitRegions
                var grabs: [(Point, DecorID)] = []
                for reg in regions {
                    guard case let .decor(id) = reg.target else { continue }
                    let r = reg.rect
                    let candidates = [
                        Point(x: r.midX, y: r.midY), Point(x: r.minX + 2, y: r.midY), Point(x: r.maxX - 2, y: r.midY),
                        Point(x: r.midX, y: r.minY + 2), Point(x: r.midX, y: r.maxY - 2),
                    ]
                    if let p = candidates.first(where: { HitTesting.hitTest($0, regions: regions) == .decor(id) }) {
                        grabs.append((p, id))
                    }
                }
                guard !grabs.isEmpty else { step(label: label); return }
                let (p, id) = grabs[op.arg % grabs.count]
                let type = engine.state.decors.decors[id]?.type ?? .chair
                drag(from: p, to: dropPoint(op.target, arg: op.arg, type: type), fromSlot: false, label: label)
            case .insertNear:
                let wishes = engine.state.wishes.active.filter { $0.type == .chair || $0.type == .lamp }
                if !wishes.isEmpty {
                    let w = wishes[op.arg % wishes.count]
                    if let r = engine.state.residents[w.wisher] {
                        switch r.attachment {
                        case .window, .ground: insert(w.type == .chair ? .chair : .lamp, at: r.attachment)
                        default: break
                        }
                    }
                } else if let r = engine.state.residents[wisher] {
                    switch r.attachment {
                    case .window, .ground: insert(op.arg % 2 == 0 ? .chair : .lamp, at: r.attachment)
                    default: break
                    }
                }
                for _ in 0 ..< 3 { step(label: label) }
            case .dayNight:
                let o: [DayNightOverride] = [.night, .night, .day, .auto]
                step([.setDayNight(o[op.arg % o.count])], label: label)
                for _ in 0 ..< 2 { step(label: label) }
            case .frames:
                for _ in 0 ... op.arg * 2 { step(label: label) }
            case .walk:
                for _ in 0 ..< 180 { step(label: label) }
            case .timeJump:
                let jumps: [TimeInterval] = [3, 5, 9, 30, 120, 1801, 4 * 3600, 11 * 3600]
                step(advance: jumps[op.arg % jumps.count], label: label)
                step(label: label)
            case .window:
                let ids = source.windows.map(\.snapshot.id)
                guard !ids.isEmpty else { step(label: label); return }
                let id = ids[op.arg % ids.count]
                switch op.target {
                case 0...3:
                    if let f = source.window(id)?.snapshot.frame {
                        source.move(id, to: Point(x: f.minX + Double(op.arg - 15) * 6, y: f.minY + Double(op.target - 1) * 30))
                    }
                case 4, 5: source.close(id)
                case 6: source.hide(id)
                case 7: source.show(id)
                default:
                    if source.count < 5 {
                        source.add(StoryEngineTests.win(nextWindowID, x: 150 + Double(op.arg) * 35, y: 250))
                        nextWindowID += 1
                    } else {
                        source.show(id)
                    }
                }
                for _ in 0 ..< 3 { step(label: label) }
            case .resetWorld:
                step([.resetWorld], label: label)
            case .restart:
                let save = engine.makeSave(now: now)
                if op.wisherB, let id = source.windows.first?.snapshot.id { source.close(id) }
                step(restore: save, label: label)
                step(label: label)
            case .unlockAll:
                step([.unlockAllDecor], label: label)
            }
        }
    }

    // Feature: V2, Property 52: 事件记录一致
    // **Validates: Requirements 3.10, 6.8, 6.10, 18.2, 18.3, 18.4, 18.5, 18.6, 21.7, 22.9**
    @Test func eventLogIsConsistentWithStateTransitions() async {
        await propertyCheck(count: 100, input: Gen<ConsistencyScenario>.scenario) { s in
            let sim = Sim(seed: s.seed)
            sim.step(label: "start")
            if s.unlock { sim.step([.unlockAllDecor], label: "unlock") }
            for op in s.ops where sim.violations.isEmpty {
                sim.run(op)
            }
            #expect(sim.violations.isEmpty, "\(sim.violations.prefix(3))")
        }
    }
}
