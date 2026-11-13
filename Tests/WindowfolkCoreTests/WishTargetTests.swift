import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 一个 Decor 的生成参数。
fileprivate struct DecorTargetSpec: Sendable {
    var isChair: Bool
    var surfaceIndex: Int
    /// 0...4，位置为 Surface 上的 frac / 4。取离散值以便制造同点（长度相等）的并列。
    var frac: Int
    /// 0...3，取小范围以便制造 `placedSeq` 并列。
    var seq: Int
    /// false 时为拖动中（不应被选中）。
    var attached: Bool
    /// false 时不出现在 `decorLocations` 中（如在 Hidden_Window 上）。
    var located: Bool
}

/// 一个随机场景：v1 窗口布局、木板、梯子，Wisher 位置，若干 Decor，两位居民各自坐着的 Decor 下标。
fileprivate struct DecorTargetWorld: Sendable {
    var windows: [WindowSnapshot]
    var screen: ScreenInfo
    var plankSpecs: [NavGraphTests.PlankSpec]
    var ladderSpecs: [NavGraphTests.LadderSpec]
    var startIndex: Int
    var startFrac: Double
    var decors: [DecorTargetSpec]
    var wantChair: Bool
    /// 下标超出 Decor 数量时表示没有坐着。
    var wisherSeat: Int
    var otherSeat: Int
}

fileprivate extension Gen where Value == DecorTargetWorld {
    static var decorTargetWorld: Generator<DecorTargetWorld, some SendableSequenceType> {
        let decor = zip(
            Gen<Bool>.bool, Gen<Int>.int(in: 0...999), Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...3),
            Gen<Int>.int(in: 0...5), Gen<Int>.int(in: 0...5)
        ).map {
            DecorTargetSpec(isChair: $0, surfaceIndex: $1, frac: $2, seq: $3, attached: $4 > 0, located: $5 > 0)
        }
        return zip(
            Gen<[WindowSnapshot]>.windowLayout,
            Gen<ScreenInfo>.screen,
            NavGraphTests.plankSpecs,
            NavGraphTests.ladderSpecs,
            Gen<Int>.int(in: 0...999),
            Gen<Double>.double(in: 0...1),
            decor.array(of: 0...7),
            Gen<Bool>.bool,
            Gen<Int>.int(in: 0...9),
            Gen<Int>.int(in: 0...9)
        ).map {
            DecorTargetWorld(windows: $0, screen: $1, plankSpecs: $2, ladderSpecs: $3, startIndex: $4,
                             startFrac: $5, decors: $6, wantChair: $7, wisherSeat: $8, otherSeat: $9)
        }
    }
}

struct WishTargetTests {
    /// 参考判定：按类型、附着、可见位置、Chair 未被他人占用、可达筛选，再按（长度、placedSeq、ID）排序。
    fileprivate static func referenceCandidates(
        _ type: DecorType, wisher: ResidentID, field: HorizontalField, decors: [Decor],
        locations: [DecorID: ResidentLocation], seats: [ResidentID: DecorID]
    ) -> [(id: DecorID, length: Double, seq: UInt64)] {
        let takenByOthers = Set(seats.filter { $0.key != wisher }.map(\.value))
        var out: [(id: DecorID, length: Double, seq: UInt64)] = []
        for d in decors {
            guard d.type == type else { continue }
            guard case .attached = d.placement else { continue }
            guard let loc = locations[d.id] else { continue }
            if type == .chair && takenByOthers.contains(d.id) { continue }
            guard let len = field.length(to: loc.surface, x: loc.x) else { continue }
            out.append((d.id, len, d.placedSeq))
        }
        return out.sorted { l, r in
            if l.length != r.length { return l.length < r.length }
            if l.seq != r.seq { return l.seq < r.seq }
            return l.id < r.id
        }
    }

