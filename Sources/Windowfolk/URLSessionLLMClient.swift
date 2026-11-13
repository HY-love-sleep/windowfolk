import Foundation
import WindowfolkCore

/// 通过 URLSession 访问 OpenAI 兼容 Chat Completions 服务的 LLM 客户端
/// （design.md「Core：LLM」，Requirement 12.3、12.7）。
///
/// - 请求由 `ChatCompletions.makeRequest` 构造：`POST` 到配置的端点 URL，API Key 只放在 `Authorization` 请求头。
/// - 不跟随重定向，避免请求（连同 API Key）被转发到配置之外的地址；3xx 响应按 `.httpStatus` 失败处理。
/// - 使用 ephemeral 会话：不写磁盘缓存，不保存 Cookie。
/// - 整体包在 `LLMTimeout.run(.seconds(15))` 里，超时后取消 URLSession 任务；结果经过 `validate`。不重试。
/// - 不写任何日志，API Key 不会出现在输出里。
final class URLSessionLLMClient: LLMClient, Sendable {
    static let requestTimeout: Duration = .seconds(15)

    private let session: URLSession
    private let redirectBlocker = RedirectBlocker()

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 15 秒总超时由 LLMTimeout.run 负责；这里只给 URLSession 一个不早于它的上限。
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 20
        session = URLSession(configuration: cfg)
    }

    func complete(_ payload: PromptPayload, config: LLMRequestConfig) async -> LLMResult {
        let session = self.session
        let blocker = redirectBlocker
        let result = await LLMTimeout.run(Self.requestTimeout) {
            guard let request = try? ChatCompletions.makeRequest(payload, config: config) else {
                return .failure(.transport)
            }
            do {
                let (data, response) = try await session.data(for: request, delegate: blocker)
                guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
                return ChatCompletions.parseResponse(statusCode: http.statusCode, data: data)
            } catch {
                return .failure(.transport)
            }
        }
        return LLMTimeout.validate(result)
    }
}

/// 拒绝所有 HTTP 重定向，只向配置的地址发送请求（Requirement 12.7）。
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
