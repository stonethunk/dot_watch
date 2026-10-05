import Foundation
import Security
#if PERSONAL_DIAGNOSTICS
import CryptoKit
import DotCore

struct PrivateWatchRecord: Codable {
    let grant: PrivateWatchGrant
    let credential: PrivateWatchCredential?
}

/// Separate device-only items on each surface. Plaintext is never staged to a file.
enum PrivateWatchKeychain {
    private static func query(_ item: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.dotwatch.app.private-watch-v1",
         kSecAttrAccount as String: item,
         kSecAttrSynchronizable as String: false]
    }
    private static func read(_ item: String) throws -> Data? {
        var request = query(item); request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let value = result as? Data else { throw PrivateWatchError.storage }
        return value
    }
    private static func write(_ data: Data, item: String) throws {
        var attributes = query(item); attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let changes = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
            guard SecItemUpdate(query(item) as CFDictionary, changes) == errSecSuccess else { throw PrivateWatchError.storage }
        } else if status != errSecSuccess { throw PrivateWatchError.storage }
    }
    static func key() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = try read("pairing-key") { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try write(key.rawRepresentation, item: "pairing-key"); return key
    }
    static func record() throws -> PrivateWatchRecord? {
        guard let data = try read("delegation") else { return nil }
        let record = try JSONDecoder().decode(PrivateWatchRecord.self, from: data)
        try record.grant.validate(); try record.credential?.matches(record.grant); return record
    }
    static func save(_ record: PrivateWatchRecord) throws {
        try record.grant.validate(); try record.credential?.matches(record.grant)
        try write(JSONEncoder().encode(record), item: "delegation")
    }
    static func clearCredential() throws {
        // Retain the last generation as a replay tombstone. Ownership is still
        // outstanding on the phone until it receives positive release acknowledgement.
        if let record = try record() { try save(PrivateWatchRecord(grant: record.grant, credential: nil)) }
    }
    static func journal() throws -> WatchCallJournal? {
        guard let data = try read("voice-journal") else { return nil }
        return try JSONDecoder().decode(WatchCallJournal.self, from: data)
    }
    static func saveJournal(_ value: WatchCallJournal?) throws {
        if let value { try write(JSONEncoder().encode(value), item: "voice-journal") }
        else {
            let status = SecItemDelete(query("voice-journal") as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PrivateWatchError.storage }
        }
    }
}

/// No SDP/audio. Persist before allocation; a crash or ambiguous HTTP response
/// cannot silently allocate a second voice session after relaunch.
struct WatchCallJournal: Codable {
    let dotID: String
    let callID: String?
}
#else
enum PrivateWatchKeychain {
    static func clearPublicUpgrade() throws {
        let query = [kSecClass as String: kSecClassGenericPassword,
                     kSecAttrService as String: "dev.dotwatch.app.private-watch-v1"] as CFDictionary
        let status = SecItemDelete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: "DotWatchCleanup", code: 1) }
    }
}
#endif
