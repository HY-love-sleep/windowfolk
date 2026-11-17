import Foundation
import WindowfolkArtKit

/// 把一次图像请求发给图像 API 并返回解码后的 PNG 数据（design.md「WindowfolkArtIO」，
/// Requirements 3.1、3.7、3.10）。
///
/// - `body` 与 `contentType` 由 `RequestBuilder.body(_:referenceData:boundary:)` 和
///   `RequestBuilder.contentType(_:boundary:)` 生成，Transport 不改动。
/// - 成功时返回 `data[0].b64_json` 解码后的图像字节；失败时返回 `GenerationFailure`，
///   其中的文字都已经过 `Redactor` 脱敏。
/// - `apiKey` 只用于构造 `Authorization: Bearer` 头，不得写进返回值、日志或错误信息。
///
/// 正式实现是 `URLSessionTransport`；测试使用按脚本返回结果的 `FakeTransport`，不发网络。
public protocol ImageTransport: Sendable {
    func send(_ request: ImageRequest, body: Data, contentType: String, apiKey: String) async
        -> Result<Data, GenerationFailure>
}
