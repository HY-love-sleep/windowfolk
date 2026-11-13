import Foundation

// WorldEngine 的 V2 编排（design.md「每帧更新顺序（V2）」与「WorldEngine 编排改动」，任务 5.6）。
//
// 本文件只按顺序调用独立的规则组件（DayNight、ActivityPlanner），不写规则本身：
// - 第 8 步：每帧 DayNight 判定，写 `WorldState.isNight`（Requirement 5.1、5.2、17.4）；
// - 第 11 步：`ActivityPlanner.plan`（居民移动之前）；
// - 第 13 步：`ActivityPlanner.resolve`（居民移动之后），写 `sat`、`slept`、`woke`、`visited`（Requirement 18.3、18.5、18.6）；
// - 第 14 步：Zzz 气泡覆盖（Requirement 5.6）；
// - 第 16 步：`ThoughtEngine.step`（全部事件产生之后），写 `thought_shown`（Requirement 14）；
// - 玩家开始拖动有人坐的 Chair 时同帧让居民 `idle`、清 `seat`（Requirement 3.8）；
// - 每次 step 结束前校正 Chair 占用（Requirement 4.13）。
//
// 自主活动只在 `activitiesEnabled` 为 true 时运行（剧情启用的世界默认启用，见 `WorldEngine.init`）。
// 参与 active Wish 的居民（`WishBook.busy`）、Wish 完成后庆祝中的居民、调试寻找中的都都不由 Activity_Planner
// 控制，Goal 由 WishDirector、StoryDirector 或调试命令写入；其余居民由 Activity_Planner 控制。
// 新成为 Busy_Resident 的居民在 `ActivityPlanner.plan`（第 11 步，与 `WishDirector.plan` 同一帧）中结束 Activity：
// `sitting` 释放 Chair，`sleeping` 写 `woke(became_busy)`（Requirement 4.12）。
// WishDirector 的编排（第 9、10、13 步）和 Wish 事件记录在 `WorldEngine.swift`（需要访问剧情的私有部分）。

extension WorldEngine {
    // MARK: - 昼夜（第 8 步）

    /// 按 Local_Clock（`now`、`timeZone`）和昼夜覆盖更新 Night 判定（Requirement 5.1、5.2、17.4）。
    func updateDayNight(now: Date, timeZone: TimeZone) {
        state.isNight = DayNight.isNight(
            now: now, timeZone: timeZone, override: state.dayNightOverride,
            nightStart: constants.nightStart, nightEnd: constants.nightEnd)
    }

    // MARK: - Busy_Resident 与戳居民

    /// 当前不由 Activity_Planner 控制的居民：Busy_Resident（`WishBook.busy`），Wish 完成后庆祝中的居民
    /// （庆祝结束后再选择 Activity，Requirement 9.8、22.6），调试寻找中的都都。
    func busyResidents() -> Set<ResidentID> {
        var busy = state.wishes.busy
        busy.formUnion(state.wishes.celebrations.keys)
        if seekOverride != nil || debugSeekActive { busy.insert(.a) }
        return busy
    }

    /// 点击时不跳跃、只显示「?」的居民（v2 Requirement 5.9、20.9、21.8）：`sleeping` 的居民（本身不在
    /// `jumpingStates` 中，这里再显式列出），以及 active Chase_Wish（`ready` 或 `running`）的 Chaser 和 Runner。
    func jumpBlockedResidents() -> Set<ResidentID> {
        var blocked = Set(state.residents.values.filter { $0.state == .sleeping }.map(\.id))
        for w in state.wishes.active where w.type == .chase {
            blocked.formUnion(w.participants)
        }
        return blocked
    }

    // MARK: - Chair 被拖动（Requirement 3.8）

