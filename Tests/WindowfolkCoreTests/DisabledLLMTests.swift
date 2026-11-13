import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// 开关关闭或设置不完整时不发请求的属性测试（design.md Property 32，任务 16.2）。
//
// 设置组合：两个开关、服务地址（空、空白、合法、各种无效格式）、模型名（空、空白、合法）、
// API Key（没有、空白、合法、钥匙串读取失败）。每个字段表都标注了该值是否合法，
// 测试用这张表独立判断「关闭或不完整」，不借用被测的校验函数。
//
// - 小心思：按应用层的方式取 `LLMSettingsModel.thoughtsConfig != nil` 作为每帧的 `thoughtsEnabled`，
//   用随机窗口操作、调试命令、昼夜覆盖、世界隐藏和随机 Thought 结果驱动完整剧情世界，
//   每帧 `StepOutput.thoughtRequests` 都应为空；仿照 ThoughtCoordinator 把请求交给 `FakeLLMClient`，
//   请求数应为 0。
// - 日记：`DiaryBatch.config` 关闭时不读钥匙串；用随机事件记录序列和随机批次种类运行 `DiaryBatch.run`，
//   并对每篇计划日记直接调用 `DiaryWriter.write`，`FakeLLMClient` 请求数应为 0。

// MARK: - 设置生成器

fileprivate let disabledEndpoints: [(text: String, valid: Bool)] = [
    ("", false),
    ("   ", false),
    ("\n\t", false),
    ("https://api.example.com/v1/chat/completions", true),
    ("  http://localhost:8080/v1  ", true),
    ("HTTPS://Example.com", true),
    ("ftp://example.com", false),
    ("api.example.com/v1", false),
    ("https://", false),
    ("http:///path", false),
    ("not a url", false),
    ("mailto:someone@example.com", false),
]

fileprivate let disabledModels: [(text: String, valid: Bool)] = [
    ("", false),
    ("  \n", false),
    ("gpt-4o-mini", true),
    (" 模型 ", true),
]

/// API Key 存储状态。`stored` 为 nil 表示没有保存。
fileprivate let disabledKeys: [(stored: String?, failRead: Bool, valid: Bool)] = [
    (nil, false, false),
    ("   ", false, false),
    ("\t\n", false, false),
    ("sk-test-123456", false, true),
    ("sk-test-123456", true, false),
    (nil, true, false),
]

fileprivate struct SettingsSpec: Sendable, CustomStringConvertible {
    var diaryOn: Bool
    var thoughtsOn: Bool
    var endpoint: Int
    var model: Int
    var key: Int
    var diaryAck: Bool
    var thoughtsAck: Bool

    var settings: LLMSettings {
        LLMSettings(
            diaryEnabled: diaryOn, thoughtsEnabled: thoughtsOn,
            endpoint: disabledEndpoints[endpoint].text, model: disabledModels[model].text,
            diaryDisclosureAcknowledged: diaryAck, thoughtsDisclosureAcknowledged: thoughtsAck)
    }

    var keyResult: Result<String?, SecretStoreError> {
        let k = disabledKeys[key]
        return k.failRead ? .failure(.operationFailed(status: -25300)) : .success(k.stored)
    }

    /// 三项都合法且钥匙串读取成功。
    var complete: Bool { disabledEndpoints[endpoint].valid && disabledModels[model].valid && disabledKeys[key].valid }
    var diaryGated: Bool { !diaryOn || !complete }
    var thoughtsGated: Bool { !thoughtsOn || !complete }

    var description: String {
        "diary=\(diaryOn) thoughts=\(thoughtsOn) endpoint=\(disabledEndpoints[endpoint].text.debugDescription) "
            + "model=\(disabledModels[model].text.debugDescription) key=\(disabledKeys[key])"
    }
}

