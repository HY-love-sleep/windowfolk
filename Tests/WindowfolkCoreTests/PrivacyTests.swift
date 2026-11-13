import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// MARK: - 生成器

/// API Key 中容易出错的字符：引号、反斜杠、斜杠、换行、控制字符、U+2028、中文、组合字符、emoji。
fileprivate let pvTrickyCharacters: [Character] = [
    "\"", "\\", "/", "\n", "\t", "\u{0}", "\u{1F}", "\u{2028}", "=", "+", ":", "{", "}", " ",
    "都", "嘟", "钥", "é", "e\u{301}", "🐹", "🔑", "👨\u{200D}👩\u{200D}👧",
]

fileprivate var pvKeyCharacter: Generator<Character, some SendableSequenceType> {
    zip(
        Gen<Bool>.bool,
        Gen<Character?>.element(of: pvTrickyCharacters).map { $0! },
        Gen<UInt32>.value(in: 0x21...0x7E)
    ).map { useTricky, tricky, raw -> Character in
        useTricky ? tricky : Character(UnicodeScalar(raw)!)
    }
}

/// API Key：6 个大写 ASCII 字母的随机前缀 + 任意中段（可很长）+ 2 个可见 ASCII 结尾，共 8 至 508 个字符。
///
/// 首尾不是空白，因此 `LLMSettingsValidation.config` 去空白后 Key 不变；总长不超过 API Key 上限 512。
/// 前缀是泄漏标记：无论 Key 以原样还是 JSON 转义形式泄漏，前缀都原样出现。其余数据中的
/// 应用名称、模型名、地址都是小写或中文，枚举取值是小写，不会巧合出现连续 6 个大写字母。
fileprivate var pvAPIKey: Generator<String, some SendableSequenceType> {
    zip(
        Gen<Character>.character(in: "A"..."Z").string(of: 6),
        zip(Gen<Bool>.bool(0.2), pvKeyCharacter.string(of: 0...24), pvKeyCharacter.string(of: 200...500))
            .map { long, short, longText in long ? longText : short },
        Gen<UInt32>.value(in: 0x21...0x7E).map { Character(UnicodeScalar($0)!) }.string(of: 2)
    ).map { prefix, middle, suffix in prefix + middle + suffix }
}

/// 一个世界：窗口布局、调试命令、关窗时机、时间与时区、LLM 返回文本。
fileprivate struct PrivacyCase: Sendable {
    var apiKey: String
    var endpoint: String
    var model: String
    var ownerNames: [String]
    var windowXs: [Int]
    var windowYs: [Int]
    var seed: UInt64
    var wish: WishType
    var wisher: ResidentID?
    var dayNight: DayNightOverride
    var closeFrame: Int
    var startSeconds: Int
    var timeZoneID: String
    var diaryLLMSucceeds: Bool
    var thoughtText: String
    var diaryText: String
}

fileprivate func pvPick(_ values: [String]) -> Generator<String, some SendableSequenceType> {
    Gen<String?>.element(of: values).map { $0! }
}

/// 小写字母、数字和中文组成的普通文本（应用名称、LLM 返回文本）。
fileprivate var pvPlainText: Generator<String, some SendableSequenceType> {
    Gen<Character?>.element(of: Array("abcdefghijklmnopqrstuvwxyz0123456789 备忘录窗口今天天气好🌸")).map { $0! }
        .string(of: 1...12)
}

fileprivate var privacyCase: Generator<PrivacyCase, some SendableSequenceType> {
    zip(
        pvAPIKey,
        pvPick(["https://api.example.com/v1/chat/completions", "http://localhost:8080/v1", "https://llm.test/x?y=1"]),
        pvPick(["gpt-4o-mini", "qwen-turbo", "本地模型"]),
        pvPlainText.array(of: 1...3),
        Gen<Int>.int(in: 0...100).array(of: 3),
        Gen<Int>.int(in: 0...60).array(of: 3),
        Gen<UInt64>.uint64(),
        zip(Gen<WishType>.case, Gen<Int>.int(in: 0...2).map { i -> ResidentID? in [ResidentID.a, .b, nil][i] },
            Gen<DayNightOverride>.case),
        zip(
            Gen<Int>.int(in: 5...80),
            Gen<Int>.int(in: 1_600_000_000...1_900_000_000),
            pvPick(["UTC", "Asia/Shanghai", "America/Los_Angeles", "Asia/Kathmandu"]),
            Gen<Bool>.bool,
            pvPlainText,
            pvPlainText)
    ).map { key, endpoint, model, names, xs, ys, seed, cmd, rest in
        PrivacyCase(
            apiKey: key, endpoint: endpoint, model: model, ownerNames: names, windowXs: xs, windowYs: ys,
            seed: seed, wish: cmd.0, wisher: cmd.1, dayNight: cmd.2, closeFrame: rest.0,
            startSeconds: rest.1, timeZoneID: rest.2, diaryLLMSucceeds: rest.3,
            thoughtText: rest.4, diaryText: rest.5)
    }
}

