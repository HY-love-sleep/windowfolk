import Foundation

// MARK: - 请求配置与失败

/// 一次 LLM 请求所需的配置。只由 `LLMSettingsValidation.config` 在设置合法时构造。
///
/// API Key 只存在于钥匙串和这个值里（Requirement 11.3、15.7）。为避免 Key 被打进日志：
/// - 不实现 `Codable`，在类型上无法被编码进 `settings.json`、`world.json` 或事件记录；
/// - `description`、`debugDescription` 和 `customMirror`（`dump` 使用）都把 Key 显示为 `***`。
public struct LLMRequestConfig: Hashable, Sendable {
    public var endpoint: URL
    public var model: String
    public var apiKey: String

    public init(endpoint: URL, model: String, apiKey: String) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
    }
}

extension LLMRequestConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "LLMRequestConfig(endpoint: \(endpoint.absoluteString), model: \(model), apiKey: ***)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "endpoint": endpoint.absoluteString, "model": model, "apiKey": "***",
        ], displayStyle: .struct)
    }
}

/// LLM 请求失败的原因。所有失败都不重试，只交给调用方的回退规则（Requirement 12.3、13.7、14.5）。
public enum LLMFailure: Hashable, Sendable, Error {
    /// 超过 LLM_Request_Timeout 仍未返回。
    case timeout
    /// HTTP 状态码不在 200 至 299。
    case httpStatus(Int)
    /// 返回的文本为空或只含空白。
    case emptyText
    /// 网络层错误（无法连接、TLS 失败、请求被取消等）。
    case transport
    /// 响应体无法解析出文本。
    case invalidResponse
}

/// LLM 请求的结果：成功时为返回的文本。
public typealias LLMResult = Result<String, LLMFailure>

// MARK: - 客户端协议

/// 访问 LLM 服务的唯一入口（Requirement 19.2）。
///
/// 应用层提供 `URLSessionLLMClient`，测试使用 `FakeLLMClient`。实现必须自己处理超时，
/// 并把结果交给 `LLMTimeout.validate`，因此调用方拿到的 `.success` 一定是非空白文本。
/// 调用发生在 Game_Loop 之外的 Task 中，`WorldEngine.step` 从不等待它（Requirement 12.5）。
public protocol LLMClient: Sendable {
    func complete(_ payload: PromptPayload, config: LLMRequestConfig) async -> LLMResult
}

// MARK: - 超时与校验

public enum LLMTimeout {
    /// 让 `op` 与 `Task.sleep(for: timeout)` 竞争，先完成者胜出，另一个被取消（Requirement 12.3、12.4）。
    ///
    /// 超时返回 `.failure(.timeout)`。`op` 应响应 Task 取消（`URLSession` 的 async 接口会响应），
    /// 否则任务组要等它自行结束才返回。外层 Task 被取消时两个子任务都会被取消。
    public static func run(
        _ timeout: Duration, _ op: @Sendable @escaping () async -> LLMResult
    ) async -> LLMResult {
        await withTaskGroup(of: LLMResult.self) { group in
            group.addTask { await op() }
            group.addTask {
                // 被取消（op 先完成或外层取消）时 sleep 立即结束；此时这个结果不会被采用或无关紧要。
                try? await Task.sleep(for: timeout)
                return .failure(.timeout)
            }
            let first = await group.next() ?? .failure(.timeout)
            group.cancelAll()
            return first
        }
    }

    /// 空文本和只含空白的文本判为 `.emptyText`；其他成功原样保留；失败保持不变（Requirement 12.3）。
    public static func validate(_ r: LLMResult) -> LLMResult {
        switch r {
        case .success(let s):
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .failure(.emptyText) : r
        case .failure:
            return r
        }
    }
}

// MARK: - Chat Completions 编解码

/// OpenAI 兼容 Chat Completions 的请求构造与响应解析（design.md「Core：LLM」，Requirement 12.3、12.7）。
///
/// 纯函数，不发起网络请求。应用层的 `URLSessionLLMClient` 用它构造请求并解释响应，
/// 因此请求格式和失败判定可以在 Core 测试中覆盖。
public enum ChatCompletions {
    struct Message: Codable, Hashable {
        var role: String
        var content: String
    }

    struct RequestBody: Codable, Hashable {
        var model: String
        var messages: [Message]
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct ResponseMessage: Decodable { var content: String? }
            var message: ResponseMessage
        }
        var choices: [Choice]
    }

    /// 请求体 `{"messages":[{"content","role"}...],"model"}`，键排序。只含 `model` 与 `payload.messages()`，不含 API Key。
    public static func requestBody(_ payload: PromptPayload, model: String) throws -> Data {
        let body = RequestBody(
            model: model,
            messages: payload.messages().map { Message(role: $0.role, content: $0.content) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(body)
    }

    /// `POST` 到 `config.endpoint`。API Key 只出现在 `Authorization: Bearer` 请求头里（Requirement 12.7）。
    public static func makeRequest(_ payload: PromptPayload, config: LLMRequestConfig) throws -> URLRequest {
        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try requestBody(payload, model: config.model)
        return req
    }

    /// 状态码不在 200 至 299 返回 `.httpStatus`；取不到 `choices[0].message.content` 返回 `.invalidResponse`；
    /// 文本再经过 `LLMTimeout.validate`（空白文本为 `.emptyText`）。
    public static func parseResponse(statusCode: Int, data: Data) -> LLMResult {
        guard (200...299).contains(statusCode) else { return .failure(.httpStatus(statusCode)) }
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = body.choices.first?.message.content
        else { return .failure(.invalidResponse) }
        return LLMTimeout.validate(.success(content))
    }
}

// MARK: - 测试替身

/// 脚本化的 LLM 客户端（Requirement 19.2）。不建立任何网络连接。
///
/// 按脚本依次返回结果，用完后重复最后一项；脚本为空时每次返回 `.failure(.transport)`。
/// `.timeout` 直接返回 `.failure(.timeout)`，不实际等待。`.text` 的结果经过
/// `LLMTimeout.validate`，与真实客户端的约定一致（空白文本得到 `.emptyText`）。
public actor FakeLLMClient: LLMClient {
    public enum Script: Hashable, Sendable {
        case text(String)
        case failure(LLMFailure)
        case timeout
    }

    private let script: [Script]
    /// 已收到的请求次数。
    public private(set) var requestCount: Int = 0
    /// 按顺序记录的每次请求的 Payload。
    public private(set) var payloads: [PromptPayload] = []

    public init(_ script: [Script]) {
        self.script = script
    }

    public func complete(_ payload: PromptPayload, config: LLMRequestConfig) async -> LLMResult {
        let index = requestCount
        requestCount += 1
        payloads.append(payload)
        guard let last = script.last else { return .failure(.transport) }
        let step = index < script.count ? script[index] : last
        switch step {
        case .text(let s): return LLMTimeout.validate(.success(s))
        case .failure(let f): return .failure(f)
        case .timeout: return .failure(.timeout)
        }
    }
}
