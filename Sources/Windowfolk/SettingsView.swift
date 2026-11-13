import SwiftUI
import WindowfolkCore

/// Settings_Window 的内容（design.md「SettingsWindowController」，Requirement 11.2、11.5–11.9）。
///
/// 三个输入框各自保存一份草稿：SwiftUI 的 `TextField` 在绑定值被截断成与旧值相同时不会刷新显示，
/// 所以先在草稿上截断再交给模型，保证屏幕上的文字不超过上限。
struct SettingsView: View {
    let model: LLMSettingsModel

    @State private var endpoint: String
    @State private var modelName: String
    @State private var apiKey: String

    init(model: LLMSettingsModel) {
        self.model = model
        _endpoint = State(initialValue: model.settings.endpoint)
        _modelName = State(initialValue: model.settings.model)
        _apiKey = State(initialValue: model.apiKey)
    }

    var body: some View {
        let issues = model.issues
        Form {
            Section("LLM 服务") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("服务地址", text: $endpoint, prompt: Text("https://api.openai.com/v1/chat/completions"))
                        .onChange(of: endpoint) { _, new in
                            let v = LLMSettingsLimits.truncate(new, to: LLMSettingsLimits.endpoint)
                            if v != new { endpoint = v }
                            model.setEndpoint(v)
                        }
                    if issues.contains(.invalidEndpoint) {
                        hint(LLMSettingsText.invalidEndpoint)
                    }
                }
                TextField("模型名", text: $modelName)
                    .onChange(of: modelName) { _, new in
                        let v = LLMSettingsLimits.truncate(new, to: LLMSettingsLimits.model)
                        if v != new { modelName = v }
                        model.setModel(v)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    SecureField("API Key", text: $apiKey)
                        .onChange(of: apiKey) { _, new in
                            let v = LLMSettingsLimits.truncate(new, to: LLMSettingsLimits.apiKey)
                            if v != new { apiKey = v }
                            model.setAPIKey(v)
                        }
                    if issues.contains(.keychainFailure) {
                        hint(LLMSettingsText.keychainFailure)
                    }
                }
            }
            Section {
                ForEach(LLMToggle.allCases, id: \.self) { t in
                    Toggle(LLMSettingsText.toggleTitle(t), isOn: toggleBinding(t))
                        .disabled(!model.canEnable)
                }
                if let pending = LLMSettingsText.pendingHint(issues) {
                    hint(pending)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .alert(
            model.pendingDisclosure.map(LLMSettingsText.disclosureTitle) ?? "",
            isPresented: disclosureBinding
        ) {
            Button(LLMSettingsText.confirm) { model.confirmDisclosure() }
            Button(LLMSettingsText.cancel, role: .cancel) { model.cancelDisclosure() }
        } message: {
            Text(LLMSettingsText.disclosureMessage)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toggleBinding(_ t: LLMToggle) -> Binding<Bool> {
        Binding(get: { model.isOn(t) }, set: { model.requestToggle(t, on: $0) })
    }

    /// 关闭说明（包括按 Esc）与「取消」相同。
    private var disclosureBinding: Binding<Bool> {
        Binding(get: { model.pendingDisclosure != nil },
                set: { if !$0 { model.cancelDisclosure() } })
    }
}
