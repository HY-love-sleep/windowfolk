import Foundation
import Observation

// Settings_Window 背后的设置模型（任务 15.2，Requirement 11.1、11.4–11.9）。
//
// 放在 Core 中，便于用临时目录和 `InMemorySecretStore` 测试编辑、校验、防抖保存和说明确认流程；
// 应用层的 `SettingsView` 只负责把这些状态画出来。GameLoop、ThoughtCoordinator、DiaryCoordinator
// 通过 `diaryConfig` / `thoughtsConfig` 读取当前配置，通过 `addChangeHandler` 得知变化（任务 15.4、15.6）。

/// Settings_Window 中的两个开关。
public enum LLMToggle: Hashable, Sendable, CaseIterable {
    /// 「日记使用 LLM」。
    case diary
    /// 「小心思」。
    case thoughts
}

/// 输入长度上限（Requirement 11.2），按 `Character` 计。
public enum LLMSettingsLimits {
    public static let endpoint = 2048
    public static let model = 128
    public static let apiKey = 512

    /// 截断到最多 `limit` 个字符。
    public static func truncate(_ s: String, to limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit)) : s
    }
}

/// Settings_Window 的界面文案（Requirement 11.5–11.9）。
public enum LLMSettingsText {
    public static func toggleTitle(_ t: LLMToggle) -> String {
        switch t {
        case .diary: "日记使用 LLM"
        case .thoughts: "小心思"
        }
    }

    /// 发送给 LLM 服务的内容，与 Requirement 12.1 的白名单一致。
    public static let disclosedItems = [
        "居民名字", "事件类型", "事件时间", "日期", "物件种类", "心愿种类", "心愿状态", "追逐结局", "花的生长阶段",
    ]

    public static func disclosureTitle(_ t: LLMToggle) -> String {
        "打开「\(toggleTitle(t))」前请确认"
    }

    /// 首次打开开关时的说明（Requirement 11.7）。
    public static let disclosureMessage =
        "发送给 LLM 服务的内容只有：" + disclosedItems.joined(separator: "、")
        + "。不包含窗口标题和应用名称。"

    public static let confirm = "确认"
    public static let cancel = "取消"

    /// 需补全的项目名称，按「服务地址、模型名、API Key」顺序，不重复（Requirement 11.5、11.6、11.9）。
    /// 地址格式无效与地址为空一样，算作需补全服务地址。
    public static func pendingItemNames(_ issues: [LLMSettingsIssue]) -> [String] {
        var out: [String] = []
        if issues.contains(.missingEndpoint) || issues.contains(.invalidEndpoint) { out.append("服务地址") }
        if issues.contains(.missingModel) { out.append("模型名") }
        if issues.contains(.missingAPIKey) || issues.contains(.keychainFailure) { out.append("API Key") }
        return out
    }

    /// 开关旁的提示；没有问题时为 nil。
    public static func pendingHint(_ issues: [LLMSettingsIssue]) -> String? {
        let names = pendingItemNames(issues)
        return names.isEmpty ? nil : "需补全：" + names.joined(separator: "、")
    }

    /// 服务地址旁的提示（Requirement 11.6）。
    public static let invalidEndpoint = "地址格式无效：需以 http:// 或 https:// 开头并包含主机名"

    /// 钥匙串失败提示（Requirement 11.9）。
    public static let keychainFailure = "钥匙串读写失败，API Key 未能保存或读取，已按空处理"
}

/// 当前 LLM 设置与 API Key 的唯一持有者。
///
/// - 修改立即生效于内存（此后的请求使用新值），并在 `saveDelay`（默认 0.3 秒）后写入
///   `LLMSettingsStore` 与 `SecretStore`（Requirement 11.4）。
/// - 任何时候只要 `issues` 非空，两个开关都被改为关闭（Requirement 11.5、11.6、11.9）。
/// - 开关第一次被打开时先进入 `pendingDisclosure`，确认后才打开并记住（Requirement 11.7、11.8）。
/// - 钥匙串读写失败时记录 `keychainError`，按 Key 为空处理，Key 不改存到别处（Requirement 11.9）。
@MainActor
@Observable
public final class LLMSettingsModel {
    /// 当前设置（已按 `issues` 关闭开关）。
    public private(set) var settings: LLMSettings
    /// 输入框中的 API Key。钥匙串失败时仍保留在内存中供界面显示，但校验和请求按空处理。
    public private(set) var apiKey: String
    /// 最近一次钥匙串读取或写入失败；成功写入后清除。
    public private(set) var keychainError: SecretStoreError?
    /// 正在等待玩家确认说明的开关。
    public private(set) var pendingDisclosure: LLMToggle?

    @ObservationIgnored private let store: LLMSettingsStore
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var settingsDirty = false
    @ObservationIgnored private var keyDirty = false
    @ObservationIgnored private var changeHandlers: [@MainActor (LLMSettingsModel) -> Void] = []

    /// 读取已保存的设置和 API Key。读取设置不会写回文件。
    public init(store: LLMSettingsStore, secrets: SecretStore, saveDelay: Duration = .milliseconds(300)) {
        self.store = store
        self.secrets = secrets
        self.saveDelay = saveDelay
        self.settings = store.load()
        switch secrets.readAPIKey() {
        case let .success(key):
            apiKey = key ?? ""
            keychainError = nil
        case let .failure(e):
            apiKey = ""
            keychainError = e
        }
        settings = LLMSettingsValidation.effective(settings, apiKeyResult: apiKeyResult)
    }

    // MARK: 读取