// MARK: - 断言工具

/// Key 的 JSON 字符串转义形式（不含两侧引号），用于检查 Key 是否以转义后的样子出现在 JSON 中。
fileprivate func pvJSONEscaped(_ key: String) -> String {
    let data = try! JSONEncoder().encode([key])
    let s = String(decoding: data, as: UTF8.self)
    return String(s.dropFirst(2).dropLast(2))
}

/// 一段文本中是否出现 Key、Key 的 JSON 转义形式或 Key 的 6 字母前缀。
fileprivate func pvLeaks(_ text: String, key: String) -> Bool {
    text.contains(key) || text.contains(pvJSONEscaped(key)) || text.contains(String(key.prefix(6)))
}

fileprivate func pvLeaks(_ data: Data, key: String) -> Bool {
    if pvLeaks(String(decoding: data, as: UTF8.self), key: key) { return true }
    // 原样字节匹配，不依赖 UTF-8 解码。
    return data.range(of: Data(key.utf8)) != nil || data.range(of: Data(key.prefix(6).utf8)) != nil
}

// MARK: - 属性

@MainActor
@Suite struct PrivacyTests {
    static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))
    static let dt = 1.0 / 30
    static let frames = 120

    // Feature: V2, Property 31: API Key 不出现在文件和 Payload 中
    /// **Validates: Requirements 11.3, 12.7, 15.7**
    ///
    /// 经 `LLMSettingsModel` 保存设置与 Key 后，跑完整 V2 世界若干帧（Thought 请求按 LLM 返回文本回填），
    /// 再写 world.json、events.jsonl、diary.jsonl。临时目录中的全部文件、每条事件行、每篇日记行、
    /// 全部 Payload 的 `messages()` 与请求体、`LLMRequestConfig` 的各种文本表示都不含 Key；
    /// `ChatCompletions.makeRequest` 只在 Authorization 头中带 Key。
    @Test func apiKeyNeverLeavesSecretStoreAndAuthorizationHeader() async throws {
        await propertyCheck(count: 100, input: privacyCase) { c in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("windowfolk-privacy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let key = c.apiKey
            let tz = TimeZone(identifier: c.timeZoneID)!

            // 1. 设置：经 LLMSettingsModel 填写、确认说明、打开两个开关并立即保存。
            let secrets = InMemorySecretStore()
            let settingsStore = FileLLMSettingsStore(directory: dir)
            let model = LLMSettingsModel(store: settingsStore, secrets: secrets, saveDelay: .seconds(3600))
            model.setEndpoint(c.endpoint)
            model.setModel(c.model)
            model.setAPIKey(key)
            for t in LLMToggle.allCases {
                model.requestToggle(t, on: true)
                model.confirmDisclosure()
            }
            model.flush()
            #expect(secrets.storedAPIKey == key)
            let config = try #require(model.diaryConfig)
            #expect(config.apiKey == key)
            #expect(model.thoughtsConfig != nil)

            let settingsData = try Data(contentsOf: settingsStore.fileURL)
            #expect(!pvLeaks(settingsData, key: key), "settings.json 含 Key")

            // 2. LLMRequestConfig 的文本表示。
            var dumped = ""
            dump(config, to: &dumped)
            for text in [config.description, config.debugDescription, String(describing: config),
                         String(reflecting: config), "\(config)", dumped] {
                #expect(!pvLeaks(text, key: key), "LLMRequestConfig 文本表示含 Key")
            }

            // 3. 世界：完整 V2（剧情、自主活动），解锁物件、触发心愿、设置昼夜，途中关掉一个窗口让居民掉落。
            var windows: [FakeWindow] = []
            for (i, name) in c.ownerNames.enumerated() {
                let frame = Rect(
                    minX: Double(80 + i * 440 + c.windowXs[i]), minY: Double(200 + c.windowYs[i] * 4),
                    width: 360, height: 280)
                windows.append(FakeWindow(snapshot: WindowSnapshot(
                    id: WindowID(i + 1), ownerName: name, ownerPID: Int32(100 + i), frame: frame, zIndex: i)))
            }
            var source = FakeWindowSource(windows: windows)
            var now = Date(timeIntervalSince1970: TimeInterval(c.startSeconds))
            let engine = WorldEngine(clockStart: now, screen: Self.screen, rng: RandomSource(seed: c.seed))
            let eventSink = FileEventSink(directory: dir)
            var events: [EventRecord] = []
            var payloads: [PromptPayload] = []
            var pendingResults: [(UInt64, ThoughtResult)] = []
            for frame in 0 ..< Self.frames {
                var commands: [Command] = []
                switch frame {
                case 1: commands = [.unlockAllDecor]
                case 2: commands = [.triggerWish(c.wish, c.wisher)]
                case 3: commands = [.setDayNight(c.dayNight)]
                default: break
                }
                if frame == c.closeFrame { source.close(1) }
                now = now.addingTimeInterval(Self.dt)
                let out = engine.step(FrameInput(
                    poll: source.poll(), screen: Self.screen, commands: commands, now: now, timeZone: tz,
                    thoughtsEnabled: model.effective.thoughtsEnabled, thoughtResults: pendingResults))
                pendingResults = out.thoughtRequests.map { ($0.id, ThoughtResult.text(c.thoughtText)) }
                payloads += out.thoughtRequests.map(\.payload)
                events += out.events
            }

            // world.json：makeSave 编码结果与写到临时目录的文件。
            let save = engine.makeSave(now: now)
            let worldData = try SaveCodec.encode(save)
            #expect(!pvLeaks(worldData, key: key), "world.json 含 Key")
            #expect(FileSaveStore(directory: dir).save(save))

            // 事件行。
            for e in events {
                let line = EventCodec.encodeLine(e, timeZone: tz)
                #expect(!pvLeaks(line, key: key), "事件行含 Key：\(e.type)")
                eventSink.append(line)
            }

            // 4. 日记：带 Key 的配置交给 FakeLLMClient（成功或失败回退模板），另写一篇模板日记。
            let fake = FakeLLMClient(c.diaryLLMSucceeds ? [.text(c.diaryText)] : [.failure(.transport)])
            let diaryStore = DiaryStore(storage: FileDiaryStorage(directory: dir))
            let written = await DiaryBatch.run(
                .today, events: events, store: diaryStore, writer: DiaryWriter(client: fake, maxLength: 500),
                config: config, now: now, timeZone: tz)
            let date = LocalDate.of(now, timeZone: tz)
            var entries = written
            for id in ResidentID.allCases {
                entries.append(DiaryEntry(
                    date: date, resident: id, text: DiaryTemplates.text(writer: id, events: events), method: .template))
            }
            for entry in entries {
                #expect(!pvLeaks(DiaryCodec.encodeLine(entry), key: key), "日记行含 Key")
            }
            payloads += await fake.payloads

            // 5. Payload：引擎发出的 Thought Payload、日记请求的 Payload，以及按全部事件新构造的 Payload。
            for id in ResidentID.allCases {
                payloads.append(PromptBuilder.diary(resident: id, date: date, events: events, timeZone: tz))
                payloads.append(PromptBuilder.thought(actor: id, recent: events, date: date, timeZone: tz))
            }
            for p in payloads {
                for m in p.messages() {
                    #expect(!pvLeaks(m.role + m.content, key: key), "Payload 消息含 Key")
                }
                let body = try ChatCompletions.requestBody(p, model: config.model)
                #expect(!pvLeaks(body, key: key), "请求体含 Key")

                let req = try ChatCompletions.makeRequest(p, config: config)
                // 含控制字符（如换行）的值不是合法的 HTTP 头值，Foundation 会丢弃该头；此时只要求不出现别的值。
                let auth = req.value(forHTTPHeaderField: "Authorization")
                if key.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                    #expect(auth == nil || auth == "Bearer \(key)")
                } else {
                    #expect(auth == "Bearer \(key)")
                }
                #expect(!pvLeaks(req.httpBody ?? Data(), key: key), "makeRequest 请求体含 Key")
                #expect(!pvLeaks(req.url?.absoluteString ?? "", key: key), "请求 URL 含 Key")
                for (name, value) in req.allHTTPHeaderFields ?? [:]
                where name.caseInsensitiveCompare("Authorization") != .orderedSame {
                    #expect(!pvLeaks(name + value, key: key), "请求头 \(name) 含 Key")
                }
            }

            // 6. 临时目录中的全部文件（settings.json、world.json、events.jsonl、diary.jsonl）。
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            #expect(files.contains { $0.lastPathComponent == FileLLMSettingsStore.fileName })
            #expect(files.contains { $0.lastPathComponent == FileSaveStore.defaultFileName })
            for file in files {
                let data = try Data(contentsOf: file)
                #expect(!pvLeaks(data, key: key), "\(file.lastPathComponent) 含 Key")
            }
        }
    }
}
