import Foundation
import Security
import DotCore

/// Device-only credential storage. No credentials in defaults, logs, or app resources.
enum CredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.dotwatch.app.session",
         kSecAttrAccount as String: "primary"]
    }

    static func read() throws -> ChatGPTCredentials? {
        #if PERSONAL_DIAGNOSTICS
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DotError.invalidCredentials }
        return try decode(data)
        #else
        return nil
        #endif
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DotError.invalidCredentials }
        let staging = URL.documentsDirectory.appendingPathComponent("paired-session.json")
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        if let browser = BrowserStagingLocation.url, FileManager.default.fileExists(atPath: browser.path) {
            try FileManager.default.removeItem(at: browser)
        }
    }

    /// Development bootstrap transferred over the trusted device connection. Consume
    /// once, erase the staging file, and never include a refresh token in this format.
    static func importPairedSessionIfPresent() throws {
        let usb = URL.documentsDirectory.appendingPathComponent("paired-session.json")
        #if PERSONAL_DIAGNOSTICS
        let urls = [usb, BrowserStagingLocation.url].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        guard urls.count == 1, let url = urls.first else { throw DotError.invalidCredentials }
        let transfer = try PrivateCredentialTransfer(data: Data(contentsOf: url), existingAccountID: read()?.accountID)
        let data = try transfer.canonicalData()
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data] as CFDictionary
            guard SecItemUpdate(query as CFDictionary, update) == errSecSuccess else { throw DotError.invalidCredentials }
        } else if status != errSecSuccess { throw DotError.invalidCredentials }
        #else
        // A public/beta upgrade must never reuse personal diagnostic credentials.
        try delete()
        #endif
    }

    static var privateTransferPending: Bool {
        #if PERSONAL_DIAGNOSTICS
        [URL.documentsDirectory.appendingPathComponent("paired-session.json"), BrowserStagingLocation.url]
            .compactMap { $0 }.contains { FileManager.default.fileExists(atPath: $0.path) }
        #else
        false
        #endif
    }

    private static func decode(_ data: Data) throws -> ChatGPTCredentials {
        #if PERSONAL_DIAGNOSTICS
        return try PrivateCredentialTransfer(data: data).credentials
        #else
        throw DotError.invalidCredentials
        #endif
    }
}
