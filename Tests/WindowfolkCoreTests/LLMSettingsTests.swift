import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// MARK: - 生成器

/// 首尾填充用的空白字符：空格、制表、换行、回车、全角空格。
fileprivate let lsPadCharacters: [Character] = [" ", "\t", "\n", "\r", "\u{3000}"]

/// 0 到 3 个空白组成的填充串。
fileprivate var lsPadding: Generator<String, some SendableSequenceType> {
    Gen<Character?>.element(of: lsPadCharacters).map { $0! }.string(of: 0...3)
}

/// 模型名和 API Key 内容用的非空白字符。
fileprivate let lsTextCharacters: [Character] = Array("abcXYZ019-_./:=+\"\\") + ["都", "é", "🐹"]

fileprivate var lsWord: Generator<String, some SendableSequenceType> {
    Gen<Character?>.element(of: lsTextCharacters).map { $0! }.string(of: 1...6)
}

/// 一段可能为空的文本，以及它两端的空白填充。
/// `core` 本身不以空白开头或结尾，所以「去掉首尾空白后的期望值」就是 `core`，
/// 不需要调用实现里的修剪函数。
fileprivate struct PaddedText: Sendable, CustomStringConvertible {
    var core: String
    var leading: String
    var trailing: String
    var raw: String { leading + core + trailing }
    var description: String { String(reflecting: raw) }
}

/// 约 1/4 为空（只剩空白填充），其余是一或两个单词，中间可能有一个空格。
fileprivate var lsPaddedText: Generator<PaddedText, some SendableSequenceType> {
    zip(Gen<Int>.int(in: 0...3), lsWord, lsWord, Gen<Bool>.bool, lsPadding, lsPadding)
        .map { mode, a, b, twoWords, lead, trail in
            let core: String
            if mode == 0 { core = "" } else { core = twoWords ? a + " " + b : a }
            return PaddedText(core: core, leading: lead, trailing: trail)
        }
}

/// 服务地址的构造方式。期望的校验结果由构造方式决定。
fileprivate enum EndpointKind: Int, CaseIterable, Sendable {
    /// 空串或只含空白 → missingEndpoint。
    case blank
    /// `http(s)://host[:port][/path]` → 有效。
    case valid
    /// 没有 scheme：`host[:port][/path]` → invalidEndpoint。
    case noScheme
    /// 其他 scheme：`ftp://host...` 等 → invalidEndpoint。
    case otherScheme
    /// 没有主机名：`https://`、`https:///path`、`http://:8080/x` → invalidEndpoint。
    case emptyHost
    /// 缺少 `//`：`http:host/path` → invalidEndpoint。
    case missingSlashes
}

fileprivate struct EndpointCase: Sendable, CustomStringConvertible {
    var kind: EndpointKind
    var text: PaddedText
    var description: String { "\(kind) \(text)" }
}

fileprivate let lsHostCharacters: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789")
fileprivate let lsPathCharacters: [Character] = Array("abcXYZ0129-_")
fileprivate let lsValidSchemes = ["http", "https", "HTTP", "Https"]
fileprivate let lsOtherSchemes = ["ftp", "file", "ws", "mailto"]

fileprivate var lsEndpoint: Generator<EndpointCase, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...(EndpointKind.allCases.count - 1)),
        Gen<Character?>.element(of: lsHostCharacters).map { $0! }.string(of: 1...8).array(of: 1...3),
        Gen<Int>.int(in: 1...65535).optional(valueRate: 0.4),
        Gen<Character?>.element(of: lsPathCharacters).map { $0! }.string(of: 1...6).array(of: 0...3),
        Gen<Int>.int(in: 0...3),
        lsPadding,
        lsPadding
    ).map { kindIndex, labels, port, segments, schemePick, lead, trail in
        let kind = EndpointKind(rawValue: kindIndex)!
        let host = labels.joined(separator: ".")
        let portText = port.map { ":\($0)" } ?? ""
        let path = segments.map { "/" + $0 }.joined()
        let scheme = lsValidSchemes[schemePick]
        let core: String
        switch kind {
        case .blank: core = ""
        case .valid: core = "\(scheme)://\(host)\(portText)\(path)"
        case .noScheme: core = "\(host)\(portText)\(path)"
        case .otherScheme: core = "\(lsOtherSchemes[schemePick])://\(host)\(portText)\(path)"
        case .emptyHost: core = "\(scheme)://\(portText)\(path)"
        case .missingSlashes: core = "\(scheme):\(host)\(path)"
        }
        return EndpointCase(kind: kind, text: PaddedText(core: core, leading: lead, trailing: trail))
    }
}

/// 钥匙串读取结果的形状。
fileprivate enum KeyCase: Sendable, CustomStringConvertible {
    case none
    case key(PaddedText)
    case failure(Int32)

    var result: Result<String?, SecretStoreError> {
        switch self {
        case .none: return .success(nil)
        case let .key(t): return .success(t.raw)
        case let .failure(status): return .failure(.operationFailed(status: status))
        }
    }

    var description: String {
        switch self {
        case .none: return "nil"
        case let .key(t): return "key(\(t))"
        case let .failure(s): return "failure(\(s))"
        }
    }
}

fileprivate var lsKey: Generator<KeyCase, some SendableSequenceType> {
    zip(Gen<Int>.int(in: 0...5), lsPaddedText, Gen<Int>.int(in: -30000...0)).map { mode, text, status in
        switch mode {
        case 0: return KeyCase.none
        case 1: return KeyCase.failure(Int32(status))
        default: return KeyCase.key(text)
        }
    }
}

