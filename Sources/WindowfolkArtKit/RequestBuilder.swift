import Foundation
import WindowfolkCore

// 图像 API 请求构造与响应解析（design.md「生成计划与请求构造」「Error Handling」，
// Requirements 3.1、3.3、3.4、3.7）。纯逻辑：不发网络，不接触 API Key。
// Key 只在 IO 层的 Transport 构造 `Authorization` 头时出现。

/// 一次图像生成请求的描述。每张候选图单独一个请求，固定 `n=1`。
public struct ImageRequest: Hashable, Sendable {
    public enum Endpoint: Hashable, Sendable {
        /// `POST /v1/images/generations`，JSON 请求体；无参考图时使用。
        case generations
        /// `POST /v1/images/edits`，multipart 请求体；有参考图时使用。
        case edits

        /// 相对 API 根地址的路径。
        public var path: String {
            switch self {
            case .generations: return "/v1/images/generations"
            case .edits: return "/v1/images/edits"
            }
        }
    }

    public var endpoint: Endpoint
    public var model: String
    public var prompt: String
    public var size: PixelSize
    /// 相对仓库根目录的参考图路径，顺序与清单相同。
    public var references: [String]

    // 固定参数（R3.4：透明背景需要配合 PNG 输出）。
    public static let background = "transparent"
    public static let outputFormat = "png"
    public static let n = 1
    public static let quality = "high"

    public init(endpoint: Endpoint, model: String, prompt: String, size: PixelSize, references: [String]) {
        self.endpoint = endpoint
        self.model = model
        self.prompt = prompt
        self.size = size
        self.references = references
    }
}

/// 图像请求失败的原因。定义在 Kit 中，供 IO 层的 Transport 与生成流程复用。
public enum GenerationFailure: Error, Hashable, Sendable {
    /// 其他 HTTP 错误；`message` 已经过 Redactor。
    case http(status: Int, message: String)
    /// 模型不可用（HTTP 404 或错误码 `model_not_found`）；关联值为模型名，未知时为空串。
    case modelUnavailable(String)
    /// 鉴权失败（HTTP 401）。不保留服务器原文，避免回显 Key。
    case unauthorized
    /// 180 秒内没有返回结果。
    case timeout
    /// 返回内容无法解码为图像。
    case undecodable
    /// 网络层错误；消息由调用方脱敏。
    case transport(String)

    /// 写入失败报告的原因文字。
    public var reason: String {
        switch self {
        case .http(let status, let message):
            return message.isEmpty ? "HTTP \(status)" : "HTTP \(status)：\(message)"
        case .modelUnavailable(let model):
            let name = model.isEmpty ? "" : " \(model) "
            return "模型\(name)不可用，可用 \(ModelName.variable) 指定其他模型，例如 gpt-image-2.5-sunburst"
        case .unauthorized:
            return "API Key 无效"
        case .timeout:
            return "请求超时（180 秒）"
        case .undecodable:
            return "返回内容无法解码为图像"
        case .transport(let message):
            return "网络错误：\(message)"
        }
    }

    /// 出现这类失败后，剩余请求不再发送，直接记为同一原因的失败（design.md Error Handling）。
    public var stopsRemainingRequests: Bool {
        switch self {
        case .modelUnavailable, .unauthorized: return true
        case .http, .timeout, .undecodable, .transport: return false
        }
    }
}

public enum RequestBuilder {
    /// 为条目构造请求：有参考图用 edits，否则用 generations。
    /// `model` 去掉首尾空白后为空时使用 `ModelName.fallback`（R3.3）。
    public static func request(for entry: PromptEntry, prompt: String, model: String) -> ImageRequest {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return ImageRequest(
            endpoint: entry.references.isEmpty ? .generations : .edits,
            model: trimmed.isEmpty ? ModelName.fallback : trimmed,
            prompt: prompt,
            size: entry.canvas,
            references: entry.references
        )
    }