    /// 玩家开始拖动一把有人坐的 Chair：坐着的居民同一帧转为 `idle`、释放 Chair，留在原 Surface 原位置。
    func unseatFromDraggedChairs(_ outcomes: [InteractionOutcome]) {
        for case let .dragStarted(.decor(did)) in outcomes {
            for id in sortedResidentIDs where state.residents[id]?.seat == did {
                guard var r = state.residents[id] else { continue }
                if r.state == .sitting { r.state = .idle }
                r.seat = nil
                state.residents[id] = r
            }
        }
    }

    /// 每次 step 结束前保证 Chair 占用不变量（Requirement 4.13）：不在 `sitting` 的居民不占用 Chair；
    /// `sitting` 的居民所坐的 Chair 必须存在、放在 Surface 上且没有被另一位居民占用，否则转为 `idle`。
    func reconcileSeats() {
        var taken: Set<DecorID> = []
        for id in sortedResidentIDs {
            guard var r = state.residents[id] else { continue }
            var changed = false
            if r.state != .sitting {
                if r.seat != nil { r.seat = nil; changed = true }
            } else if let seat = r.seat, let d = state.decors.decors[seat], d.type == .chair,
                      case .attached = d.placement, !taken.contains(seat) {
                taken.insert(seat)
            } else {
                r.state = .idle
                r.seat = nil
                changed = true
            }
            if changed { state.residents[id] = r }
        }
    }

    // MARK: - Activity（第 11、13 步）

    /// 第 11 步：为非 Busy 居民推进和选择 Activity，写 Goal（居民移动之前）。
    func planActivities(now: Date) {
        guard activitiesEnabled, pendingRestore == nil else { return }
        updateDebugSeek()
        var residents = state.residents
        var activities = state.activities
        let eligible = Set(residents.keys).subtracting(busyResidents())
        let events = ActivityPlanner.plan(
            residents: &residents, activities: &activities, eligible: eligible,
            ctx: activityContext(now: now, residents: residents), rng: &rng)
        state.residents = residents
        state.activities = activities
        // `preferHome` 只影响下一次选择（Requirement 9.8）：选出 Activity 后移除。
        for id in preferHome where eligible.contains(id) && activities[id] != nil {
            preferHome.remove(id)
        }
        recordActivityEvents(events)
    }

    /// 第 13 步：到达判定、坐下、入睡、拜访与赏花停留（居民移动之后）。
    func resolveActivities(now: Date) {
        guard activitiesEnabled, pendingRestore == nil else { return }
        var residents = state.residents
        var activities = state.activities
        let eligible = Set(residents.keys).subtracting(busyResidents())
        let events = ActivityPlanner.resolve(
            residents: &residents, activities: &activities, eligible: eligible,
            ctx: activityContext(now: now, residents: residents))
        state.residents = residents
        state.activities = activities
        recordActivityEvents(events)
    }

    /// 每次 step 结束前：居民在 `plan` 之后才进入 `falling`、`hanging`（移动中失去支撑、帧末支撑校正）时，
    /// 同帧放弃其 Activity（Requirement 4.1、4.11）。
    func endAirborneActivities() {
        guard activitiesEnabled, pendingRestore == nil else { return }
        var residents = state.residents
        var activities = state.activities
        let events = ActivityPlanner.endAirborneActivities(
            residents: &residents, activities: &activities,
            eligible: Set(residents.keys).subtracting(busyResidents()))
        state.residents = residents
        state.activities = activities
        recordActivityEvents(events)
    }

    /// 剧情未启用时的调试寻找：都都走到嘟嘟身边（同一 Surface、x 差 ≤ Gift_Reach_Distance）或任一方不存在时结束。
    private func updateDebugSeek() {
        guard debugSeekActive else { return }
        let world = movementContext()
        guard let a = state.residents[.a], let b = state.residents[.b] else {
            debugSeekActive = false
            return
        }
        if !isOnHiddenWindow(a), !isOnHiddenWindow(b),
           let la = ResidentController.location(of: a, world: world),
           let lb = ResidentController.location(of: b, world: world),
           la.surface == lb.surface, abs(la.x - lb.x) <= constants.giftReachDistance {
            debugSeekActive = false
        } else if a.goal != .reach(.b) {
            // 调试命令被其他目标取代（例如测试直接改了 Goal）：结束。
            debugSeekActive = false
        }
    }

