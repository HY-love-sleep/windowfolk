import Foundation

// LLM 设置、设置校验、settings.json 存储与 API Key 存储接口
// （design.md「Core：LLM」、任务 11.7，Requirement 11.1、11.3–11.6、11.9、12.6、19.4）。
//
// API Key 不属于 `LLMSettings`：它只存在于 `SecretStore` 和每次请求的 `LLMRequestConfig` 中，
// 因此 `settings.json` 在类型上就无法写入 API Key（Requirement 11.3）。
// 真正的钥匙串实现在应用层（`KeychainSecretStore`），这里只定义协议和测试用的内存实现。

/// 保存在 `settings.json` 中的 LLM 设置。默认值即首次启动时的状态：两个开关关闭、地址和模型为空（Requirement 11.1）。
public struct LLMSettings: Hashable, Sendable, Codable {
    /// 「日记使用 LLM」。
    public var diaryEnabled: Bool
    /// 「小心思」。
    public var thoughtsEnabled: Bool
    /// 服务地址（原样保存，校验和请求时去掉首尾空白）。
    public var endpoint: String
    /// 模型名（原样保存，校验和请求时去掉首尾空白）。
    public var model: String
    /// 「日记使用 LLM」首次打开时的说明是否已确认（Requirement 11.8）。
    public var diaryDisclosureAcknowledged: Bool
    /// 「小心思」首次打开时的说明是否已确认（Requirement 11.8）。
    public var thoughtsDisclosureAcknowledged: Bool

    public init(diaryEnabled: Bool = false, thoughtsEnabled: Bool = false,
                endpoint: String = "", model: String = "",
                diaryDisclosureAcknowledged: Bool = false, thoughtsDisclosureAcknowledged: Bool = false) {
        self.diaryEnabled = diaryEnabled
        self.thoughtsEnabled = thoughtsEnabled
        self.endpoint = endpoint
        self.model = model
        self.diaryDisclosureAcknowledged = diaryDisclosureAcknowledged
        self.thoughtsDisclosureAcknowledged = thoughtsDisclosureAcknowledged
    }

    private enum CodingKeys: String, CodingKey {
        case diaryEnabled, thoughtsEnabled, endpoint, model
        case diaryDisclosureAcknowledged, thoughtsDisclosureAcknowledged
    }

    /// 缺少的字段取默认值，便于以后增减字段时旧文件仍可读。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMSettings()
        diaryEnabled = try c.decodeIfPresent(Bool.self, forKey: .diaryEnabled) ?? d.diaryEnabled
        thoughtsEnabled = try c.decodeIfPresent(Bool.self, forKey: .thoughtsEnabled) ?? d.thoughtsEnabled
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? d.endpoint
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        diaryDisclosureAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .diaryDisclosureAcknowledged)
            ?? d.diaryDisclosureAcknowledged
        thoughtsDisclosureAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .thoughtsDisclosureAcknowledged)
            ?? d.thoughtsDisclosureAcknowledged
    }
}

/// 设置中需要玩家补全或修正的项目（Requirement 11.5、11.6、11.9）。
public enum LLMSettingsIssue: Hashable, Sendable {
    /// 服务地址为空或只含空白。
    case missingEndpoint
    /// 模型名为空或只含空白。
    case missingModel
    /// API Key 为空、只含空白，或因钥匙串失败而按空处理。
    case missingAPIKey
    /// 服务地址不是带主机名的 `http://` / `https://` URL。
    case invalidEndpoint
    /// 钥匙串读取（或写入）失败。
    case keychainFailure
}

/// API Key 存储失败。`status` 为底层错误码（钥匙串为 `OSStatus`），内存实现用任意值。
public enum SecretStoreError: Error, Hashable, Sendable {
    case operationFailed(status: Int32)
}

/// 设置校验。所有发起请求的地方只能通过这里拿到配置（Requirement 12.6）。
public enum LLMSettingsValidation {
    /// 去掉首尾空白和换行。
    public static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析服务地址：去掉首尾空白后用 `URLComponents` 解析，scheme 必须是 http 或 https 且 host 非空。
    /// 空地址或格式无效时返回 nil。
    public static func endpointURL(_ endpoint: String) -> URL? {
        let text = trimmed(endpoint)
        guard !text.isEmpty, let comps = URLComponents(string: text),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty
        else { return nil }
        return comps.url
    }

    /// 按固定顺序列出问题：地址、模型、API Key、钥匙串。
    /// `apiKey` 为 nil 表示没有 Key（按空处理）。
    public static func issues(_ s: LLMSettings, apiKey: String?) -> [LLMSettingsIssue] {
        issues(s, apiKey: apiKey, keychainFailed: false)
    }

    /// 同上，但直接接收钥匙串读取结果：读取失败时记 `keychainFailure`，并按 Key 为空处理（Requirement 11.9）。
    public static func issues(_ s: LLMSettings, apiKeyResult: Result<String?, SecretStoreError>) -> [LLMSettingsIssue] {
        switch apiKeyResult {
        case let .success(key): return issues(s, apiKey: key, keychainFailed: false)
        case .failure: return issues(s, apiKey: nil, keychainFailed: true)
        }
    }

