import Foundation
import DotCore

#if PERSONAL_DIAGNOSTICS

/// Temporary private development setup. Never refreshes, manufactures, or
/// shares an account's authorization. Public builds do not call this importer.
public struct PrivateCredentialTransfer: Sendable {
    public let credentials: ChatGPTCredentials

    public init(data: Data, existingAccountID: String? = nil) throws {
        guard !data.isEmpty, data.count < 64 * 1024 else { throw DotError.invalidCredentials }
        let value: JSONValue
        do { value = try JSONValue.decode(data) }
        catch { throw DotError.invalidCredentials }
        guard let token = value["access_token"].string, let account = value["account_id"].string else { throw DotError.invalidCredentials }
        let credentials = try ChatGPTCredentials(accessToken: token, accountID: account)
        if let existingAccountID, existingAccountID != credentials.accountID {
            throw DotError.accountChangeRequiresSignOut
        }
        self.credentials = credentials
    }

    /// Persist only the allowed access token and account. An unexpected refresh
    /// token or other field in a transfer file must never enter device storage.
    public func canonicalData() throws -> Data {
        try JSONValue.object([
            "access_token": .string(credentials.accessToken),
            "account_id": .string(credentials.accountID)
        ]).encoded()
    }
}
#endif