/// 一半概率三项都取合法值，使「开关关闭但设置完整」与「开关打开但设置不完整」都经常出现。
fileprivate var settingsSpecGen: Generator<SettingsSpec, some SendableSequenceType> {
    let validEndpoints = disabledEndpoints.indices.filter { disabledEndpoints[$0].valid }
    let validModels = disabledModels.indices.filter { disabledModels[$0].valid }
    let validKeys = disabledKeys.indices.filter { disabledKeys[$0].valid }
    return zip(
        Gen<Bool>.bool, Gen<Bool>.bool, Gen<Bool>.bool,
        Gen<Int>.int(in: 0...(disabledEndpoints.count - 1)),
        Gen<Int>.int(in: 0...(disabledModels.count - 1)),
        Gen<Int>.int(in: 0...(disabledKeys.count - 1)),
        Gen<Int>.int(in: 0...99),
        Gen<Bool>.bool, Gen<Bool>.bool
    ).map { diaryOn, thoughtsOn, preferValid, e, m, k, pick, da, ta in
        SettingsSpec(
            diaryOn: diaryOn, thoughtsOn: thoughtsOn,
            endpoint: preferValid ? validEndpoints[pick % validEndpoints.count] : e,
            model: preferValid ? validModels[pick % validModels.count] : m,
            key: preferValid ? validKeys[pick % validKeys.count] : k,
            diaryAck: da, thoughtsAck: ta)
    }
}

/// 只在内存中保存的设置存储。
fileprivate struct DisabledSettingsStore: LLMSettingsStore {
    let value: LLMSettings
    func load() -> LLMSettings { value }
    func save(_ s: LLMSettings) -> Bool { true }
}

/// 内存日记存储。
fileprivate final class DisabledDiaryStorage: DiaryStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func readAll() -> Data? { lock.withLock { data.isEmpty ? nil : data } }
    func append(_ line: Data) -> Bool { lock.withLock { data.append(line); return true } }
}

/// 两个配置在 `LLMSettingsModel` 上的读数（在主线程上取）。
fileprivate struct ModelConfigs: Sendable {
    var diary: LLMRequestConfig?
    var thoughts: LLMRequestConfig?
}

@MainActor
fileprivate func modelConfigs(_ spec: SettingsSpec) -> ModelConfigs {
    let k = disabledKeys[spec.key]
    let secrets = InMemorySecretStore(apiKey: k.stored)
    secrets.failReads = k.failRead
    let model = LLMSettingsModel(
        store: DisabledSettingsStore(value: spec.settings), secrets: secrets, saveDelay: .seconds(3600))
    return ModelConfigs(diary: model.diaryConfig, thoughts: model.thoughtsConfig)
}

// MARK: - 世界操作生成器

fileprivate enum WorldOp: Sendable, CustomStringConvertible {
    case wait(Int)
    case addWindow(x: Int, y: Int, w: Int, h: Int, app: Int)
    case closeWindow(Int)
    case moveWindow(Int, x: Int, y: Int)
    case hideWindow(Int)
    case showWindow(Int)
    case command(Int)
    case result(id: Int, text: Int)
    case worldHidden(Bool)

    var description: String {
        switch self {
        case let .wait(n): "wait(\(n))"
        case let .addWindow(x, y, w, h, app): "add(\(x),\(y),\(w),\(h),app\(app))"
        case let .closeWindow(i): "close(\(i))"
        case let .moveWindow(i, x, y): "move(\(i),\(x),\(y))"
        case let .hideWindow(i): "hide(\(i))"
        case let .showWindow(i): "show(\(i))"
        case let .command(c): "cmd(\(disabledCommands[c]))"
        case let .result(id, text): "result(\(id),\(text))"
        case let .worldHidden(h): "hidden(\(h))"
        }
    }
}

fileprivate let disabledCommands: [Command] = [
    .triggerWish(.flower, nil), .triggerWish(.chair, .a), .triggerWish(.lamp, .b),
    .triggerWish(.visit, .a), .triggerWish(.chase, nil),
    .fastForward, .unlockAllDecor, .debugGiveFlower, .debugSeek,
    .setDayNight(.day), .setDayNight(.night), .setDayNight(.auto), .resetWorld,
]

fileprivate let disabledApps = ["Notes", "Safari", "备忘录", "Visual Studio Code"]

/// 每次等待的帧数与每帧时长。包含 1 帧、数秒和超过 Thought_Min_Interval 的长等待（dt 被上限截断，以多帧推进）。
fileprivate let disabledWaits: [(frames: Int, dt: Double)] = [(1, 1.0 / 30), (15, 1.0 / 30), (30, 0.2), (20, 1.0), (40, 0.25)]

