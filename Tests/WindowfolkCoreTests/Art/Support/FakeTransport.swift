import Foundation
import WindowfolkArtIO
import WindowfolkArtKit

// 按脚本返回结果的 Transport（任务 11.3，design.md「Testing Strategy」）。
// 不发网络、不需要 API Key；记录每次调用的请求、请求体与 Content-Type，供断言使用。
//
// 脚本按调用顺序消费；脚本用完后返回 `fallback`（默认是一条传输错误）。
// `calls` 与 `callCount` 线程安全，可在 async 测试中读取。

final class FakeTransport: ImageTransport, @unchecked Sendable {
    /// 一次调用的结果。
    enum Outcome: Sendable {
        case success(Data)
        case failure(GenerationFailure)
    }

    /// 一次调用的记录。
    struct Call: Sendable {
        var request: ImageRequest
        var body: Data
        var contentType: String
    }

    private let lock = NSLock()
    private var pending: [Outcome]
    private var recorded: [Call] = []
    private let fallback: Outcome

    /// - Parameters:
    ///   - outcomes: 按调用顺序消费的结果。
    ///   - fallback: 脚本用完后返回的结果。
    init(_ outcomes: [Outcome], fallback: Outcome = .failure(.transport("脚本已用完"))) {
        self.pending = outcomes
        self.fallback = fallback
    }

    /// 全部成功的脚本。
    convenience init(successData: [Data]) {
        self.init(successData.map { .success($0) })
    }

    func send(
        _ request: ImageRequest, body: Data, contentType: String, apiKey: String
    ) async -> Result<Data, GenerationFailure> {
        let outcome = lock.withLock { () -> Outcome in
            recorded.append(Call(request: request, body: body, contentType: contentType))
            return pending.isEmpty ? fallback : pending.removeFirst()
        }

        switch outcome {
        case .success(let data): return .success(data)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// 到目前为止收到的全部调用，按调用顺序。
    var calls: [Call] {
        lock.withLock { recorded }
    }

    var callCount: Int {
        lock.withLock { recorded.count }
    }
}
