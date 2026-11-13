import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// 格式版本 2 存档的属性测试（V2 design.md Property 2、48）。

/// `unlockedDecor` 里的单个字符串：合法值、大小写或空白变体、已知的未知值、任意 ASCII 字母数字串。
fileprivate var decorString: Generator<String, some SendableSequenceType> { zip(
    Gen<Int>.int(in: 0...3),
    Gen<String?>.element(of: ["chair", "lamp"]).map { $0! },
    Gen<String?>.element(of: ["Chair", "LAMP", "Lamp", " chair", "lamp ", "", "sofa", "chase", "flower"])
        .map { $0! },
    Gen.letterOrNumber.string(of: 0...8)
).map { pick, legal, variant, random -> String in
    switch pick {
    case 0, 1: legal
    case 2: variant
    default: random
    }
} }

/// 一份合法存档，加上用来替换其 `unlockedDecor` 的任意字符串数组（含重复项）。
fileprivate var saveWithDecorStrings: Generator<(SaveFile, [String]), some SendableSequenceType> {
    zip(Gen<SaveFile>.saveFile, decorString.array(of: 0...10))
}

/// 把编码后的存档中 `wishBook.unlockedDecor` 换成给定字符串数组。
fileprivate func replacingUnlockedDecor(in data: Data, with strings: [String]) throws -> Data {
    var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var book = try #require(obj["wishBook"] as? [String: Any])
    book["unlockedDecor"] = strings
    obj["wishBook"] = book
    return try JSONSerialization.data(withJSONObject: obj)
}

/// 把 v2 编码改写成 v1 格式（版本号 1，无 `wishBook`、居民无 v2 字段、无 chair / lamp）。
fileprivate func v1Encoding(of s: SaveFile) -> Data {
    guard let data = try? SaveCodec.encode(s),
          var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Data() }
    obj["version"] = 1
    obj["wishBook"] = nil
    obj["residents"] = ((obj["residents"] as? [[String: Any]]) ?? []).map { r in
        var r = r
        r["walkDistance"] = nil
        r["lastWishEndedAt"] = nil
        return r
    }
    obj["groundObjects"] = ((obj["groundObjects"] as? [[String: Any]]) ?? []).filter {
        !["chair", "lamp"].contains($0["kind"] as? String ?? "")
    }
    return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
}

/// 非 v2 存档的四类来源：v1 格式的存档、版本号被改的 v2 格式存档、随机字节、截断的 v2 编码。
/// 返回 (数据, 是否为版本号不符的合法 JSON)。
fileprivate var nonV2Save: Generator<(Data, Bool), some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...3),
        Gen<SaveFile>.saveFile,
        Gen<Int>.int(in: -1000...1000),
        Gen<Int>.int(in: 0...255).array(of: 0...200),
        Gen<Double>.double(in: 0..<1)
    ).map { kind, file, version, bytes, cut -> (Data, Bool) in
        switch kind {
        case 0:
            return (v1Encoding(of: file), true)
        case 1:
            var f = file
            // 保留 chair、lamp 和 Unlocked_Decor，确认回退后不会沿用它们。
            f.wishBook.unlockedDecor = DecorType.allCases
            f.version = version == SaveCodec.currentVersion ? version + 1 : version
            return ((try? SaveCodec.encode(f)) ?? Data(), true)
        case 2:
            return (Data(bytes.map { UInt8($0) }), false)
        default:
            let full = (try? SaveCodec.encode(file)) ?? Data()
            return (full.prefix(Int(Double(full.count) * cut)), false)
        }
    }
}

struct SaveFileV2Tests {
    // Feature: V2, Property 48: 非 v2 存档回退
    // **Validates: Requirements 15.5**
    @Test func nonV2SaveFallsBack() async {
        #expect(SaveCodec.currentVersion == 2)
        await propertyCheck(count: 100, input: nonV2Save, Gen<Int>.int(in: 0...2_000_000_000)) { input, t in
            let (data, versionOnly) = input
            do {
                _ = try SaveCodec.decode(data)
                Issue.record("generated data unexpectedly decodes"); return
            } catch let SaveCodecError.versionMismatch(found) {
                #expect(versionOnly, "random or truncated data reported as version mismatch")
                #expect(found != 2)
            } catch {
                #expect(!versionOnly, "version-mismatched save not reported as .versionMismatch: \(error)")
            }

            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("windowfolk-p48-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: dir) }
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
            // 原文件重命名为带时间戳的备份，内容不变（v1 R22.12）。
            #expect(!fm.fileExists(atPath: store.fileURL.path))
            #expect(backup.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
            #expect(backup.lastPathComponent == "world.corrupt-\(FileSaveStore.timestamp(now)).json")
            #expect((try? Data(contentsOf: backup)) == data)
            #expect(store.loadSave(now: now) == .missing)

            // 新开局：Unlocked_Decor 为空，Ground 上没有 Decor。
            let screen = PersistenceTests.screen
            var source = FakeWindowSource(snapshots: PersistenceTests.freshWindows)
            var clock = now
            let engine = WorldEngine(clockStart: clock, screen: screen, rng: RandomSource(seed: 7),
                                     demoResident: false, story: true, restored: nil)
            for _ in 0..<10 {
                clock = clock.addingTimeInterval(PersistenceTests.frameDT)
                engine.step(FrameInput(poll: source.poll(), screen: screen, now: clock))
            }
            #expect(engine.state.decors.unlocked.isEmpty)
            #expect(engine.state.decors.decors.isEmpty)
            let save = engine.makeSave(now: clock)
            #expect(save.wishBook.unlockedDecor.isEmpty)
            #expect(!save.groundObjects.contains { $0.kind == .chair || $0.kind == .lamp })
            #expect(save.groundObjects.isEmpty)
            #expect(save.story.round == 1)

            // 之后的保存写出新的 world.json，备份保持不变。
            #expect(store.save(save))
            #expect(store.loadSave(now: clock) == .loaded(save))
            #expect((try? Data(contentsOf: backup)) == data)
        }
    }

    // Feature: V2, Property 2: Unlocked_Decor 解码容错
    // **Validates: Requirements 1.9**
    @Test func unlockedDecorDecodingIsLossy() async {
        await propertyCheck(count: 100, input: saveWithDecorStrings) { s, strings in
            do {
                let encoded = try SaveCodec.encode(s)
                let legal = strings.compactMap(DecorType.init(rawValue:))
                let expectedDecor = Set(legal).sorted()

                let decoded = try SaveCodec.decode(replacingUnlockedDecor(in: encoded, with: strings))
                #expect(decoded.wishBook.unlockedDecor == expectedDecor)

                // 其余字段与只含合法值时的解码结果相同，也与原存档相同。
                let clean = try SaveCodec.decode(
                    replacingUnlockedDecor(in: encoded, with: legal.map(\.rawValue)))
                #expect(decoded == clean)
                var expected = s
                expected.wishBook.unlockedDecor = expectedDecor
                #expect(decoded == expected)
            } catch {
                Issue.record("unexpected error: \(error) for \(strings)")
            }
        }
    }
}