fileprivate var worldOpGen: Generator<WorldOp, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...13),
        Gen<Int>.int(in: 0...170), Gen<Int>.int(in: 4...95),
        Gen<Int>.int(in: 25...80), Gen<Int>.int(in: 20...60),
        Gen<Int>.int(in: 0...7)
    ).map { kind, a, b, c, d, e -> WorldOp in
        switch kind {
        case 0...3: return .wait(a % disabledWaits.count)
        case 4, 5: return .addWindow(x: a, y: b, w: c, h: d, app: e % disabledApps.count)
        case 6: return .closeWindow(e)
        case 7: return .moveWindow(e, x: a, y: b)
        case 8: return .hideWindow(e)
        case 9: return .showWindow(e)
        case 10, 11: return .command(a % disabledCommands.count)
        case 12: return .result(id: e, text: a % 3)
        default: return .worldHidden(a % 4 == 0)
        }
    }
}

fileprivate var worldScriptGen: Generator<[WorldOp], some SendableSequenceType> {
    worldOpGen.array(of: 4...24)
}

// MARK: - 日记事件生成器

fileprivate let diaryEventTypes = EventType.allCases
fileprivate let diaryRefs: [String?] = [
    "resident_a", "resident_b", "player", "app:Notes", "app:备忘录", "decor:1", nil,
]

fileprivate struct DiaryScript: Sendable, CustomStringConvertible {
    /// （相对首日的秒数，类型，actor，target）
    var events: [(Int, Int, Int, Int)]
    /// 0 catchUp，1 dayChanged，2 today
    var kind: Int
    /// 「此刻」相对首日的天数（0...4）
    var nowDay: Int

    var description: String { "kind=\(kind) nowDay=\(nowDay) events=\(events)" }
}

fileprivate var diaryScriptGen: Generator<DiaryScript, some SendableSequenceType> {
    let event = zip(
        Gen<Int>.int(in: 0...(4 * 86_400)),
        Gen<Int>.int(in: 0...(diaryEventTypes.count - 1)),
        Gen<Int>.int(in: 0...(diaryRefs.count - 1)),
        Gen<Int>.int(in: 0...(diaryRefs.count - 1))
    ).map { ($0, $1, $2, $3) }
    return zip(event.array(of: 0...30), Gen<Int>.int(in: 0...2), Gen<Int>.int(in: 0...4))
        .map { DiaryScript(events: $0, kind: $1, nowDay: $2) }
}

// MARK: - 属性测试

