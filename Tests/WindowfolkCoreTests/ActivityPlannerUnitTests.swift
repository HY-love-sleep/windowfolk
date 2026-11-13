import Foundation
import Testing
@testable import WindowfolkCore

@Suite("ActivityPlanner 可执行判定与选择单元测试")
struct ActivityPlannerUnitTests {
    let k = Tunables()
    let now = Date(timeIntervalSince1970: 1_000_000)

    func h(_ id: SurfaceID, _ x0: Double, _ x1: Double, _ y: Double) -> Surface {
        Surface(id: id, start: Point(x: x0, y: y), end: Point(x: x1, y: y))
    }

    /// Ground [0, 1000]（y = 880）；窗口 1 的窗沿 [90, 110]（y = 770），可往下跳，x = 100 处有梯子上去；
    /// 窗口 2 的窗沿 [500, 600]（y = 200），与其他 Surface 不连通。
    func nav() -> NavGraph {
        let ledge = h(.ledge(1, index: 0), 90, 110, 770)
        let island = h(.ledge(2, index: 0), 500, 600, 200)
        let ground = h(.ground, 0, 1000, 880)
        let ladder = NavLadder(id: LadderID(1), bottomSurface: .ground, bottom: Point(x: 100, y: 880),
                               topSurface: ledge.id, top: Point(x: 100, y: 770))
        return NavGraph.build(surfaces: [ledge, island, ground], ladders: [ladder], constants: k)
    }

    func decor(_ id: UInt64, _ t: DecorType, x: Double?) -> Decor {
        Decor(id: DecorID(id), type: t,
              placement: x.map { .attached(.ground(x: $0)) } ?? .dragged(grabOffset: Point(x: 0, y: 0), fresh: false))
    }

    /// a 在 Ground x = 500，b 在窗口 1 的窗沿上。
    func world(isNight: Bool = false) -> ActivityContext {
        let ds: [Decor] = [
            decor(1, .chair, x: 300), decor(2, .chair, x: 600), decor(3, .chair, x: 520),
            decor(4, .lamp, x: 900), decor(5, .lamp, x: 400), decor(6, .lamp, x: nil),
        ]
        var decorLocations: [DecorID: ResidentLocation] = [:]
        for d in ds {
            if case let .attached(.ground(x)) = d.placement {
                decorLocations[d.id] = ResidentLocation(surface: .ground, x: x)
            }
        }
        let flower = Item(id: ItemID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
                          kind: .flower(storyRound: 1), placement: .attached(.ground(x: 700)),
                          growth: FlowerGrowth(plantedAt: now, reached: .bloom))
        let sprout = Item(id: ItemID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
                          kind: .flower(storyRound: 2), placement: .attached(.ground(x: 510)),
                          growth: FlowerGrowth(plantedAt: now, reached: .sprout))
        return ActivityContext(
            nav: nav(),
            locations: [.a: ResidentLocation(surface: .ground, x: 500),
                        .b: ResidentLocation(surface: .ledge(1, index: 0), x: 100)],
            decors: DecorStore(decors: Dictionary(uniqueKeysWithValues: ds.map { ($0.id, $0) })),
            seats: [.b: DecorID(3)],
            items: ItemStore(items: [flower.id: flower, sprout.id: sprout]),
            homes: [.a: 1, .b: 1],
            isNight: isNight, now: now, constants: k,
            decorLocations: decorLocations,
            itemLocations: [flower.id: ResidentLocation(surface: .ground, x: 700),
                            sprout.id: ResidentLocation(surface: .ground, x: 510)])
    }

    @Test("白天：按条件判定，rest 取最近的空闲 Chair，admire_flower 只看 bloom，没有 sleep")
    func executableByDay() {
        let ctx = world()
        let exec = ActivityPlanner.executable(.a, ctx: ctx)
        #expect(exec[.wander] == ActivityTarget.none)
        #expect(exec[.goHome] == .home(1))
        #expect(exec[.visitNeighbor] == .resident(.b))
        #expect(exec[.rest] == .chair(DecorID(2)))   // 3 号被 b 占用；2 号距 100，1 号距 200
        #expect(exec[.admireFlower] == .flower(ctx.items.sortedIDs[0]))
        #expect(exec[.sleep] == nil)
    }