    /// 居民移动使用的只读世界信息。
    func movementContext() -> WorldContext {
        WorldContext(
            windows: state.windows, surfaces: state.surfaces, screen: state.screen, constants: constants,
            nav: state.nav, ladders: state.ladders.lookup(windows: state.windows))
    }

    /// 由当前世界状态构造 ActivityPlanner 的输入。
    func activityContext(now: Date, residents: [ResidentID: Resident]) -> ActivityContext {
        let world = movementContext()
        var locations: [ResidentID: ResidentLocation] = [:]
        var seats: [ResidentID: DecorID] = [:]
        for (id, r) in residents {
            if let seat = r.seat { seats[id] = seat }
            guard !isOnHiddenWindow(r) else { continue }
            locations[id] = ResidentController.location(of: r, world: world)
        }
        var decorLocations: [DecorID: ResidentLocation] = [:]
        for did in state.decors.sortedIDs {
            guard let d = state.decors.decors[did], case let .attached(a) = d.placement,
                  !isAttachmentHidden(a) else { continue }
            decorLocations[did] = ActivityContext.location(of: a, world: world)
        }
        var itemLocations: [ItemID: ResidentLocation] = [:]
        for iid in state.items.sortedIDs {
            guard let it = state.items[iid], case let .attached(a) = it.placement, !isAttachmentHidden(a) else {
                continue
            }
            itemLocations[iid] = ActivityContext.location(of: a, world: world)
        }
        var homes = state.story.homes
        for (id, _) in homes where residents[id] == nil { homes[id] = nil }
        return ActivityContext(
            nav: state.nav, locations: locations, decors: state.decors, seats: seats, items: state.items,
            homes: homes, isNight: state.isNight, now: now, constants: constants,
            preferHome: preferHome.intersection(residents.keys), decorLocations: decorLocations, itemLocations: itemLocations, world: world)
    }

    // MARK: - 气泡（第 14 步）

    /// Zzz 气泡（Requirement 5.6）：`sleeping` 的居民没有其他气泡时显示 Zzz；离开 `sleeping` 的同一帧消失。
    func applyActivityBubbles() {
        for id in sortedResidentIDs {
            guard var r = state.residents[id] else { continue }
            if r.state == .sleeping {
                guard r.bubble == nil || r.bubble == .dots else { continue }
                r.bubble = .zzz
            } else if r.bubble == .zzz {
                r.bubble = nil
            } else {
                continue
            }
            state.residents[id] = r
        }
    }

    /// Wish_Bubble（Requirement 6.8、6.9、7.1、7.4、9.3、20.3）：active 的非送花 Wish 的 Wisher 显示对应图标，
    /// 代替「...」（Requirement 6.13）；Visit_Wish 的箭头指向 Visit_Flag。Wish 结束的同一帧清除（Requirement 6.10、
    /// 6.11、10.5）。「?」由 `ResidentView.poke` 单独给出，渲染层在「?」显示期间隐藏 Wish_Bubble（Requirement 10.6）。
    /// 送花仍按 v1 R16.2 由 `applyStoryBubbles` 处理。心形（拜访、种花）等其他气泡优先保留。
    func applyWishBubbles() {
        var icons: [ResidentID: WishIcon] = [:]
        let world = movementContext()
        for w in state.wishes.active {
            guard let r = state.residents[w.wisher] else { continue }
            let rx = isOnHiddenWindow(r) ? nil : ResidentController.currentSurface(of: r, world: world)?.position.x
            let fx = w.visitTarget.flatMap { WishDirector.visitFlagX(window: $0.window, surfaces: state.surfaces) }
            if let icon = WishDirector.wishIcon(for: w, resident: w.wisher, residentX: rx, flagX: fx) {
                icons[w.wisher] = icon
            }
        }
        for id in sortedResidentIDs {
            guard var r = state.residents[id] else { continue }
            if let icon = icons[id] {
                // 心形（拜访停留）由 Wish_Bubble 覆盖：Wisher 持续显示 Wish_Bubble（Requirement 6.8、6.9）。
                // Chase_Wish 结束后的庆祝心形（Requirement 22.3）出现时该 Wish 已不是 active，不在 `icons` 中。
                switch r.bubble {
                case nil, .dots?, .zzz?, .heart?, .wishIcon?: r.bubble = .wishIcon(icon)
                default: continue
                }
            } else if case .wishIcon? = r.bubble {
                r.bubble = nil
            } else {
                continue
            }
            state.residents[id] = r
        }
    }

