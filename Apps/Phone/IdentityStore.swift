import Foundation
import Security
import DotAuth

/// Stores verified identity metadata only. No raw ID/access/refresh token, and
/// no credential accepted by undocumented Dot endpoints, enters this store.
enum IdentityStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.dotwatch.app.openai-identity",
         kSecAttrAccount as String: "primary"]
    }
    static func read(configuration: OpenAIClientConfiguration) throws -> OpenAIIdentity? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count < 64 * 1024 else { throw SignInError.invalidIdentity }
        let identity = try JSONDecoder().decode(OpenAIIdentity.self, from: data)
        guard identity.issuer == "https://auth.openai.com", identity.clientID == configuration.clientID,
              !identity.subject.isEmpty, identity.validUntil > Date() else {
            try delete()
            return nil
        }
        return identity
    }
    static func save(_ identity: OpenAIIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        guard data.count < 64 * 1024 else { throw SignInError.invalidIdentity }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else { throw SignInError.invalidIdentity }
        } else if status != errSecSuccess { throw SignInError.invalidIdentity }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SignInError.invalidIdentity }
    }
}
