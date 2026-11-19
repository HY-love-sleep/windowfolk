import Foundation
import WindowfolkArtKit

/// 通过 URLSession 调用 OpenAI Images API 的 `ImageTransport`（design.md「WindowfolkArtIO」，
/// Requirements 3.1、3.7、3.10）。
///
/// - 使用 ephemeral 会话：不写磁盘缓存，不保存 Cookie。
/// - 请求超时与资源超时都是 180 秒（R3.7）；超时映射为 `GenerationFailure.timeout`。
/// - API Key 只放进 `Authorization: Bearer` 头（R3.10）。
/// - 只跟随同源（同协议、同主机、同端口）的重定向；跨主机重定向被拒绝，
///   避免请求连同 Key 发到其他地址。被拒绝的 3xx 响应按 HTTP 错误处理。
/// - 响应交给 `RequestBuilder.decodeResponse(_:status:model:secret:)` 解析：
///   服务器错误只取 `error.message` 并经 `Redactor` 脱敏。网络层错误信息同样脱敏。
/// - 不重试，不写日志。
public final class URLSessionTransport: ImageTransport, Sendable {
    /// 默认 API 根地址。
    public static let defaultBaseURL = URL(string: "https://api.openai.com")!
    /// 单个请求的超时秒数（R3.7）。
    public static let timeout: TimeInterval = 180

    private let baseURL: URL?
    private let session: URLSession
    private let redirectGuard = SameOriginRedirectGuard()

    public init(baseURL: URL? = URLSessionTransport.defaultBaseURL) {
        self.baseURL = baseURL
        self.session = URLSession(configuration: Self.makeConfiguration())
    }

    /// 自定义 OpenAI 兼容服务可传入服务根地址或以 /v1 结尾的 API 地址。
    /// 无效配置返回 nil，调用方必须拒绝发请求，避免密钥误发到默认服务。
    public static func baseURL(from variables: [String: String]) -> URL? {
        guard let value = variables["WINDOWFOLK_IMAGE_BASE_URL"], !value.isEmpty else {
            return defaultBaseURL
        }
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else { return nil }
        return url.lastPathComponent == "v1" ? url.deletingLastPathComponent() : url
    }

    /// 会话配置：ephemeral、不缓存、不存 Cookie、请求与资源超时都为 180 秒。
    static func makeConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        return cfg
    }

    /// 构造 `URLRequest`：`POST <baseURL><endpoint.path>`，Key 只出现在 `Authorization` 头。
    static func makeURLRequest(
        _ request: ImageRequest, body: Data, contentType: String, apiKey: String, baseURL: URL
    ) -> URLRequest {
        var url = baseURL
        for component in request.endpoint.path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body
        return urlRequest
    }

    public func send(
        _ request: ImageRequest, body: Data, contentType: String, apiKey: String
    ) async -> Result<Data, GenerationFailure> {
        guard let baseURL else {
            return .failure(.transport("WINDOWFOLK_IMAGE_BASE_URL 不是有效的 HTTPS 地址"))
        }
        let urlRequest = Self.makeURLRequest(
            request, body: body, contentType: contentType, apiKey: apiKey, baseURL: baseURL)
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: redirectGuard)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("响应不是 HTTP 响应"))
            }
            return RequestBuilder.decodeResponse(
                data, status: http.statusCode, model: request.model, secret: apiKey)
        } catch {
            return .failure(Self.failure(for: error, secret: apiKey))
        }
    }

    /// 把网络层错误映射为 `GenerationFailure`；文字经 `Redactor` 脱敏。
    static func failure(for error: Error, secret: String) -> GenerationFailure {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .cancelled:
                return .transport("请求已取消")
            default:
                break
            }
        }
        if error is CancellationError {
            return .transport("请求已取消")
        }
        let message = (error as NSError).localizedDescription
        return .transport(Redactor.redact(message, secret: secret))
    }

    /// 重定向目标与原请求同源（协议、主机、端口都相同）时才允许跟随。
    static func allowsRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target,
              let originalScheme = original.scheme?.lowercased(),
              let targetScheme = target.scheme?.lowercased(),
              let originalHost = original.host?.lowercased(),
              let targetHost = target.host?.lowercased() else {
            return false
        }
        return originalScheme == targetScheme
            && originalHost == targetHost
            && effectivePort(original, scheme: originalScheme) == effectivePort(target, scheme: targetScheme)
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// 拒绝跨源重定向的任务代理（R3.10）。返回 nil 时 URLSession 把 3xx 响应原样交回。
private final class SameOriginRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        let original = task.originalRequest?.url ?? response.url
        return URLSessionTransport.allowsRedirect(from: original, to: request.url) ? request : nil
    }
}