    /// 供校验和请求使用的 Key：钥匙串失败时为失败，空串为 nil。
    public var apiKeyResult: Result<String?, SecretStoreError> {
        if let keychainError { return .failure(keychainError) }
        return .success(apiKey.isEmpty ? nil : apiKey)
    }

    public var issues: [LLMSettingsIssue] {
        LLMSettingsValidation.issues(settings, apiKeyResult: apiKeyResult)
    }

    /// 两个开关是否可以打开。
    public var canEnable: Bool { issues.isEmpty }

    public func isOn(_ t: LLMToggle) -> Bool {
        switch t {
        case .diary: settings.diaryEnabled
        case .thoughts: settings.thoughtsEnabled
        }
    }

    /// 经 `effective` 处理后的设置。
    public var effective: LLMSettings {
        LLMSettingsValidation.effective(settings, apiKeyResult: apiKeyResult)
    }

    /// 设置合法时的请求配置，与开关无关。
    public var requestConfig: LLMRequestConfig? {
        LLMSettingsValidation.config(settings, apiKeyResult: apiKeyResult)
    }

    /// 「日记使用 LLM」打开且设置合法时的配置，否则为 nil（Requirement 12.6）。
    public var diaryConfig: LLMRequestConfig? { effective.diaryEnabled ? requestConfig : nil }

    /// 「小心思」打开且设置合法时的配置，否则为 nil（Requirement 12.6）。
    public var thoughtsConfig: LLMRequestConfig? { effective.thoughtsEnabled ? requestConfig : nil }

    // MARK: 变化通知

    /// 注册变化回调。设置、API Key 或钥匙串状态在内存中变化后同步调用（不等待保存）。
    public func addChangeHandler(_ handler: @escaping @MainActor (LLMSettingsModel) -> Void) {
        changeHandlers.append(handler)
    }

    // MARK: 编辑

    public func setEndpoint(_ s: String) {
        let v = LLMSettingsLimits.truncate(s, to: LLMSettingsLimits.endpoint)
        guard v != settings.endpoint else { return }
        settings.endpoint = v
        settingsDirty = true
        didEdit()
    }

    public func setModel(_ s: String) {
        let v = LLMSettingsLimits.truncate(s, to: LLMSettingsLimits.model)
        guard v != settings.model else { return }
        settings.model = v
        settingsDirty = true
        didEdit()
    }

    public func setAPIKey(_ s: String) {
        let v = LLMSettingsLimits.truncate(s, to: LLMSettingsLimits.apiKey)
        guard v != apiKey else { return }
        apiKey = v
        keyDirty = true
        didEdit()
    }

    /// 玩家拨动开关。关闭直接生效；打开时设置不完整则忽略，说明未确认则先等待确认。
    public func requestToggle(_ t: LLMToggle, on: Bool) {
        if !on {
            if pendingDisclosure == t { pendingDisclosure = nil }
            guard isOn(t) else { return }
            setFlag(t, false)
            didEdit()
            return
        }
        guard !isOn(t), canEnable else { return }
        if acknowledged(t) {
            setFlag(t, true)
            didEdit()
        } else {
            pendingDisclosure = t
        }
    }

    /// 说明中选择「确认」：记住已确认并打开该开关（Requirement 11.8）。
    public func confirmDisclosure() {
        guard let t = pendingDisclosure else { return }
        pendingDisclosure = nil
        switch t {
        case .diary: settings.diaryDisclosureAcknowledged = true
        case .thoughts: settings.thoughtsDisclosureAcknowledged = true
        }
        settingsDirty = true
        if canEnable { setFlag(t, true) }
        didEdit()
    }

    /// 说明中选择「取消」或关闭说明：开关保持关闭，下次重新显示说明（Requirement 11.8）。
    public func cancelDisclosure() {
        pendingDisclosure = nil
    }

    /// 立即写入尚未保存的修改（窗口关闭、应用退出时调用）。
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        var changed = false
        if keyDirty {
            keyDirty = false
            switch secrets.writeAPIKey(apiKey.isEmpty ? nil : apiKey) {
            case .success:
                if keychainError != nil { keychainError = nil; changed = true }
            case let .failure(e):
                if keychainError != e { keychainError = e; changed = true }
            }
            if normalize() { changed = true }
        }
        if settingsDirty {
            settingsDirty = false
            store.save(settings)
        }
        if changed { notify() }
    }

    /// 是否有尚未保存的修改。
    public var hasPendingSave: Bool { settingsDirty || keyDirty }

    // MARK: 内部

    private func acknowledged(_ t: LLMToggle) -> Bool {
        switch t {
        case .diary: settings.diaryDisclosureAcknowledged
        case .thoughts: settings.thoughtsDisclosureAcknowledged
        }
    }

    private func setFlag(_ t: LLMToggle, _ v: Bool) {
        switch t {
        case .diary: settings.diaryEnabled = v
        case .thoughts: settings.thoughtsEnabled = v
        }
        settingsDirty = true
    }

    /// 有问题时关闭两个开关并取消待确认的说明。返回是否改动了设置。
    @discardableResult
    private func normalize() -> Bool {
        guard !canEnable else { return false }
        pendingDisclosure = nil
        let forced = LLMSettingsValidation.effective(settings, apiKeyResult: apiKeyResult)
        guard forced != settings else { return false }
        settings = forced
        settingsDirty = true
        return true
    }

    private func didEdit() {
        normalize()
        notify()
        scheduleSave()
    }

    private func notify() {
        for h in changeHandlers { h(self) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
