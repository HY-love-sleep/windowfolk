import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// 保存与恢复的属性测试（design.md Property 37 至 40）。

struct PersistenceTests {
    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 2560, height: 1440),
        visibleFrame: Rect(minX: 0, minY: 25, width: 2560, height: 1340)
    )

    /// 编码结果的顶层与剧情字段（Requirement 22.3）。
    static func expectRequiredFields(_ data: Data, _ s: SaveFile) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            Issue.record("not a JSON object")
            return
        }
        #expect(obj["version"] as? Int == SaveCodec.currentVersion)
        #expect((obj["groundObjects"] as? [Any])?.count == s.groundObjects.count)
        #expect((obj["residents"] as? [Any])?.count == s.residents.count)
        guard let story = obj["story"] as? [String: Any] else {
            Issue.record("missing story")
            return
        }
        #expect(Set(story.keys) == ["stage", "round", "doneAt"])
        #expect(story["round"] as? Int == s.story.round)
        if let stage = s.story.stage {
            #expect(story["stage"] as? String == stage.rawValue)
        } else {
            #expect(story["stage"] is NSNull)
        }
        if s.story.doneAt == nil { #expect(story["doneAt"] is NSNull) }
        for r in (obj["residents"] as? [[String: Any]]) ?? [] {
            #expect(Set(r.keys) == ["id", "x", "heldItem"])
        }
    }

    // Feature: v1, Property 37: 存档往返
    // **Validates: Requirements 22.3, 22.9, 22.13**
    @Test func saveFileRoundTrip() async {
        await propertyCheck(count: 100, input: Gen.saveFile) { s in
            guard let data = try? SaveCodec.encode(s) else {
                Issue.record("encode failed")
                return
            }
            Self.expectRequiredFields(data, s)
            #expect((try? SaveCodec.decode(data)) == s)
        }
    }

    // Feature: v1, Property 37: 存档往返（由真实世界生成的存档）
    // **Validates: Requirements 22.3, 22.9, 22.13**
    @Test func engineSaveRoundTrip() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout, Gen<Int>.int(in: 0...240), Gen<UInt64>.value(in: 0...UInt64.max)
        ) { windows, steps, seed in
            var now = Date(timeIntervalSince1970: 1_800_000_000.123_456)
            let engine = WorldEngine(clockStart: now, screen: Self.screen, rng: RandomSource(seed: seed),
                                     demoResident: false, story: true, restored: nil)
            var source = FakeWindowSource(snapshots: windows)
            for _ in 0...steps {
                now = now.addingTimeInterval(1.0 / 30)
                _ = engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: now))
            }
            let save = engine.makeSave(now: now)
            guard let data = try? SaveCodec.encode(save) else {
                Issue.record("encode failed")
                return
            }
            Self.expectRequiredFields(data, save)
            #expect((try? SaveCodec.decode(data)) == save)
        }
    }

    // MARK: - Property 38

    static let frameDT = 1.0 / 30

    /// 窗口最后一次已知（可见或隐藏）快照上的点。窗口已关闭时为 nil。
    static func refPoint(_ wid: WindowID, offset: Double, _ w: WorldState) -> Point? {
        w.windows.records[wid].map { Point(x: $0.snapshot.frame.minX + offset, y: $0.snapshot.frame.minY) }
    }

    /// 已架设木板两端（按 x 从左到右）；任一端窗口已关闭时为 nil。
    static func refPlankEnds(_ p: PlacedPlank, _ w: WorldState) -> (Point, Point)? {
        guard let a = refPoint(p.endA.window, offset: p.endA.offset, w),
              let b = refPoint(p.endB.window, offset: p.endB.offset, w) else { return nil }
        return a.x <= b.x ? (a, b) : (b, a)
    }

    /// Attachment 的参考屏幕 x，按 Requirement 22.4 直接写出；无法独立确定时为 nil（不检查）。
    static func refX(_ a: CoreAttachment, _ w: WorldState) -> Double? {
        switch a {
        case let .window(wid, offset): return refPoint(wid, offset: offset, w)?.x
        case let .ground(x): return x
        case let .plank(pid, t):
            guard let p = w.planks.planks[pid]?.placed, let (l, r) = refPlankEnds(p, w) else { return nil }
            return l.x + (r.x - l.x) * min(max(t, 0), 1)
        case let .free(p): return p.x
        case .ladder: return nil
        }
    }

    static func refItemX(_ item: Item, _ w: WorldState) -> Double? {
        switch item.placement {
        case let .attached(a): return refX(a, w)
        case let .falling(f): return f.position.x
        case .held, .dragged: return nil
        }
    }

    static func refPlankX(_ p: PlankState, _ w: WorldState) -> Double? {
        switch p {
        case let .placed(placed):
            guard let (l, r) = refPlankEnds(placed, w) else { return nil }
            return (l.x + r.x) / 2
        case let .loose(a): return refX(a, w)
        case let .falling(f): return f.position.x
        case .dragged: return nil
        }
    }

    static func refLadderX(_ l: LadderState, _ w: WorldState) -> Double? {
        switch l {
        case let .placed(placed): return refPoint(placed.top.window, offset: placed.top.offset, w)?.x
        case let .loose(a): return refX(a, w)
        case let .falling(f): return f.position.x
        case .dragged: return nil
        }
    }

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 }

    // Feature: v1, Property 38: 保存时归一为地面物件
    // **Validates: Requirements 22.4, 22.8**
    @Test func snapshotNormalizesToGroundObjects() async {
        await propertyCheck(
            count: 100,
            input: Gen.windowLayout,
            Gen<Int>.int(in: 0...9_999).array(of: 40),
            Gen<Int>.int(in: 0...9_999).array(of: 0...4),
            Gen<Int>.int(in: 0...40)
        ) { layout, params, ops, tail in
            let windows = Array(layout.prefix(12))
            let screen = WindowFilterTests.pollScreen
            var source = FakeWindowSource(snapshots: windows)
            var now = Date(timeIntervalSince1970: 3_000_000)
            let engine = WorldEngine(clockStart: now, screen: screen, rng: RandomSource(seed: 11),
                                     demoResident: false)
            WindowFilterTests.buildWorld(engine, windows: windows, params: params)
            func run(_ n: Int, _ src: inout FakeWindowSource, _ e: WorldEngine) {
                for _ in 0 ..< n {
                    now = now.addingTimeInterval(Self.frameDT)
                    e.step(FrameInput(poll: src.poll(), screen: screen, now: now))
                }
            }
            run(90, &source, engine)
            // 隐藏、移动、关闭部分窗口，再推进随机帧数（可能在下落途中保存）。
            for op in ops { WindowFilterTests.mutate(&source, ids: windows.map(\.id), op: op) }
            run(tail, &source, engine)

            let world = engine.state
            let save = engine.makeSave(now: now)
            let objects = save.groundObjects

            // 每个对象只出现一次。
            #expect(Set(objects.map(\.id)).count == objects.count)

            // 被持有的 Item：只记在持有者名下。
            var held: Set<String> = []
            for (rid, r) in world.residents {
                let saved = save.residents.first { $0.id == rid }
                guard let iid = r.heldItem, let item = world.items[iid] else {
                    #expect(saved?.heldItem == nil)
                    continue
                }
                held.insert(iid.rawValue.uuidString)
                #expect(saved?.heldItem?.id == iid.rawValue.uuidString)
                #expect(saved?.heldItem?.kind == (item.kind.isFlower ? .flower : .fruit))
            }
            #expect(held.isDisjoint(with: objects.map(\.id)))

            // 未被持有的 Item：恰好各一个 Ground_Object，x 为当前屏幕 x。
            let itemObjects = objects.filter { $0.kind == .flower || $0.kind == .fruit }
            let unheld = world.items.items.values.filter { !held.contains($0.id.rawValue.uuidString) }
            #expect(Set(itemObjects.map(\.id)) == Set(unheld.map { $0.id.rawValue.uuidString }))
            for item in unheld {
                guard let obj = itemObjects.first(where: { $0.id == item.id.rawValue.uuidString }) else { continue }
                #expect(obj.kind == (item.kind.isFlower ? .flower : .fruit))
                if let x = Self.refItemX(item, world) {
                    #expect(Self.close(obj.x, x), "item \(item.placement): saved \(obj.x), expected \(x)")
                }
            }

            // 全部 Plank、Ladder：数量相同，x 多重集合一致。
            let plankObjects = objects.filter { $0.kind == .plank }.map(\.x).sorted()
            let ladderObjects = objects.filter { $0.kind == .ladder }.map(\.x).sorted()
            #expect(plankObjects.count == world.planks.planks.count)
            #expect(ladderObjects.count == world.ladders.ladders.count)
            let plankRef = world.planks.planks.values.map { Self.refPlankX($0, world) }
            let ladderRef = world.ladders.ladders.values.map { Self.refLadderX($0, world) }
            if plankRef.allSatisfy({ $0 != nil }) {
                let ref = plankRef.compactMap { $0 }.sorted()
                #expect(zip(plankObjects, ref).allSatisfy { Self.close($0, $1) }, "planks \(plankObjects) vs \(ref)")
            }
            if ladderRef.allSatisfy({ $0 != nil }) {
                let ref = ladderRef.compactMap { $0 }.sorted()
                #expect(zip(ladderObjects, ref).allSatisfy { Self.close($0, $1) }, "ladders \(ladderObjects) vs \(ref)")
            }

            // 恢复后：持有的 Item 仍由同一位居民持有，且不作为 Ground_Object 出现（Requirement 22.8）。
            var source2 = FakeWindowSource(snapshots: windows)
            let restored = WorldEngine(clockStart: now, screen: screen, rng: RandomSource(seed: 12),
                                       demoResident: false, story: false, restored: save)
            run(90, &source2, restored)
            for s in save.residents {
                guard let h = s.heldItem else { continue }
                let r = restored.state.residents[s.id]
                #expect(r?.heldItem?.rawValue.uuidString == h.id)
                if let iid = r?.heldItem {
                    #expect(restored.state.items[iid]?.placement == .held(s.id))
                }
            }
            let restoredGroundItems = restored.state.items.items.values
                .filter { $0.placement.holder == nil }.map { $0.id.rawValue.uuidString }
            #expect(Set(restoredGroundItems) == Set(itemObjects.map(\.id)))
        }
    }

    // MARK: - Property 40

    /// 损坏存档的四类来源：随机字节、截断的合法编码、版本号被改的合法编码、结构不对的合法 JSON。
    static var corruptSave: Generator<Data, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...3),
            Gen<Int>.int(in: 0...255).array(of: 0...200),
            Gen.saveFile,
            Gen<Double>.double(in: 0..<1),
            Gen<Int>.int(in: -1000...1000),
            Gen<Int>.int(in: 0...9)
        ).map { kind, bytes, file, cut, version, shape -> Data in
            switch kind {
            case 0:
                return Data(bytes.map { UInt8($0) })
            case 1:
                let full = (try? SaveCodec.encode(file)) ?? Data()
                return full.prefix(Int(Double(full.count) * cut))
            case 2:
                var f = file
                f.version = version == SaveCodec.currentVersion ? version + 1 : version
                return (try? SaveCodec.encode(f)) ?? Data()
            default:
                let shapes = [
                    "null", "[]", "[1,2,3]", "\"world\"", "42", "{}",
                    #"{"version":1}"#,
                    #"{"version":"1","savedAt":0,"story":{"stage":null,"round":1,"doneAt":null},"residents":[],"groundObjects":[]}"#,
                    #"{"version":1,"savedAt":0,"story":5,"residents":[],"groundObjects":[]}"#,
                    #"{"version":1,"savedAt":"yesterday","story":{"stage":"bogus","round":1,"doneAt":null},"residents":{},"groundObjects":[]}"#,
                ]
                return Data(shapes[shape].utf8)
            }
        }
    }

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-p40-\(UUID().uuidString)", isDirectory: true)
    }

    /// 两个合格窗口，用于确认损坏回退后按首次开局处理。
    static let freshWindows = [
        WindowSnapshot(id: 1, ownerName: "A", ownerPID: 100,
                       frame: Rect(minX: 100, minY: 300, width: 500, height: 400), zIndex: 0),
        WindowSnapshot(id: 2, ownerName: "B", ownerPID: 101,
                       frame: Rect(minX: 1600, minY: 300, width: 500, height: 400), zIndex: 1),
    ]

    // Feature: v1, Property 40: 损坏存档回退
    // **Validates: Requirements 22.12**
    @Test func corruptSaveFallsBack() async {
        await propertyCheck(count: 100, input: Self.corruptSave, Gen<Int>.int(in: 0...2_000_000_000)) { data, t in
            #expect((try? SaveCodec.decode(data)) == nil, "generated data unexpectedly decodes")

            let fm = FileManager.default
            let dir = Self.tempDir()
            defer { try? fm.removeItem(at: dir) }
            #expect(dir.path.hasPrefix(fm.temporaryDirectory.path))
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent(FileSaveStore.defaultFileName))
            } catch {
                Issue.record("setup failed: \(error)"); return
            }
            let store = FileSaveStore(directory: dir)
            let now = Date(timeIntervalSince1970: Double(t))

            guard case let .corrupt(backup?) = store.loadSave(now: now) else {
                Issue.record("expected .corrupt with backup"); return
            }
            // 原文件已被重命名：备份内容不变，文件名带时间戳。
            #expect(!fm.fileExists(atPath: store.fileURL.path))
            #expect(backup.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
            #expect(backup.lastPathComponent == "world.corrupt-\(FileSaveStore.timestamp(now)).json")
            #expect((try? Data(contentsOf: backup)) == data)
            // 再次读取按首次开局处理。
            #expect(store.loadSave(now: now) == .missing)

            // 以无存档方式开局：Story_Round 为 1，没有 Ground_Object。
            var source = FakeWindowSource(snapshots: Self.freshWindows)
            var clock = now
            let engine = WorldEngine(clockStart: clock, screen: Self.screen, rng: RandomSource(seed: 7),
                                     demoResident: false, story: true, restored: nil)
            for _ in 0..<10 {
                clock = clock.addingTimeInterval(Self.frameDT)
                engine.step(FrameInput(poll: source.poll(), screen: Self.screen, now: clock))
            }
            #expect(engine.state.story.round == 1)
            #expect(engine.state.story.stage != nil)
            let save = engine.makeSave(now: clock)
            #expect(save.story.round == 1)
            #expect(save.groundObjects.isEmpty)

            // 之后的保存写出新的 world.json，备份保持不变。
            #expect(store.save(save))
            #expect(store.loadSave(now: clock) == .loaded(save))
            #expect((try? Data(contentsOf: backup)) == data)
        }
    }
}