    /// 请求体对应的 `Content-Type`。
    public static func contentType(_ r: ImageRequest, boundary: String) -> String {
        switch r.endpoint {
        case .generations: return "application/json"
        case .edits: return "multipart/form-data; boundary=\(boundary)"
        }
    }

    /// generations：JSON 体（键排序，输出稳定）；edits：multipart 体，每张参考图一个 `image[]` 部分。
    /// `referenceData[i]` 对应 `r.references[i]`；`boundary` 只用于 edits。
    public static func body(_ r: ImageRequest, referenceData: [Data], boundary: String) -> Data {
        switch r.endpoint {
        case .generations:
            return jsonBody(r)
        case .edits:
            return multipartBody(r, referenceData: referenceData, boundary: boundary)
        }
    }

    /// 只看响应体的解析：取 `data[0].b64_json`；含 `error` 对象时按错误码映射。
    public static func decodeResponse(_ data: Data) -> Result<Data, GenerationFailure> {
        decodeResponse(data, status: 200, model: "", secret: "")
    }

    /// 结合 HTTP 状态码解析响应。
    /// - 401 → `unauthorized`；404 或错误码 `model_not_found` → `modelUnavailable(model)`；
    /// - 其他非 2xx 或含 `error` 对象 → `http`，消息只取 `error.message` 并经 `Redactor` 脱敏；
    /// - 2xx 时 `data[0].b64_json` 缺失或不是合法 base64 → `undecodable`。
    public static func decodeResponse(
        _ data: Data, status: Int, model: String, secret: String
    ) -> Result<Data, GenerationFailure> {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String

        if status == 401 || code == "invalid_api_key" {
            return .failure(.unauthorized)
        }
        if status == 404 || code == "model_not_found" {
            return .failure(.modelUnavailable(model))
        }
        if !(200..<300).contains(status) || error != nil {
            let message = (error?["message"] as? String) ?? ""
            let cleaned = Redactor.redact(message, secret: secret)
            return .failure(.http(status: status, message: cleaned))
        }

        guard let items = object?["data"] as? [[String: Any]],
              let encoded = items.first?["b64_json"] as? String,
              let image = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !image.isEmpty else {
            return .failure(.undecodable)
        }
        return .success(image)
    }

    // MARK: - 请求体

    /// 两种接口共用的文本字段，顺序固定。
    private static func fields(_ r: ImageRequest) -> [(String, String)] {
        [
            ("model", r.model),
            ("prompt", r.prompt),
            ("size", r.size.canvasString),
            ("background", ImageRequest.background),
            ("output_format", ImageRequest.outputFormat),
            ("quality", ImageRequest.quality),
            ("n", String(ImageRequest.n)),
        ]
    }

    private static func jsonBody(_ r: ImageRequest) -> Data {
        let object: [String: Any] = [
            "model": r.model,
            "prompt": r.prompt,
            "size": r.size.canvasString,
            "background": ImageRequest.background,
            "output_format": ImageRequest.outputFormat,
            "quality": ImageRequest.quality,
            "n": ImageRequest.n,
        ]
        // 字典只含字符串与整数，序列化不会失败。
        return (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
    }

    private static func multipartBody(_ r: ImageRequest, referenceData: [Data], boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }

        for (name, value) in fields(r) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }
        for (index, data) in referenceData.enumerated() {
            let path = index < r.references.count ? r.references[index] : ""
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"image[]\"; filename=\"\(fileName(path, index: index))\"\r\n")
            append("Content-Type: image/png\r\n\r\n")
            body.append(data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    /// 参考图路径的最后一段，去掉会破坏头部的字符；为空时用 `reference_<n>.png`。
    private static func fileName(_ path: String, index: Int) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        let safe = last.filter { $0 != "\"" && $0 != "\r" && $0 != "\n" && $0 != "\\" }
        return safe.isEmpty ? "reference_\(index + 1).png" : safe
    }
}
