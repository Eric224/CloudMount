import Foundation
import Security
import LocalAuthentication

protocol VaultSecretStore {
    func read(_ id: UUID) throws -> VaultSecrets?
    func save(_ keys: VaultSecrets) throws
    func remove(_ id: UUID) throws
}

struct VaultKeychain: VaultSecretStore {
    var service = "com.codex.cloudmount.vault.v1"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    func read(_ id: UUID) throws -> VaultSecrets? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Routine operations and startup must never trigger an OS password dialog.
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound || result == errSecInteractionNotAllowed || result == errSecAuthFailed { return nil }
        guard result == errSecSuccess, let data = item as? Data, let keys = try? JSONDecoder().decode(VaultSecrets.self, from: data), keys.id == id else {
            throw VaultFailure.message("無法讀取鑰匙圈，請使用保險箱密碼解鎖。")
        }
        return keys
    }
    func save(_ keys: VaultSecrets) throws {
        let data = try JSONEncoder().encode(keys)
        var query = query(keys.id)
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VaultFailure.message("鑰匙圈無法儲存；保險箱已解鎖，下次可使用密碼開啟。") }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw VaultFailure.message("鑰匙圈無法儲存；保險箱已解鎖，下次可使用密碼開啟。") }
    }
    func remove(_ id: UUID) throws {
        var query = query(id)
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw VaultFailure.message("無法移除鑰匙圈中的解鎖資訊。") }
    }
}