    /// 没有任何问题时返回请求配置（各项已去掉首尾空白），否则为 nil。
    public static func config(_ s: LLMSettings, apiKey: String?) -> LLMRequestConfig? {
        guard issues(s, apiKey: apiKey).isEmpty,
              let url = endpointURL(s.endpoint), let key = apiKey
        else { return nil }
        return LLMRequestConfig(endpoint: url, model: trimmed(s.model), apiKey: trimmed(key))
    }

    /// 钥匙串读取失败时为 nil。
    public static func config(_ s: LLMSettings, apiKeyResult: Result<String?, SecretStoreError>) -> LLMRequestConfig? {
        guard case let .success(key) = apiKeyResult else { return nil }
        return config(s, apiKey: key)
    }

    /// 有任何问题时两个开关强制关闭，其余字段不变；没有问题时原样返回（Requirement 11.5、12.6）。
    public static func effective(_ s: LLMSettings, apiKey: String?) -> LLMSettings {
        forceOffIfNeeded(s, hasIssues: !issues(s, apiKey: apiKey).isEmpty)
    }

    /// 钥匙串读取失败时两个开关强制关闭。
    public static func effective(_ s: LLMSettings, apiKeyResult: Result<String?, SecretStoreError>) -> LLMSettings {
        forceOffIfNeeded(s, hasIssues: !issues(s, apiKeyResult: apiKeyResult).isEmpty)
    }

    private static func issues(_ s: LLMSettings, apiKey: String?, keychainFailed: Bool) -> [LLMSettingsIssue] {
        var out: [LLMSettingsIssue] = []
        if trimmed(s.endpoint).isEmpty {
            out.append(.missingEndpoint)
        } else if endpointURL(s.endpoint) == nil {
            out.append(.invalidEndpoint)
        }
        if trimmed(s.model).isEmpty { out.append(.missingModel) }
        if keychainFailed || trimmed(apiKey ?? "").isEmpty { out.append(.missingAPIKey) }
        if keychainFailed { out.append(.keychainFailure) }
        return out
    }

    private static func forceOffIfNeeded(_ s: LLMSettings, hasIssues: Bool) -> LLMSettings {
        guard hasIssues else { return s }
        var out = s
        out.diaryEnabled = false
        out.thoughtsEnabled = false
        return out
    }
}

// MARK: - settings.json

/// LLM 设置存储（design.md `LLMSettingsStore`）。
public protocol LLMSettingsStore: Sendable {
    /// 读取设置；文件不存在或无法读取、无法解析时返回默认值（Requirement 11.1）。
    func load() -> LLMSettings
    /// 原子写入，返回是否成功；失败时原文件不变。
    @discardableResult
    func save(_ s: LLMSettings) -> Bool
}

/// 把设置写到某个目录下的 `settings.json`。不含 API Key（Requirement 11.3）。
/// 测试传入临时目录（Requirement 19.4）。
public struct FileLLMSettingsStore: LLMSettingsStore {
    public static let fileName = "settings.json"

    public let directory: URL
    public let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public func load() -> LLMSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(LLMSettings.self, from: data)
        else { return LLMSettings() }
        return s
    }

    @discardableResult
    public func save(_ s: LLMSettings) -> Bool {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(s)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - API Key

/// API Key 存储（design.md `SecretStore`）。应用层用钥匙串实现，测试用 `InMemorySecretStore`。
public protocol SecretStore: Sendable {
    /// 读取 API Key；没有保存时为 `.success(nil)`。
    func readAPIKey() -> Result<String?, SecretStoreError>
    /// 写入 API Key；nil 或空串表示删除。失败时不改存到别处（Requirement 11.9）。
    func writeAPIKey(_ key: String?) -> Result<Void, SecretStoreError>
}

/// 测试用的内存 API Key 存储。可设置 `failReads` / `failWrites` 模拟钥匙串失败。
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var _failReads = false
    private var _failWrites = false

    public init(apiKey: String? = nil) {
        self.key = (apiKey?.isEmpty ?? true) ? nil : apiKey
    }

    /// 为 true 时 `readAPIKey` 返回失败。
    public var failReads: Bool {
        get { lock.withLock { _failReads } }
        set { lock.withLock { _failReads = newValue } }
    }

    /// 为 true 时 `writeAPIKey` 返回失败且不改变已保存的值。
    public var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }

    /// 当前保存的值（不经过失败模拟），供测试断言。
    public var storedAPIKey: String? { lock.withLock { key } }

    public func readAPIKey() -> Result<String?, SecretStoreError> {
        lock.withLock {
            _failReads ? .failure(.operationFailed(status: -1)) : .success(key)
        }
    }

    public func writeAPIKey(_ newKey: String?) -> Result<Void, SecretStoreError> {
        lock.withLock {
            if _failWrites { return .failure(.operationFailed(status: -1)) }
            key = (newKey?.isEmpty ?? true) ? nil : newKey
            return .success(())
        }
    }
}
