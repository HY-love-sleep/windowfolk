import Foundation
import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// RequestBuilder 的属性测试与示例（任务 5.4）。清单生成器见 Support/ManifestGen.swift。
@Suite struct RequestBuilderTests {

    // Feature: 美术, Property 5: 请求内容完整
    /// *For any* 条目、环境变量 `WINDOWFOLK_IMAGE_MODEL` 的任意取值（含未设置、空串和纯空白），构造出的请求：
    /// 模型名在取值去空白后为空时为 `gpt-image-2.5-flare`，否则为原值；提示词等于 `compose` 结果；
    /// 尺寸为条目画布；`background` 为 `transparent`；参考图非空时使用 edits 接口且请求体中每张参考图
    /// 恰好一个 `image[]` 部分，为空时使用 generations 接口。请求体不含 API Key。
    ///
    /// **Validates: Requirements 3.1, 3.3, 3.4**
    @Test func requestContentIsComplete() async {
        await propertyCheck(
            count: 100,
            input: Gen.manifest, modelSetting, secretKey, Gen<UInt8>.uint8().array(of: 1...48)
        ) { manifest, setting, secret, imageSeed in
            let env = setting.environment
            let expectedModel = setting.expectedModel
            #expect(ModelName.resolve(env) == expectedModel, "ModelName.resolve 结果不符：\(setting)")

            for (index, entry) in manifest.entries.enumerated() {
                guard let prompt = PromptComposer.compose(manifest, key: entry.key) else {
                    Issue.record("\(entry.key)：compose 返回 nil")
                    continue
                }
                let request = RequestBuilder.request(for: entry, prompt: prompt, model: ModelName.resolve(env))
                // 直接传入原始取值（未设置记为空串）也应得到同样的模型名。
                let direct = RequestBuilder.request(for: entry, prompt: prompt, model: setting.rawValue ?? "")
                #expect(direct == request, "\(entry.key)：直接传入原始模型取值的结果不同")

                #expect(request.model == expectedModel, "\(entry.key)：模型名 \(request.model) ≠ \(expectedModel)")
                #expect(request.prompt == prompt, "\(entry.key)：提示词不等于 compose 结果")
                #expect(request.size == entry.canvas, "\(entry.key)：尺寸不等于条目画布")
                #expect(request.references == entry.references, "\(entry.key)：参考图与条目不同")

                let boundary = "windowfolk-boundary-\(index)-\(imageSeed.count)"
                // 每张参考图一段不同的字节，便于逐段核对。
                let referenceData = entry.references.indices.map { i in
                    Data(imageSeed.map { $0 &+ UInt8(truncatingIfNeeded: i) })
                }
                let body = RequestBuilder.body(request, referenceData: referenceData, boundary: boundary)
                #expect(!contains(Array(body), Array(secret.utf8)), "\(entry.key)：请求体包含 API Key")

                if entry.references.isEmpty {
                    #expect(request.endpoint == .generations, "\(entry.key)：无参考图时应使用 generations")
                    #expect(RequestBuilder.contentType(request, boundary: boundary) == "application/json")
                    checkJSONBody(body, entry: entry, prompt: prompt, model: expectedModel)
                } else {
                    #expect(request.endpoint == .edits, "\(entry.key)：有参考图时应使用 edits")
                    #expect(RequestBuilder.contentType(request, boundary: boundary)
                            == "multipart/form-data; boundary=\(boundary)")
                    checkMultipartBody(
                        body, boundary: boundary, entry: entry, prompt: prompt,
                        model: expectedModel, referenceData: referenceData
                    )
                }
            }
        }
    }

    // MARK: - 示例：响应解析

    static let secret = "sk-proj-AbCdEfGhIjKlMnOpQrStUv0123456789"

    @Test func successReturnsDecodedImage() throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let body = json(["data": [["b64_json": image.base64EncodedString()]]])
        let result = RequestBuilder.decodeResponse(body, status: 200, model: "m", secret: Self.secret)
        #expect(result == .success(image))
    }

    @Test func missingOrInvalidImageIsUndecodable() {
        for body in [
            json(["data": []]),
            json(["data": [["url": "https://example.com/a.png"]]]),
            json(["data": [["b64_json": ""]]]),
            Data("not json".utf8),
        ] {
            #expect(RequestBuilder.decodeResponse(body, status: 200, model: "m", secret: Self.secret)
                    == .failure(.undecodable))
        }
    }

    @Test func unauthorizedDoesNotEchoKey() {
        let body = json(["error": ["message": "Incorrect API key provided: \(Self.secret)", "code": "invalid_api_key"]])
        for status in [401, 200, 400] {
            let result = RequestBuilder.decodeResponse(body, status: status, model: "m", secret: Self.secret)
            #expect(result == .failure(.unauthorized), "status \(status)")
        }
        #expect(!GenerationFailure.unauthorized.reason.contains(Self.secret))
    }

    @Test func modelNotFoundMapsToModelUnavailable() {
        let coded = json(["error": ["message": "no such model", "code": "model_not_found"]])
        #expect(RequestBuilder.decodeResponse(coded, status: 400, model: "gpt-x", secret: Self.secret)
                == .failure(.modelUnavailable("gpt-x")))
        #expect(RequestBuilder.decodeResponse(Data(), status: 404, model: "gpt-y", secret: Self.secret)
                == .failure(.modelUnavailable("gpt-y")))
        #expect(GenerationFailure.modelUnavailable("gpt-x").reason.contains("gpt-x"))
    }

    @Test func otherErrorsAreRedactedHTTPFailures() {
        let leak = "upstream failed for key \(Self.secret) (partial \(Self.secret.prefix(12))***)"
        let body = json(["error": ["message": leak, "code": "server_error"]])
        for status in [500, 429, 200] {
            let result = RequestBuilder.decodeResponse(body, status: status, model: "m", secret: Self.secret)
            guard case .failure(.http(let code, let message)) = result else {
                Issue.record("status \(status)：应为 http 失败，实际 \(result)")
                continue
            }
            #expect(code == status)
            #expect(!message.contains(Self.secret), "status \(status)：错误信息含完整 Key")
            #expect(!message.contains(String(Self.secret.prefix(12))), "status \(status)：错误信息含 Key 片段")
            #expect(!GenerationFailure.http(status: code, message: message).reason.contains(Self.secret))
        }
        // 非 2xx 且没有 error 对象：消息为空。
        #expect(RequestBuilder.decodeResponse(Data("oops".utf8), status: 502, model: "m", secret: Self.secret)
                == .failure(.http(status: 502, message: "")))
    }

    // MARK: - 示例：请求构造

    @Test func blankModelFallsBackAndFilenameIsSanitized() throws {
        let entry = PromptEntry(
            key: "k", description: "d", frames: 1, canvas: PixelSize(width: 1536, height: 1024),
            references: ["art/references/[draft] \"v2\".png", ""]
        )
        let request = RequestBuilder.request(for: entry, prompt: "P", model: " \t\n ")
        #expect(request.model == ModelName.fallback)
        #expect(request.endpoint == .edits)
        let body = RequestBuilder.body(request, referenceData: [Data([1]), Data([2])], boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"image[]\"; filename=\"[draft] v2.png\"\r\n"))
        #expect(text.contains("name=\"image[]\"; filename=\"reference_2.png\"\r\n"))
        #expect(text.contains("name=\"size\"\r\n\r\n1536x1024\r\n"))
    }

    /// 回归：提示词以 U+FEFF 开头时，generations 请求体逐标量保留原文。
    @Test func jsonBodyKeepsLeadingByteOrderMark() throws {
        let entry = PromptEntry(key: "k", description: "d", frames: 1, canvas: PixelSize(width: 1024, height: 1024), references: [])
        let prompt = "\u{FEFF}ß中文\u{FEFF}"
        let request = RequestBuilder.request(for: entry, prompt: prompt, model: "m")
        let body = RequestBuilder.body(request, referenceData: [], boundary: "B")
        let object = try #require(try ManifestParser.jsonObject(from: body) as? [String: Any])
        let decoded = try #require(object["prompt"] as? String)
        #expect(Array(decoded.unicodeScalars) == Array(prompt.unicodeScalars))
        #expect(String(decoding: body, as: UTF8.self).contains("\"prompt\":\"\(prompt)\""))
    }
}