    // Feature: V2, Property 22: Decor 目标选择
    // **Validates: Requirements 7.2, 7.5**
    @Test func decorTargetIsShortestThenEarliestPlacedAndSticky() async {
        await propertyCheck(count: 100, input: Gen.decorTargetWorld) { w in
            let k = Tunables()
            let planks = NavGraphTests.makePlanks(w.plankSpecs, windows: w.windows)
            let placedLadders = NavGraphTests.makeLadders(w.ladderSpecs, windows: w.windows, screen: w.screen)
            var table = WindowTable()
            for win in w.windows { table.records[win.id] = WindowRecord(snapshot: win, visibility: .visible) }
            let surfaces = SurfaceBuilder.build(windows: w.windows, planks: planks, screen: w.screen)
            let presentPlanks = Set(surfaces.compactMap(\.id.plankID))
            let navPlanks = planks.filter { presentPlanks.contains($0.id) }
            let ladders = placedLadders.compactMap { $0.navLadder(windows: table, surfaces: surfaces) }
            let graph = NavGraph.build(surfaces: surfaces, planks: navPlanks, ladders: ladders, constants: k)

            let start = surfaces[w.startIndex % surfaces.count]
            let me = ResidentLocation(surface: start.id, x: start.start.x + (start.end.x - start.start.x) * w.startFrac)

            // Decor 与其位置。位置由生成参数直接给出（Decor 不参与 Nav_Graph，Attachment 本身不影响选择）。
            var decors: [Decor] = []
            var locations: [DecorID: ResidentLocation] = [:]
            for (i, s) in w.decors.enumerated() {
                let id = DecorID(UInt64(i + 1))
                let sf = surfaces[s.surfaceIndex % surfaces.count]
                let x = sf.start.x + (sf.end.x - sf.start.x) * Double(s.frac) / 4
                let placement: DecorPlacement = s.attached
                    ? .attached(.ground(x: x)) : .dragged(grabOffset: Point(x: 0, y: 0), fresh: false)
                decors.append(Decor(id: id, type: s.isChair ? .chair : .lamp, placement: placement,
                                    placedSeq: UInt64(s.seq)))
                if s.located { locations[id] = ResidentLocation(surface: sf.id, x: x) }
            }
            var seats: [ResidentID: DecorID] = [:]
            if w.wisherSeat < decors.count { seats[.a] = decors[w.wisherSeat].id }
            if w.otherSeat < decors.count { seats[.b] = decors[w.otherSeat].id }
            let store = DecorStore(decors: Dictionary(uniqueKeysWithValues: decors.map { ($0.id, $0) }))

            let type: DecorType = w.wantChair ? .chair : .lamp
            let field = graph.horizontalField(from: me.surface, at: me.x)
            let candidates = Self.referenceCandidates(type, wisher: .a, field: field, decors: decors,
                                                      locations: locations, seats: seats)
            let picked = WishDirector.selectDecorTarget(type, for: .a, from: me, decors: store,
                                                        decorLocations: locations, seats: seats, nav: graph)
            let info = "type \(type) me \(me) seats \(seats) "
                + "decors \(decors.map { "\($0.id.rawValue):\($0.type)/\($0.placedSeq)/\($0.placement) @\(locations[$0.id].map { "\($0)" } ?? "-")" }) "
                + "candidates \(candidates.map { "\($0.id.rawValue):\($0.length)/\($0.seq)" })"

            // 选择：没有可选对象时为 nil，否则为（长度、placedSeq、ID）最小者。
            #expect(picked == candidates.first?.id, "picked \(String(describing: picked?.rawValue)) \(info)")

            // 粘性：经由 advanceDecorWish，已有有效目标时即使存在更近的对象也不更换；没有目标时选出参考结果。
            var world = WorldState(screen: w.screen)
            world.decors = store
            world.residents = [
                .a: Resident(id: .a, attachment: .ground(x: me.x), seat: seats[.a]),
                .b: Resident(id: .b, attachment: .ground(x: 0), seat: seats[.b]),
            ]
            let ctx = WishContext(nav: graph, locations: [.a: me], decorLocations: locations,
                                  now: Date(timeIntervalSince1970: 0), constants: k)
            let wishType: WishType = type == .chair ? .chair : .lamp

            var fresh = Wish(id: WishID(1), type: wishType, wisher: .a, createdAt: ctx.now)
            var freshWorld = world
            WishDirector.advanceDecorWish(&fresh, world: &freshWorld, ctx: ctx)
            #expect(fresh.decorTarget == candidates.first?.id, "fresh target \(info)")

            if let worst = candidates.last {
                var held = Wish(id: WishID(1), type: wishType, wisher: .a, createdAt: ctx.now, decorTarget: worst.id)
                var heldWorld = world
                WishDirector.advanceDecorWish(&held, world: &heldWorld, ctx: ctx)
                let now = String(describing: held.decorTarget?.rawValue)
                #expect(held.decorTarget == worst.id, "held target \(worst.id.rawValue) replaced by \(now) \(info)")
            }
        }
    }
}
