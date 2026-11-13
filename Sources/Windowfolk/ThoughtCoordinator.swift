import Foundation
import WindowfolkCore

/// 在 Game_Loop 之外执行 Thought 请求（design.md「线程模型」，Requirement 12.5、14.1、14.10）。
///
/// - `@MainActor`：请求队列、结果队列和进行中的 Task 都只在主线程上读写，与 `GameLoop` 相同。
/// - 每个 `ThoughtRequest` 启动一个 `Task`，在其中 `await client.complete(...)`；`step` 从不等待它。
///   结果回到主线程后排队，下一帧由 `GameLoop` 经 `FrameInput.thoughtResults` 交给 `step`。
/// - 只有「小心思」打开且设置合法（`LLMSettingsModel.thoughtsConfig` 非 nil）时才调用 `LLMClient`；
///   否则丢弃请求，不建立任何网络连接（Requirement 11.10、12.6）。
/// - 「小心思」被关闭（或设置变得不完整）时取消进行中的 Task，并丢弃它们之后返回的任何结果（Requirement 14.10）。
///   紧接着的一帧 `thoughtsEnabled` 必为 false，即使在两帧之间又被打开：Core 借此清除进行中状态和显示中的
///   Thought，不会一直等一个已被取消的请求（Requirement 14.5、14.9）。
@MainActor
final class ThoughtCoordinator {
    /// 下一帧交给 `FrameInput` 的两项。
    struct FrameState {
        var thoughtsEnabled: Bool
        var thoughtResults: [(UInt64, ThoughtResult)]
    }

    private let client: any LLMClient
    /// 当前的请求配置；「小心思」关闭或设置不合法时为 nil。
    private let currentConfig: @MainActor () -> LLMRequestConfig?

    /// 进行中的请求，按请求 id。
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    /// 已回到主线程、等待下一帧送入的结果，按返回顺序。
    private var results: [(UInt64, ThoughtResult)] = []
    /// 每次取消加一；Task 完成时代数不同则丢弃结果。
    private var generation: UInt64 = 0
    /// 上次检查时是否生效，用于识别「打开 → 关闭」。
    private var wasEnabled: Bool
    /// 自上一帧以来发生过关闭：下一帧报告为关闭。
    private var disabledSinceLastFrame = false

    /// - `config`：每次分发请求和每帧开始时读取。
    init(client: any LLMClient, config: @escaping @MainActor () -> LLMRequestConfig?) {
        self.client = client
        self.currentConfig = config
        self.wasEnabled = config() != nil
    }

    /// 从 `LLMSettingsModel` 读取配置，并在设置变化时立即检查是否被关闭。
    convenience init(client: any LLMClient, settings: LLMSettingsModel) {
        self.init(client: client) { [weak settings] in settings?.thoughtsConfig }
        settings.addChangeHandler { [weak self] _ in
            self?.settingsChanged()
        }
    }

    /// 进行中的请求数（调试与断言用）。
    var inFlightCount: Int { tasks.count }

    /// 设置变化后调用：从生效变为不生效时取消全部进行中的请求。
    func settingsChanged() {
        let enabled = currentConfig() != nil
        if wasEnabled, !enabled { cancelAll() }
        wasEnabled = enabled
    }

    /// 每帧 `step` 之前调用一次：本帧的 `thoughtsEnabled`，以及自上一帧以来回到主线程的结果。
    func takeFrameState() -> FrameState {
        // 没有经过 change handler 的变化（例如直接构造时传入的闭包）在这里补上检查。
        settingsChanged()
        let enabled = wasEnabled && !disabledSinceLastFrame
        disabledSinceLastFrame = false
        let out = enabled ? results : []
        results.removeAll()
        return FrameState(thoughtsEnabled: enabled, thoughtResults: out)
    }

    /// 把 `StepOutput.thoughtRequests` 交给 `LLMClient`。不生效时丢弃，不发起网络请求。
    func dispatch(_ requests: [ThoughtRequest]) {
        guard !requests.isEmpty else { return }
        guard let config = currentConfig() else {
            // 设置在 step 与分发之间不会变化（同一帧、同一线程）；万一不生效，就让下一帧报告关闭，
            // Core 随之清除进行中状态，不会一直等这个被丢弃的请求。
            disabledSinceLastFrame = true
            return
        }
        for request in requests where tasks[request.id] == nil {
            start(request, config: config)
        }
    }

    /// 取消全部进行中的请求并丢弃尚未送入的结果；下一帧报告为关闭。
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        results.removeAll()
        generation &+= 1
        disabledSinceLastFrame = true
    }

    // MARK: - 内部

    private func start(_ request: ThoughtRequest, config: LLMRequestConfig) {
        let client = self.client
        let payload = request.payload
        let id = request.id
        let gen = generation
        tasks[id] = Task { [weak self] in
            // `complete` 是非隔离的 async 方法：网络等待不占主线程，Game_Loop 照常运行（Requirement 12.5）。
            let result = await client.complete(payload, config: config)
            self?.finish(id: id, generation: gen, result: result)
        }
    }

    private func finish(id: UInt64, generation gen: UInt64, result: LLMResult) {
        // 已被取消（关闭「小心思」）的请求：丢弃其后返回的任何文本（Requirement 14.10）。
        guard gen == generation, tasks.removeValue(forKey: id) != nil else { return }
        switch result {
        case .success(let text): results.append((id, .text(text)))
        case .failure: results.append((id, .failure))
        }
    }
}