// MARK: - 生成器

/// Model_Variable 的取值。
fileprivate enum ModelSetting: Sendable, CustomStringConvertible {
    case unset
    /// 去空白后为空的取值（空串或纯空白）。
    case blank(String)
    /// 非空模型名，前后可能带空白。
    case named(padding: String, name: String, trailing: String)

    var rawValue: String? {
        switch self {
        case .unset: return nil
        case .blank(let value): return value
        case .named(let padding, let name, let trailing): return padding + name + trailing
        }
    }

    var environment: [String: String] {
        var env = ["OPENAI_API_KEY": "unused", "PATH": "/usr/bin"]
        if let value = rawValue { env[ModelName.variable] = value }
        return env
    }

    var expectedModel: String {
        switch self {
        case .unset, .blank: return ModelName.fallback
        case .named(_, let name, _): return name
        }
    }

    var description: String { "ModelSetting(\(rawValue.map { String(reflecting: $0) } ?? "unset"))" }
}

fileprivate let whitespacePool = ["", " ", "  ", "\t", "\n", "\r\n", " \t\n ", "\u{3000}", "\u{00A0}"]
fileprivate let modelNamePool = [
    "gpt-image-2.5-sunburst", "gpt-image-2.5-flare", "gpt-image-1", "my model", "模型-x", "a",
]

