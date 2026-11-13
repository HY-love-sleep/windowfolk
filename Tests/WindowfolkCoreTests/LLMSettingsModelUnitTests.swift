import Foundation
import Testing
@testable import WindowfolkCore

/// Settings_Window 背后的 `LLMSettingsModel` 例子测试（任务 15.2，Requirement 11.1、11.2、11.4–11.9）。
/// 只使用临时目录和 `InMemorySecretStore`，不访问钥匙串。
@MainActor
@Suite struct LLMSettingsModelUnitTests {
    private func tempStore() -> FileLLMSettingsStore {
        FileLLMSettingsStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-settings-model-\(UUID().uuidString)", isDirectory: true))
    }

    private func filled(_ m: LLMSettingsModel) {
        m.setEndpoint("https://api.example.com/v1/chat/completions")
        m.setModel("gpt-4o-mini")
        m.setAPIKey("sk-test-123456")
    }

    @Test func startsOffAndEmptyWithoutSavedSettings() {
        let m = LLMSettingsModel(store: tempStore(), secrets: InMemorySecretStore())
        #expect(m.settings == LLMSettings())
        #expect(m.apiKey.isEmpty)
        #expect(!m.canEnable)
        #expect(m.diaryConfig == nil && m.thoughtsConfig == nil)
    }

    @Test func inputsAreTruncatedToLimits() {
        let m = LLMSettingsModel(store: tempStore(), secrets: InMemorySecretStore())
        m.setEndpoint("https://a.com/" + String(repeating: "x", count: 3000))
        m.setModel(String(repeating: "模", count: 200))
        m.setAPIKey(String(repeating: "k", count: 600))
        #expect(m.settings.endpoint.count == 2048)
        #expect(m.settings.model.count == 128)
        #expect(m.apiKey.count == 512)
    }

    @Test func togglesCannotOpenWhileIncompleteAndCloseWhenFieldCleared() {
        let m = LLMSettingsModel(store: tempStore(), secrets: InMemorySecretStore())
        m.requestToggle(.diary, on: true)
        #expect(!m.isOn(.diary) && m.pendingDisclosure == nil)
        #expect(LLMSettingsText.pendingItemNames(m.issues) == ["服务地址", "模型名", "API Key"])

        filled(m)
        m.requestToggle(.diary, on: true)
        m.confirmDisclosure()
        #expect(m.isOn(.diary))
        #expect(m.diaryConfig != nil && m.thoughtsConfig == nil)

        m.setEndpoint("ftp://example.com")
        #expect(!m.isOn(.diary))
        #expect(m.issues.contains(.invalidEndpoint))
        #expect(LLMSettingsText.pendingItemNames(m.issues) == ["服务地址"])
        #expect(m.diaryConfig == nil)
    }

    @Test func disclosureIsShownUntilConfirmedThenRemembered() {
        let m = LLMSettingsModel(store: tempStore(), secrets: InMemorySecretStore())
        filled(m)

        m.requestToggle(.thoughts, on: true)
        #expect(m.pendingDisclosure == .thoughts && !m.isOn(.thoughts))
        m.cancelDisclosure()
        #expect(m.pendingDisclosure == nil && !m.isOn(.thoughts))
        #expect(!m.settings.thoughtsDisclosureAcknowledged)

        m.requestToggle(.thoughts, on: true)
        #expect(m.pendingDisclosure == .thoughts)
        m.confirmDisclosure()
        #expect(m.isOn(.thoughts) && m.settings.thoughtsDisclosureAcknowledged)

        m.requestToggle(.thoughts, on: false)
        m.requestToggle(.thoughts, on: true)
        #expect(m.pendingDisclosure == nil && m.isOn(.thoughts))

        // 另一个开关的说明单独确认。
        m.requestToggle(.diary, on: true)
        #expect(m.pendingDisclosure == .diary && !m.isOn(.diary))
    }

    @Test func disclosureMessageListsOnlyWhitelistedItems() {
        let msg = LLMSettingsText.disclosureMessage
        for item in ["居民名字", "事件类型", "事件时间", "日期", "物件种类", "心愿种类", "心愿状态", "追逐结局", "花的生长阶段"] {
            #expect(msg.contains(item))
        }
        #expect(msg.contains("不包含窗口标题和应用名称"))
    }

    @Test func editsAreSavedWithinOneSecondAndSurviveRestart() async throws {
        let store = tempStore()
        let secrets = InMemorySecretStore()
        let m = LLMSettingsModel(store: store, secrets: secrets, saveDelay: .milliseconds(50))
        filled(m)
        m.requestToggle(.diary, on: true)
        m.confirmDisclosure()
        #expect(m.hasPendingSave)

        try await Task.sleep(for: .milliseconds(600))
        #expect(!m.hasPendingSave)
        #expect(store.load() == m.settings)
        #expect(secrets.storedAPIKey == "sk-test-123456")

        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!raw.contains("sk-test-123456"))

        let restarted = LLMSettingsModel(store: store, secrets: secrets)
        #expect(restarted.settings == m.settings)
        #expect(restarted.apiKey == "sk-test-123456")
        #expect(restarted.isOn(.diary))
    }

    @Test func keychainReadFailureDisablesTogglesAndShowsHint() {
        let store = tempStore()
        store.save(LLMSettings(diaryEnabled: true, thoughtsEnabled: true,
                               endpoint: "https://api.example.com/v1", model: "m",
                               diaryDisclosureAcknowledged: true, thoughtsDisclosureAcknowledged: true))
        let secrets = InMemorySecretStore(apiKey: "sk-saved")
        secrets.failReads = true
        let m = LLMSettingsModel(store: store, secrets: secrets)
        #expect(m.apiKey.isEmpty)
        #expect(m.issues.contains(.keychainFailure))
        #expect(!m.isOn(.diary) && !m.isOn(.thoughts))
        #expect(LLMSettingsText.pendingItemNames(m.issues) == ["API Key"])
        #expect(m.requestConfig == nil)
    }

    @Test func keychainWriteFailureKeepsKeyOutOfOtherStoresAndClosesToggles() {
        let store = tempStore()
        let secrets = InMemorySecretStore()
        let m = LLMSettingsModel(store: store, secrets: secrets)
        filled(m)
        m.requestToggle(.diary, on: true)
        m.confirmDisclosure()
        m.flush()
        #expect(m.isOn(.diary))

        secrets.failWrites = true
        m.setAPIKey("sk-new-key-999")
        m.flush()
        #expect(m.keychainError != nil)
        #expect(m.issues.contains(.keychainFailure))
        #expect(!m.isOn(.diary))
        #expect(secrets.storedAPIKey == "sk-test-123456")
        #expect(store.load().diaryEnabled == false)

        secrets.failWrites = false
        m.setAPIKey("sk-new-key-998")
        m.flush()
        #expect(m.keychainError == nil && m.canEnable)
        #expect(secrets.storedAPIKey == "sk-new-key-998")
    }

    @Test func changeHandlersSeeNewValuesImmediately() {
        let m = LLMSettingsModel(store: tempStore(), secrets: InMemorySecretStore(), saveDelay: .seconds(10))
        var seen: [String] = []
        m.addChangeHandler { seen.append($0.settings.model) }
        m.setModel("a")
        m.setModel("a")
        m.setModel("b")
        #expect(seen == ["a", "b"])
    }
}