    @Test("夜晚：sleep 目标为路线最短的已放置 Lamp，拖动中的 Lamp 不算")
    func executableAtNight() {
        let exec = ActivityPlanner.executable(.a, ctx: world(isNight: true))
        #expect(exec[.sleep] == .lamp(DecorID(5)))
    }

    @Test("站在 Home_Window 上、Home 不可达、对方不可定位或无位置时的判定")
    func notExecutable() {
        var ctx = world()
        // b 已在家：没有 go_home。
        #expect(ActivityPlanner.executable(.b, ctx: ctx)[.goHome] == nil)
        // Home 为不连通的窗口 2：没有 go_home。
        ctx.homes[.a] = 2
        #expect(ActivityPlanner.executable(.a, ctx: ctx)[.goHome] == nil)
        // b 下落中（不在 locations）：没有 visit_neighbor。
        ctx.locations[.b] = nil
        #expect(ActivityPlanner.executable(.a, ctx: ctx)[.visitNeighbor] == nil)
        // 自己无法定位：只有 wander。
        ctx.locations[.a] = nil
        ctx.isNight = true
        #expect(ActivityPlanner.executable(.a, ctx: ctx) == [.wander: ActivityTarget.none])
    }

    @Test("Night 且 sleep 可执行时直接选 sleep，不消耗随机数")
    func nightPicksSleep() {
        var rng = RandomSource(seed: 7)
        let before = rng
        let a = ActivityPlanner.choose(.a, ctx: world(isNight: true), rng: &rng)
        #expect(a == Activity(kind: .sleep, target: .lamp(DecorID(5)), startedAt: now))
        #expect(rng == before)
    }

    @Test("选择属于可执行集合、确定，wander 时长在区间内")
    func chooseIsDeterministicAndValid() {
        var ctx = world()
        ctx.isNight = true
        ctx.decors.decors[DecorID(4)] = nil
        ctx.decors.decors[DecorID(5)] = nil   // Night 但没有 Lamp：按权重在其余中选
        var seen: Set<ActivityKind> = []
        for seed in UInt64(0)..<200 {
            var r1 = RandomSource(seed: seed), r2 = RandomSource(seed: seed)
            let a1 = ActivityPlanner.choose(.a, ctx: ctx, rng: &r1)
            let a2 = ActivityPlanner.choose(.a, ctx: ctx, rng: &r2)
            #expect(a1 == a2)
            let exec = ActivityPlanner.executable(.a, ctx: ctx)
            #expect(exec[a1.kind] == a1.target)
            #expect(a1.startedAt == now && a1.phase == .moving)
            if a1.kind == .wander {
                let d = a1.wanderDuration ?? -1
                #expect(d >= k.activityMinDuration && d <= k.activityMaxDuration)
                #expect(a1.surface == .ground)
            } else {
                #expect(a1.wanderUntil == nil)
            }
            seen.insert(a1.kind)
        }
        #expect(seen == [.wander, .goHome, .visitNeighbor, .rest, .admireFlower])
    }

    @Test("location(of:world:) 把 Attachment 换算为 Surface 和 x")
    func locateAttachment() {
        let ground = h(.ground, 0, 1000, 880)
        let world = WorldContext(windows: WindowTable(), surfaces: [ground],
                                 screen: ScreenInfo(frame: Rect(minX: 0, minY: 0, width: 1000, height: 900),
                                                    visibleFrame: Rect(minX: 0, minY: 0, width: 1000, height: 880)),
                                 constants: k)
        #expect(ActivityContext.location(of: .ground(x: 42), world: world)
                == ResidentLocation(surface: .ground, x: 42))
        #expect(ActivityContext.location(of: .window(1, offset: 5), world: world) == nil)
        #expect(ActivityContext.location(of: .free(Point(x: 1, y: 1)), world: world) == nil)
    }
}