// MARK: - 任务 16.8：存档单元测试

/// 经由真实文件（临时目录）完成「保存 → 读取 → 恢复」的具体场景。
/// 与 PersistenceUnitTests（直接传 SaveFile）和 FileSaveStoreUnitTests（只测文件层）互补。
struct PersistenceExampleTests {
    static let screen = PersistenceUnitTests.screen
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let windows = [PersistenceUnitTests.win(1, x: 100, y: 400), PersistenceUnitTests.win(2, x: 400, y: 400)]

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-16-8-\(UUID().uuidString)", isDirectory: true)
    }

    /// 写入临时目录再读回，返回读到的存档。
    static func throughFile(_ save: SaveFile, dir: URL) throws -> SaveFile {
        let store = FileSaveStore(directory: dir)
        #expect(store.save(save))
        guard case let .loaded(loaded) = store.loadSave(now: t0) else {
            Issue.record("expected .loaded")
            throw CancellationError()
        }
        #expect(loaded == save)
        return loaded
    }

    static func engine(restored: SaveFile?, now: Date) -> (WorldEngine, FakeWindowSource) {
        (WorldEngine(clockStart: now, screen: screen, rng: RandomSource(seed: 3),
                     demoResident: false, story: true, restored: restored),
         FakeWindowSource(snapshots: windows))
    }

    static func step(_ e: WorldEngine, _ src: inout FakeWindowSource, _ now: inout Date, by dt: Double, _ n: Int) {
        for _ in 0..<n {
            now = now.addingTimeInterval(dt)
            e.step(FrameInput(poll: src.poll(), screen: screen, now: now))
        }
    }

    /// Done 恢复：倒计时未过时保持 Done，到达 doneAt + Round_Interval 后 1 秒内开始下一轮（Requirement 19.7、22.10）。
    @Test func doneRestoreCountdownNotYetElapsed() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = Tunables()
        let doneAt = Self.t0.addingTimeInterval(-(c.roundInterval - 20))
        let save = SaveFile(
            savedAt: Self.t0.addingTimeInterval(-30),
            story: SavedStory(stage: .done, round: 3, doneAt: doneAt),
            residents: [SavedResident(id: .a, x: 150), SavedResident(id: .b, x: 450)],
            groundObjects: [])
        let loaded = try Self.throughFile(save, dir: dir)

        var now = Self.t0
        let (e, src0) = Self.engine(restored: loaded, now: now)
        var src = src0
        Self.step(e, &src, &now, by: 0.25, 1)
        #expect(e.state.story.stage == .done)
        #expect(e.state.story.round == 3)
        #expect(e.state.story.doneAt == doneAt)

        // 推进到倒计时结束前：仍为 Done。
        Self.step(e, &src, &now, by: 0.25, 4 * 19)
        #expect(e.state.story.stage == .done)
        #expect(e.state.story.round == 3)

        // 越过 doneAt + Round_Interval，1 秒内开始第 4 轮，Giver 为嘟嘟。
        Self.step(e, &src, &now, by: 0.25, 4 * 2)
        #expect(e.state.story.round == 4)
        #expect(e.state.story.giver == .b)
        #expect(e.state.story.stage.map { [.wish, .waiting, .travel].contains($0) } == true)
        #expect(e.state.residents[.b]?.heldItem.flatMap { e.state.items[$0]?.kind.isFlower } == true)
    }

    /// Done 恢复：倒计时在应用未运行期间已过，恢复后 1 秒内开始下一轮（Requirement 19.7）。
    @Test func doneRestoreCountdownElapsedWhileClosed() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = Tunables()
        let save = SaveFile(
            savedAt: Self.t0.addingTimeInterval(-3600),
            story: SavedStory(stage: .done, round: 2, doneAt: Self.t0.addingTimeInterval(-c.roundInterval * 5)),
            residents: [SavedResident(id: .a, x: 150), SavedResident(id: .b, x: 450)],
            groundObjects: [])
        let loaded = try Self.throughFile(save, dir: dir)

        var now = Self.t0
        let (e, src0) = Self.engine(restored: loaded, now: now)
        var src = src0
        Self.step(e, &src, &now, by: 1.0 / 30, 30)
        #expect(e.state.story.round == 3)
        #expect(e.state.story.giver == .a)
        #expect(e.state.story.stage != .done)
    }

    /// `planting` 中保存：存为 `travel`，恢复后花在 Giver 手上且没有种下时间（Requirement 22.9、design.md）。
    @Test func plantingSavedAsTravelWithFlowerInGiversHands() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 第 2 轮：Giver 为嘟嘟，正在和都都一起种花。
        var world = WorldState(screen: Self.screen)
        var a = Resident(id: .a, attachment: .ground(x: 300))
        a.state = .planting
        var b = Resident(id: .b, attachment: .ground(x: 320))
        b.state = .planting
        let pot = Item.flowerPot(storyRound: 2, placement: .held(.b))
        #expect(world.items.give(pot, to: &b))
        world.residents[.a] = a
        world.residents[.b] = b
        world.story = StoryState(stage: .planting, round: 2, currentFlower: pot.id, plantingElapsed: 1.2)

        let save = SaveSnapshot.snapshot(world: world, now: Self.t0)
        #expect(save.story.stage == .travel)
        #expect(save.groundObjects.isEmpty)
        #expect(save.residents.first { $0.id == .b }?.heldItem?.id == pot.id.rawValue.uuidString)
        #expect(save.residents.first { $0.id == .a }?.heldItem == nil)
        let loaded = try Self.throughFile(save, dir: dir)

        var now = Self.t0
        let (e, src0) = Self.engine(restored: loaded, now: now)
        var src = src0
        Self.step(e, &src, &now, by: 1.0 / 30, 1)
        let st = e.state
        #expect(st.story.round == 2)
        #expect(st.story.stage == .travel || st.story.stage == .waiting)
        #expect(st.story.plantingElapsed == 0)
        #expect(st.story.currentFlower == pot.id)
        #expect(st.residents[.b]?.heldItem == pot.id)
        let flower = try #require(st.items[pot.id])
        #expect(flower.placement == .held(.b))
        #expect(flower.growth?.plantedAt == nil)
        #expect(flower.growth?.reached == .pot)
        #expect(st.items.items.values.filter { $0.kind.isFlower }.count == 1)
        #expect(st.residents.values.allSatisfy { $0.state != .planting })
    }

    /// Growing 恢复：应用未运行期间花从 pot 长到 sprout，剧情保持 Growing（Requirement 22.10）。
    @Test func growingRestoreRecomputesStageFromPlantedAt() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = Tunables()
        let flowerID = UUID()
        let planted = Self.t0.addingTimeInterval(-(c.bloomDuration * 0.75))
        let save = SaveFile(
            savedAt: Self.t0.addingTimeInterval(-(c.bloomDuration * 0.7)),
            story: SavedStory(stage: .growing, round: 1, doneAt: nil),
            residents: [SavedResident(id: .a, x: 150), SavedResident(id: .b, x: 450)],
            groundObjects: [SavedObject(id: flowerID.uuidString, kind: .flower, x: 460,
                                        flower: SavedFlower(storyRound: 1, plantedAt: planted, reached: .pot))])
        let loaded = try Self.throughFile(save, dir: dir)

        var now = Self.t0
        let (e, src0) = Self.engine(restored: loaded, now: now)
        var src = src0
        Self.step(e, &src, &now, by: 1.0 / 30, 1)
        #expect(e.state.story.stage == .growing)
        #expect(e.state.story.currentFlower == ItemID(flowerID))
        #expect(e.state.items[ItemID(flowerID)]?.growth?.reached == .sprout)
        #expect(e.state.items[ItemID(flowerID)]?.growth?.plantedAt == planted)
    }

    /// 不存在 world.json：按首次开局，Story_Round 为 1，Ground 上没有 Ground_Object（Requirement 22.11）。
    @Test func missingWorldJSONStartsFirstLaunch() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSaveStore(directory: dir)
        #expect(store.loadSave(now: Self.t0) == .missing)

        var now = Self.t0
        let (e, src0) = Self.engine(restored: nil, now: now)
        var src = src0
        Self.step(e, &src, &now, by: 1.0 / 30, 3)
        #expect(e.state.story.round == 1)
        #expect(e.state.story.stage != nil)
        #expect(e.state.story.homes == [.a: 1, .b: 2])
        #expect(e.state.planks.planks.isEmpty && e.state.ladders.ladders.isEmpty)
        #expect(e.state.items.items.values.allSatisfy { $0.placement.holder != nil })
        #expect(e.makeSave(now: now).groundObjects.isEmpty)
    }

    /// 写入失败时原文件不变，下一次保存（下一个 Autosave_Interval）重试成功（Requirement 22.5）。
    @Test func failedAutosaveKeepsOriginalAndRetrySucceeds() throws {
        let fm = FileManager.default
        let dir = Self.tempDir()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }
        var now = Self.t0
        let (e, src0) = Self.engine(restored: nil, now: now)
        var src = src0
        Self.step(e, &src, &now, by: 1.0 / 30, 3)
        let store = FileSaveStore(directory: dir)
        let first = e.makeSave(now: now)
        #expect(store.save(first))
        let before = try Data(contentsOf: store.fileURL)

        Self.step(e, &src, &now, by: 0.25, 4 * 30)
        let second = e.makeSave(now: now)
        #expect(second != first)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(!store.save(second))
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(store.loadSave(now: now) == .loaded(first))

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(store.save(second))
        #expect(store.loadSave(now: now) == .loaded(second))
    }
}