@Suite struct DisabledLLMTests {
    private static let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))

    // Feature: V2, Property 32: 开关关闭时不发请求（小心思）
    // **Validates: Requirements 11.10, 12.6**
    @Test func thoughtsGatedSendNoRequests() async {
        await propertyCheck(count: 100, input: settingsSpecGen, worldScriptGen) { spec, script in
            guard spec.thoughtsGated else { return }
            let s = spec.settings
            let configs = await MainActor.run { modelConfigs(spec) }
            #expect(configs.thoughts == nil, "\(spec)")
            if !spec.complete {
                #expect(LLMSettingsValidation.config(s, apiKeyResult: spec.keyResult) == nil, "\(spec)")
                #expect(!LLMSettingsValidation.effective(s, apiKeyResult: spec.keyResult).thoughtsEnabled, "\(spec)")
            }
            let thoughtsEnabled = configs.thoughts != nil

            let client = FakeLLMClient([.text("想吃果子")])
            let utc = TimeZone(identifier: "UTC")!
            var now = Date(timeIntervalSince1970: 1_760_000_000)
            let engine = WorldEngine(clockStart: now, screen: Self.screen, rng: RandomSource(seed: 32))
            var source = FakeWindowSource(snapshots: [
                WindowSnapshot(id: 1, ownerName: "Notes", ownerPID: 10,
                               frame: Rect(minX: 100, minY: 300, width: 400, height: 300), zIndex: 0),
                WindowSnapshot(id: 2, ownerName: "Safari", ownerPID: 11,
                               frame: Rect(minX: 700, minY: 200, width: 500, height: 400), zIndex: 1),
            ])
            var nextID: WindowID = 3
            var hidden = false
            var commands: [Command] = []
            var results: [(UInt64, ThoughtResult)] = []

            func step(_ dt: Double) async {
                now = now.addingTimeInterval(dt)
                let out = engine.step(FrameInput(
                    poll: source.poll(), screen: Self.screen, commands: commands, now: now, timeZone: utc,
                    worldHidden: hidden, thoughtsEnabled: thoughtsEnabled, thoughtResults: results))
                commands = []
                results = []
                #expect(out.thoughtRequests.isEmpty, "\(spec)\n\(script)")
                // 与 ThoughtCoordinator.dispatch 相同：只有配置非 nil 时才交给 LLMClient。
                if let config = configs.thoughts {
                    for r in out.thoughtRequests { _ = await client.complete(r.payload, config: config) }
                }
            }

            func windowID(_ i: Int) -> WindowID? {
                source.windows.isEmpty ? nil : source.windows[i % source.windows.count].snapshot.id
            }

            await step(1.0 / 30)
            for op in script {
                switch op {
                case let .wait(w):
                    for _ in 0..<disabledWaits[w].frames { await step(disabledWaits[w].dt) }
                    continue
                case let .addWindow(x, y, w, h, app):
                    source.addInFront(WindowSnapshot(
                        id: nextID, ownerName: disabledApps[app], ownerPID: 20 + Int32(app),
                        frame: Rect(minX: Double(x * 8), minY: Double(y * 8), width: Double(w * 8), height: Double(h * 8)),
                        zIndex: 0))
                    nextID += 1
                case let .closeWindow(i):
                    if let id = windowID(i) { source.close(id) }
                case let .moveWindow(i, x, y):
                    if let id = windowID(i) { source.move(id, to: Point(x: Double(x * 8), y: Double(y * 8))) }
                case let .hideWindow(i):
                    if let id = windowID(i) { source.hide(id) }
                case let .showWindow(i):
                    if let id = windowID(i) { source.show(id) }
                case let .command(c):
                    commands.append(disabledCommands[c])
                case let .result(id, text):
                    results.append((UInt64(id), text == 0 ? .failure : .text(["好开心", "  \n "][text - 1])))
                case let .worldHidden(h):
                    hidden = h
                }
                await step(1.0 / 30)
            }
            #expect(await client.requestCount == 0, "\(spec)\n\(script)")
        }
    }

    // Feature: V2, Property 32: 开关关闭时不发请求（日记）
    // **Validates: Requirements 11.10, 12.6**
    @Test func diaryGatedSendsNoRequests() async {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let day0 = LocalDate(year: 2026, month: 3, day: 7)
        let start = day0.range(timeZone: tz).lowerBound

        await propertyCheck(count: 100, input: settingsSpecGen, diaryScriptGen) { spec, script in
            guard spec.diaryGated else { return }
            let s = spec.settings
            let configs = await MainActor.run { modelConfigs(spec) }
            #expect(configs.diary == nil, "\(spec)")
            if !spec.complete {
                #expect(LLMSettingsValidation.config(s, apiKeyResult: spec.keyResult) == nil, "\(spec)")
                #expect(!LLMSettingsValidation.effective(s, apiKeyResult: spec.keyResult).diaryEnabled, "\(spec)")
            }

            var keyReads = 0
            let config = DiaryBatch.config(s) {
                keyReads += 1
                return spec.keyResult
            }
            #expect(config == nil, "\(spec)")
            if !spec.diaryOn { #expect(keyReads == 0, "\(spec)") }

            let events = script.events
                .map { t, type, actor, target in
                    EventRecord(time: start.addingTimeInterval(Double(t)), type: diaryEventTypes[type],
                                actor: diaryRefs[actor], target: diaryRefs[target],
                                detail: ["wish_type": "chase", "chase_outcome": "caught"])
                }
                .sorted { $0.time < $1.time }
            let now = start.addingTimeInterval(Double(script.nowDay * 86_400 + 43_200))
            let today = LocalDate.of(now, timeZone: tz)
            let kind: DiaryBatchKind =
                switch script.kind {
                case 0: .catchUp
                case 1: .dayChanged(from: day0, to: today)
                default: .today
                }

            let client = FakeLLMClient([.text("今天很开心。")])
            let writer = DiaryWriter(client: client, maxLength: Tunables().diaryMaxLength)
            let store = DiaryStore(storage: DisabledDiaryStorage())
            let written = await DiaryBatch.run(
                kind, events: events, store: store, writer: writer, config: config, now: now, timeZone: tz)
            #expect(written.allSatisfy { $0.method == .template }, "\(spec)\n\(script)")

            // 每篇计划日记也直接经 DiaryWriter.write 写一次（模型给出的配置）。
            for job in DiaryBatch.plan(kind, events: events, existing: [], now: now, timeZone: tz) {
                let entry = await writer.write(job.key, events: job.events, config: configs.diary, timeZone: tz)
                #expect(entry.method == .template, "\(spec)\n\(script)")
            }
            #expect(await client.requestCount == 0, "\(spec)\n\(script)")
        }
    }
}
