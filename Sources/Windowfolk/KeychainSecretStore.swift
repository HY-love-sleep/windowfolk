import Foundation
import Security
import WindowfolkCore

/// 把 API Key 存在登录钥匙串中的 `SecretStore`（design.md「KeychainSecretStore」，Requirement 11.3、11.9）。
///
/// 通用密码项，以 service `com.windowfolk.llm` 加 account `api-key` 唯一定位。
/// SwiftPM 可执行文件没有 keychain-access-groups 授权，因此不使用 Data Protection 钥匙串。
/// 任何非成功状态都返回 `.failure`，不改存到别处；不写日志。
final class KeychainSecretStore: SecretStore, Sendable {
    static let service = "com.windowfolk.llm"
    static let account = "api-key"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func readAPIKey() -> Result<String?, SecretStoreError> {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                return .failure(.operationFailed(status: errSecDecode))
            }
            return .success(key.isEmpty ? nil : key)
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(.operationFailed(status: status))
        }
    }

    /// nil 或空串删除该项；否则先 `SecItemUpdate`，不存在时 `SecItemAdd`。
    func writeAPIKey(_ key: String?) -> Result<Void, SecretStoreError> {
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
                ? .success(()) : .failure(.operationFailed(status: status))
        }
        let data = Data(key.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return .success(())
        case errSecItemNotFound:
            var add = baseQuery
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            return status == errSecSuccess ? .success(()) : .failure(.operationFailed(status: status))
        default:
            return .failure(.operationFailed(status: update))
        }
    }
}