    /// Visit_Flag 位置（Requirement 9.2、9.7、9.9）：每个 active Visit_Wish 的 Visit_Target 当前最长一段窗沿中点。
    /// Visit_Target 隐藏时其窗沿不在路面中，因此没有旗。
    func visitFlags() -> [Point] {
        state.wishes.active.compactMap { w in
            w.visitTarget.flatMap { WishDirector.visitFlagPoint(window: $0.window, surfaces: state.surfaces) }
        }
    }

    // MARK: - Thought（第 16 步）

    /// 推进 Thought_Engine（v2 Requirement 14）。在全部事件产生之后调用，能看到本帧的 `wish_fulfilled`、`landed`、
    /// `woke`、`visited`。本帧开始显示的 Thought 写一条 `thought_shown`（v2 Requirement 14.8）。返回本帧发出的请求。
    /// 只写 `WorldState.thoughts` 和 `Resident.thought`，不影响其他世界状态（v2 Requirement 12.5）。
    func updateThoughts(_ input: FrameInput) -> [ThoughtRequest] {
        var residents = state.residents
        var thoughts = state.thoughts
        let (requests, shown) = thoughts.step(
            events: eventLog.records, results: input.thoughtResults, enabled: input.thoughtsEnabled,
            residents: &residents, suppressed: thoughtSuppressed(worldHidden: input.worldHidden),
            now: input.now, timeZone: input.timeZone, constants: constants)
        state.thoughts = thoughts
        state.residents = residents
        for r in shown {
            eventLog.add(r.type, actor: r.actor, target: r.target, detail: r.detail)
        }
        return requests
    }

    /// 不能显示 Thought 的居民（v2 Requirement 14.3）：`falling`、`hanging`、`sleeping`，附着在 Hidden_Window 上；
    /// 世界因全屏隐藏时是全部居民。
    func thoughtSuppressed(worldHidden: Bool) -> Set<ResidentID> {
        if worldHidden { return Set(state.residents.keys) }
        let blocked: Set<ResidentState> = [.falling, .hanging, .sleeping]
        return Set(state.residents.values.filter { blocked.contains($0.state) || isOnHiddenWindow($0) }.map(\.id))
    }

    // MARK: - 事件（Requirement 18.3、18.5、18.6）

    /// `sat`、`slept`：`target` 为 `decor:<id>`；`woke`：`detail.reason`；`visited`：`target` 为被拜访者，
    /// `detail.source` 为 `visit_neighbor`（design.md「EventType 扩充」）。
    func recordActivityEvents(_ events: [ActivityEvent]) {
        for e in events {
            switch e {
            case let .sat(r, d):
                eventLog.add(.sat, actor: EventRecord.residentRef(r), target: EventRef.decor(d))
            case let .slept(r, d):
                eventLog.add(.slept, actor: EventRecord.residentRef(r), target: EventRef.decor(d))
            case let .woke(r, reason):
                eventLog.add(.woke, actor: EventRecord.residentRef(r), detail: ["reason": reason.rawValue])
            case let .visited(visitor, host):
                eventLog.add(.visited, actor: EventRecord.residentRef(visitor),
                             target: EventRecord.residentRef(host), detail: ["source": "visit_neighbor"])
            }
        }
    }
}