fileprivate var modelSetting: Generator<ModelSetting, some SendableSequenceType> {
    zip(
        Gen<Int>.int(in: 0...3),
        Gen<String?>.element(of: whitespacePool).map { $0! }.array(of: 0...3).map { $0.joined() },
        Gen<String?>.element(of: modelNamePool).map { $0! },
        Gen<String?>.element(of: whitespacePool).map { $0! }
    ).map { kind, blank, name, trailing -> ModelSetting in
        switch kind {
        case 0: return .unset
        case 1: return .blank(blank)
        default: return .named(padding: blank, name: name, trailing: trailing)
        }
    }
}

fileprivate let keyAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

/// `sk-` 开头的随机 API Key。
fileprivate var secretKey: Generator<String, some SendableSequenceType> {
    Gen<UInt8>.uint8().array(of: 20...48).map { bytes in
        "sk-" + String(bytes.map { keyAlphabet[Int($0) % keyAlphabet.count] })
    }
}

// MARK: - 请求体核对

/// 期望的文本字段（名、值），顺序与 multipart 体一致。
fileprivate func expectedFields(entry: PromptEntry, prompt: String, model: String) -> [(String, String)] {
    [
        ("model", model),
        ("prompt", prompt),
        ("size", "\(entry.canvas.width)x\(entry.canvas.height)"),
        ("background", "transparent"),
        ("output_format", "png"),
        ("quality", "high"),
        ("n", "1"),
    ]
}

fileprivate func checkJSONBody(_ body: Data, entry: PromptEntry, prompt: String, model: String) {
    // JSONSerialization.jsonObject 会删掉字符串开头的 U+FEFF（请求体字节里仍保留），
    // 提示词以 U+FEFF 开头时会误报，所以用 JSONDecoder 读出的树核对取值。
    guard let object = (try? ManifestParser.jsonObject(from: body)) as? [String: Any] else {
        Issue.record("\(entry.key)：generations 请求体不是 JSON 对象")
        return
    }
    let expected = expectedFields(entry: entry, prompt: prompt, model: model)
    #expect(Set(object.keys) == Set(expected.map(\.0)), "\(entry.key)：JSON 键集合不符：\(object.keys.sorted())")
    for (name, value) in expected {
        if name == "n" {
            #expect((object[name] as? Int) == 1, "\(entry.key)：n 应为整数 1")
        } else {
            #expect((object[name] as? String) == value, "\(entry.key)：JSON 字段 \(name) 不符")
        }
    }
    #expect(object["image"] == nil && object["image[]"] == nil, "\(entry.key)：generations 不应带图像")
}