fileprivate struct SettingsCase: Sendable, CustomStringConvertible {
    var endpoint: EndpointCase
    var model: PaddedText
    var key: KeyCase
    var diaryEnabled: Bool
    var thoughtsEnabled: Bool
    var diaryAck: Bool
    var thoughtsAck: Bool

    var settings: LLMSettings {
        LLMSettings(diaryEnabled: diaryEnabled, thoughtsEnabled: thoughtsEnabled,
                    endpoint: endpoint.text.raw, model: model.raw,
                    diaryDisclosureAcknowledged: diaryAck, thoughtsDisclosureAcknowledged: thoughtsAck)
    }

    var description: String {
        "endpoint=\(endpoint) model=\(model) key=\(key) diary=\(diaryEnabled) thoughts=\(thoughtsEnabled)"
    }
}

fileprivate var lsSettingsCase: Generator<SettingsCase, some SendableSequenceType> {
    zip(lsEndpoint, lsPaddedText, lsKey, Gen<Bool>.bool, Gen<Bool>.bool, Gen<Bool>.bool, Gen<Bool>.bool)
        .map { e, m, k, d, t, da, ta in
            SettingsCase(endpoint: e, model: m, key: k, diaryEnabled: d, thoughtsEnabled: t,
                         diaryAck: da, thoughtsAck: ta)
        }
}

// MARK: - 参考规则

/// 按 Requirement 11.5、11.6、11.9 由构造方式直接给出期望的问题列表（顺序：地址、模型、API Key、钥匙串）。
fileprivate func expectedIssues(_ c: SettingsCase) -> [LLMSettingsIssue] {
    var out: [LLMSettingsIssue] = []
    switch c.endpoint.kind {
    case .blank: out.append(.missingEndpoint)
    case .valid: break
    case .noScheme, .otherScheme, .emptyHost, .missingSlashes: out.append(.invalidEndpoint)
    }
    if c.model.core.isEmpty { out.append(.missingModel) }
    switch c.key {
    case .none: out.append(.missingAPIKey)
    case let .key(t): if t.core.isEmpty { out.append(.missingAPIKey) }
    case .failure: out.append(contentsOf: [.missingAPIKey, .keychainFailure])
    }
    return out
}

// MARK: - 属性

@Suite struct LLMSettingsTests {
    // Feature: V2, Property 29: LLM 设置校验
    // **Validates: Requirements 11.5, 11.6, 11.9**
    @Test func llmSettingsValidation() async {
        await propertyCheck(count: 300, input: lsSettingsCase) { c in
            let s = c.settings
            let result = c.key.result
            let expected = expectedIssues(c)

            // issues 与参考规则一致（Result 重载；读取成功时 String? 重载也一致）。
            #expect(LLMSettingsValidation.issues(s, apiKeyResult: result) == expected, "\(c)")
            if case let .success(key) = result {
                #expect(LLMSettingsValidation.issues(s, apiKey: key) == expected, "\(c)")
            }

            let effective = LLMSettingsValidation.effective(s, apiKeyResult: result)
            let config = LLMSettingsValidation.config(s, apiKeyResult: result)
            if expected.isEmpty {
                // 没有问题：设置原样保留，config 各项为去掉首尾空白后的输入。
                #expect(effective == s, "\(c)")
                guard let config, case let .key(key) = c.key else {
                    Issue.record("没有问题时应得到 config：\(c)")
                    return
                }
                #expect(config.endpoint.absoluteString == c.endpoint.text.core, "\(c)")
                #expect(config.model == c.model.core, "\(c)")
                #expect(config.apiKey == key.core, "\(c)")
                #expect(LLMSettingsValidation.config(s, apiKey: key.raw) == config, "\(c)")
                #expect(LLMSettingsValidation.effective(s, apiKey: key.raw) == s, "\(c)")
            } else {
                // 有任一问题：两个开关关闭、其他字段不变，config 为 nil。
                var off = s
                off.diaryEnabled = false
                off.thoughtsEnabled = false
                #expect(effective == off, "\(c)")
                #expect(config == nil, "\(c)")
                if case let .success(key) = result {
                    #expect(LLMSettingsValidation.effective(s, apiKey: key) == off, "\(c)")
                    #expect(LLMSettingsValidation.config(s, apiKey: key) == nil, "\(c)")
                }
            }
        }
    }

    // Feature: V2, Property 30: LLM 设置往返
    // **Validates: Requirements 11.4**
    @Test func llmSettingsRoundTrip() async {
        await propertyCheck(count: 200, input: lsSettingsCase, lsSettingsCase) { first, second in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("windowfolk-p30-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            // 目录尚不存在：save 自行创建目录，load 得到相等的值。
            let store = FileLLMSettingsStore(directory: dir)
            #expect(store.save(first.settings), "\(first)")
            #expect(store.load() == first.settings, "\(first)")

            // 覆盖写入后读到新值；新建的 store（模拟重启）读到同一个值。
            #expect(store.save(second.settings), "\(second)")
            #expect(store.load() == second.settings, "\(second)")
            #expect(FileLLMSettingsStore(directory: dir).load() == second.settings, "\(second)")

            // API Key 走 SecretStore 往返：非空原样读回，空串表示删除。
            let secrets = InMemorySecretStore()
            for c in [first, second] {
                guard case let .key(text) = c.key else { continue }
                guard case .success = secrets.writeAPIKey(text.raw) else {
                    Issue.record("写入 API Key 失败：\(c)")
                    continue
                }
                let expected: String? = text.raw.isEmpty ? nil : text.raw
                guard case let .success(read) = secrets.readAPIKey() else {
                    Issue.record("读取 API Key 失败：\(c)")
                    continue
                }
                #expect(read == expected, "\(c)")
            }
        }
    }
}
