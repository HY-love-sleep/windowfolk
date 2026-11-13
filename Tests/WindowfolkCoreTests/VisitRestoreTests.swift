import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// Visit_Wish 恢复时 Visit_Target 匹配的属性测试（V2 design.md Property 46）。
// 世界状态直接构造：0 到 6 个窗口（应用名称来自一个含大小写、空格差异和非 ASCII 的小名称池，zIndex 可重复，
// 每个窗口可见或隐藏），两位居民各自可能有或没有 Home_Window，存档里每位居民至多一个 Visit_Wish
// （保存的应用名称来自同一名称池，创建时间可能已超时）。未开局，不会补 Flower_Wish。
// 期望值按 Requirement 15.4 独立计算：候选为当前可见、所属应用名称与保存值完全相同、不是 Home_Window 的窗口；
// 恢复得到的 Visit_Target 的 zIndex 等于候选中的最小值。没有候选或已超时时 dropped，冷却起点为恢复时刻。

fileprivate let names = ["Notes", "notes", "Notes ", "Safari", "备忘录", ""]

fileprivate struct WindowSpec: Sendable {
    var name: String
    var zIndex: Int
    var visible: Bool
}

fileprivate struct VisitSpec: Sendable {
    var include: Bool
    var app: String
    var age: Double      // 恢复时刻减创建时间（秒）
}

fileprivate struct RestoreSpec: Sendable {
    var windows: [WindowSpec]
    var homeA: Int?      // 窗口序号（取模到窗口数）
    var homeB: Int?
    var visitA: VisitSpec
    var visitB: VisitSpec
    var now: Double
}

fileprivate let screen = ScreenInfo(
    frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
    visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 850))

fileprivate let nameGen = Gen<String?>.element(of: names).map { $0! }

fileprivate let windowSpec = zip(nameGen, Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...3))
    .map { WindowSpec(name: $0, zIndex: $1, visible: $2 != 0) }

/// 年龄一半在 Wish_Timeout 内（含 0），一半在其上下边界附近或之外。
fileprivate let ageGen = zip(Gen<Bool>.bool, Gen<Double>.double(in: 0..<1799), Gen<Double>.double(in: 1800...4000))
    .map { fresh, a, b in fresh ? a : b }

fileprivate let visitSpec = zip(Gen<Int>.int(in: 0...4), nameGen, ageGen)
    .map { VisitSpec(include: $0 != 0, app: $1, age: $2) }

fileprivate let restoreSpec = zip(
    windowSpec.array(of: 0...6),
    Gen<Int>.int(in: 0...5).optional(),
    Gen<Int>.int(in: 0...5).optional(),
    visitSpec, visitSpec,
    Gen<Int>.int(in: 1_000_000_000...4_000_000_000)
).map { RestoreSpec(windows: $0, homeA: $1, homeB: $2, visitA: $3, visitB: $4, now: Double($5)) }

struct VisitRestoreTests {
    // Feature: V2, Property 46: Visit_Target 恢复匹配
    // **Validates: Requirements 15.4**
    @Test func visitTargetRestoreMatching() async {
        await propertyCheck(count: 200, input: restoreSpec) { spec in
            let c = Tunables()
            let now = Date(timeIntervalSince1970: spec.now)

            var records: [WindowID: WindowRecord] = [:]
            var snapshots: [WindowSnapshot] = []
            for (i, w) in spec.windows.enumerated() {
                let snap = WindowSnapshot(
                    id: WindowID(i + 1), ownerName: w.name, ownerPID: Int32(i + 1),
                    frame: Rect(minX: Double(i) * 200, minY: 300, width: 180, height: 200), zIndex: w.zIndex)
                records[snap.id] = WindowRecord(snapshot: snap, visibility: w.visible ? .visible : .hidden)
                snapshots.append(snap)
            }
            var world = WorldState(screen: screen, windows: WindowTable(records: records))
            world.residents = [.a: Resident(id: .a, attachment: .ground(x: 300)),
                               .b: Resident(id: .b, attachment: .ground(x: 900))]
            var homes: [ResidentID: WindowID] = [:]
            if !snapshots.isEmpty {
                if let h = spec.homeA { homes[.a] = WindowID(h % snapshots.count + 1) }
                if let h = spec.homeB { homes[.b] = WindowID(h % snapshots.count + 1) }
            }
            world.story.homes = homes
            world.story.stage = nil

            var saved: [SavedWish] = []
            for (r, v) in [(ResidentID.a, spec.visitA), (.b, spec.visitB)] where v.include {
                saved.append(SavedWish(type: .visit, wisher: r, createdAt: now.addingTimeInterval(-v.age),
                                       visitTargetApp: v.app))
            }
            let save = SaveFile(
                savedAt: now, story: SavedStory(stage: nil, round: 1, doneAt: nil),
                residents: [SavedResident(id: .a, x: 300), SavedResident(id: .b, x: 900)],
                groundObjects: [], wishBook: SavedWishBook(activeWishes: saved))

            let dropped = SaveSnapshot.restoreWishes(save, into: &world, now: now, constants: c)

            let homeSet = Set(homes.values)
            var expectedDropped: [SavedWish] = []
            // 存档中的 Wish 按 (createdAt, wisher) 排序，dropped 按存档顺序返回。
            for s in save.wishBook.activeWishes {
                let candidates = snapshots.filter {
                    records[$0.id]?.visibility == .visible && $0.ownerName == s.visitTargetApp
                        && !homeSet.contains($0.id)
                }
                let minZ = candidates.map(\.zIndex).min()
                let timedOut = now.timeIntervalSince(s.createdAt) >= c.wishTimeout
                let wish = world.wishes.wish(of: s.wisher)
                if timedOut || minZ == nil {
                    expectedDropped.append(s)
                    #expect(wish == nil)
                    #expect(world.wishes.lastEnded[s.wisher] == now)
                    continue
                }
                guard let wish, let target = wish.visitTarget else {
                    Issue.record("visit wish of \(s.wisher) not restored; candidates \(candidates.map(\.id))")
                    continue
                }
                #expect(wish.type == .visit && wish.createdAt == s.createdAt && wish.state == .active)
                // 目标是候选之一，应用名称与保存值完全相同，zIndex 为候选中的最小值（即最前），不是 Home_Window。
                let chosen = candidates.first { $0.id == target.window }
                #expect(chosen != nil)
                #expect(target.ownerName == s.visitTargetApp)
                #expect(chosen?.zIndex == minZ)
                #expect(!homeSet.contains(target.window))
                #expect(world.wishes.lastEnded[s.wisher] == nil)
            }
            #expect(dropped == expectedDropped)
            #expect(world.wishes.active.count == saved.count - expectedDropped.count)
        }
    }
}