fileprivate func checkMultipartBody(
    _ body: Data, boundary: String, entry: PromptEntry, prompt: String,
    model: String, referenceData: [Data]
) {
    guard let parts = multipartParts(Array(body), boundary: boundary) else {
        Issue.record("\(entry.key)：multipart 体结构不合法")
        return
    }
    let fields = expectedFields(entry: entry, prompt: prompt, model: model)
    let textParts = parts.filter { !$0.headers.contains("name=\"image[]\"") }
    let imageParts = parts.filter { $0.headers.contains("name=\"image[]\"") }

    #expect(textParts.count == fields.count, "\(entry.key)：文本字段数 \(textParts.count) ≠ \(fields.count)")
    for (part, (name, value)) in Swift.zip(textParts, fields) {
        #expect(part.headers == "Content-Disposition: form-data; name=\"\(name)\"", "\(entry.key)：字段 \(name) 头部不符")
        #expect(part.content == Array(value.utf8), "\(entry.key)：字段 \(name) 值不符")
    }

    // 每张参考图恰好一个 image[] 部分，顺序与内容一致。
    #expect(imageParts.count == entry.references.count,
            "\(entry.key)：image[] 部分 \(imageParts.count) ≠ 参考图 \(entry.references.count)")
    for (i, (part, data)) in Swift.zip(imageParts, referenceData).enumerated() {
        #expect(part.content == Array(data), "\(entry.key)：第 \(i + 1) 张参考图内容不符")
        let lines = part.headers.components(separatedBy: "\r\n")
        #expect(lines.count == 2 && lines.last == "Content-Type: image/png", "\(entry.key)：第 \(i + 1) 张参考图头部不符")
        let prefix = "Content-Disposition: form-data; name=\"image[]\"; filename=\""
        guard let first = lines.first, first.hasPrefix(prefix), first.hasSuffix("\"") else {
            Issue.record("\(entry.key)：第 \(i + 1) 张参考图 Content-Disposition 不符：\(part.headers)")
            continue
        }
        let filename = String(first.dropFirst(prefix.count).dropLast())
        #expect(!filename.isEmpty && !filename.contains("\""), "\(entry.key)：文件名含引号或为空：\(filename)")
        let last = entry.references[i].split(separator: "/").last.map(String.init) ?? ""
        let cleaned = last.filter { $0 != "\"" && $0 != "\r" && $0 != "\n" && $0 != "\\" }
        #expect(filename == (cleaned.isEmpty ? "reference_\(i + 1).png" : cleaned),
                "\(entry.key)：文件名 \(filename) 与参考图 \(entry.references[i]) 不对应")
    }
}

fileprivate struct Part {
    var headers: String
    var content: [UInt8]
}

/// 按 RFC 7578 切分 multipart 体：`--B\r\n` 头部 `\r\n\r\n` 内容，部分之间以 `\r\n--B` 分隔，
/// 以 `\r\n--B--\r\n` 结束。结构不合法时返回 nil。
fileprivate func multipartParts(_ body: [UInt8], boundary: String) -> [Part]? {
    let bytes = Array("\r\n".utf8) + body
    let delimiter = Array("\r\n--\(boundary)".utf8)
    let starts = occurrences(of: delimiter, in: bytes)
    guard starts.first == 0, let closing = starts.last,
          Array(bytes[(closing + delimiter.count)...]) == Array("--\r\n".utf8) else { return nil }

    var parts: [Part] = []
    for (start, end) in Swift.zip(starts, starts.dropFirst()) {
        let segment = Array(bytes[(start + delimiter.count)..<end])
        guard segment.starts(with: Array("\r\n".utf8)) else { return nil }
        let rest = Array(segment.dropFirst(2))
        let separator = Array("\r\n\r\n".utf8)
        guard let split = occurrences(of: separator, in: rest).first else { return nil }
        parts.append(Part(
            headers: String(decoding: rest[..<split], as: UTF8.self),
            content: Array(rest[(split + separator.count)...])
        ))
    }
    return parts
}

fileprivate func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
    guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
    var result: [Int] = []
    var i = 0
    while i <= haystack.count - needle.count {
        if haystack[i] == needle[0], haystack[i..<(i + needle.count)].elementsEqual(needle) {
            result.append(i)
            i += needle.count
        } else {
            i += 1
        }
    }
    return result
}

fileprivate func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    !occurrences(of: needle, in: haystack).isEmpty
}

fileprivate func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}
