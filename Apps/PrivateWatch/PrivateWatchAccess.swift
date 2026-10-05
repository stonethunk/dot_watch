#if PERSONAL_DIAGNOSTICS
import Foundation
import CryptoKit
import DotCore
import DotCompanion

enum PrivateWatchError: String, Error { case invalid, stale, setup, busy, storage, unreachable, timeout, release }

/// Durable permission to start voice, independent of phone liveness. Ownership
/// returns to the phone only after the Watch acknowledges release and revocation.
struct PrivateWatchGrant: Codable, Sendable, Equatable {
    enum Owner: String, Codable, Sendable { case phone, watch }
    let schema: Int
    let generation: UInt64
    let pairing: CharacterPairing
    let owner: Owner
    let recipient: Data

    init(generation: UInt64, pairing: CharacterPairing, owner: Owner, recipient: Data) throws {
        schema = 1; self.generation = generation; self.pairing = pairing
        self.owner = owner; self.recipient = recipient
        try validate()
    }
    func validate() throws {
        try pairing.validate()
        guard schema == 1, generation > 0, generation < UInt64.max,
              recipient.count == 32, pairing.appearance != nil else { throw PrivateWatchError.invalid }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    func follows(_ previous: Self?) throws {
        try validate()
        guard let previous else { return }
        // A new installation must first acknowledge the old grant's revocation.
        if pairing.installation != previous.pairing.installation {
            guard previous.owner == .phone else { throw PrivateWatchError.stale }
            return
        }
        guard generation > previous.generation || self == previous else { throw PrivateWatchError.stale }
    }
}

/// Only access token/account ID are encoded, never passwords or refresh tokens.
struct PrivateWatchCredential: Codable, Sendable {
    let accessToken: String
    let accountID: String
    init(_ credentials: ChatGPTCredentials) throws {
        accessToken = credentials.accessToken; accountID = credentials.accountID
        _ = try checked()
    }
    func checked() throws -> ChatGPTCredentials {
        guard accessToken.utf8.count <= 32 * 1024, accountID.utf8.count <= 256 else { throw PrivateWatchError.invalid }
        return try ChatGPTCredentials(accessToken: accessToken, accountID: accountID)
    }
    func matches(_ grant: PrivateWatchGrant) throws {
        _ = try checked()
        guard grant.owner == .watch,
              grant.pairing.appearance?.accountHash == PairedAppearance.hash(Data(accountID.utf8)) else { throw PrivateWatchError.invalid }
    }
}

struct PrivateWatchEnvelope: Codable, Sendable {
    let ephemeralPublicKey: Data
    let ciphertext: Data
    private static let info = Data("DotWatch private credential sync v1".utf8)

    static func seal(_ credentials: ChatGPTCredentials, for grant: PrivateWatchGrant) throws -> Self {
        let value = try PrivateWatchCredential(credentials); try value.matches(grant)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: grant.recipient)
        let aad = try grant.encoded()
        let key = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: aad, sharedInfo: info, outputByteCount: 32)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(value), using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw PrivateWatchError.invalid }
        return Self(ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, ciphertext: combined)
    }

    func open(with key: Curve25519.KeyAgreement.PrivateKey, grant: PrivateWatchGrant) throws -> PrivateWatchCredential {
        guard key.publicKey.rawRepresentation == grant.recipient, ephemeralPublicKey.count == 32,
              ciphertext.count <= 48 * 1024 else { throw PrivateWatchError.invalid }
        let aad = try grant.encoded()
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKey)
        let symmetric = try key.sharedSecretFromKeyAgreement(with: peer)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: aad, sharedInfo: Self.info, outputByteCount: 32)
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: symmetric, authenticating: aad)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == ["accessToken", "accountID"] else { throw PrivateWatchError.invalid }
        let value = try JSONDecoder().decode(PrivateWatchCredential.self, from: data)
        try value.matches(grant)
        return value
    }
}

struct PrivateWatchMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case sync, grant, revoke, ack, failed }
    let schema: Int
    let kind: Kind
    let requestID: UUID
    let publicKey: Data?
    let grant: PrivateWatchGrant?
    let envelope: PrivateWatchEnvelope?
    let error: PrivateWatchError?

    init(_ kind: Kind, requestID: UUID = UUID(), publicKey: Data? = nil, grant: PrivateWatchGrant? = nil,
         envelope: PrivateWatchEnvelope? = nil, error: PrivateWatchError? = nil) {
        schema = 1; self.kind = kind; self.requestID = requestID; self.publicKey = publicKey
        self.grant = grant; self.envelope = envelope; self.error = error
    }
    func encoded() throws -> Data {
        try validate(); let data = try JSONEncoder().encode(self)
        guard data.count <= 64 * 1024 else { throw PrivateWatchError.invalid }; return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024, !data.isEmpty,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys).isSubset(of: ["schema", "kind", "requestID", "publicKey", "grant", "envelope", "error"]) else { throw PrivateWatchError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    private func validate() throws {
        guard schema == 1 else { throw PrivateWatchError.invalid }
        try grant?.validate()
        switch kind {
        case .sync: guard publicKey?.count == 32, grant == nil, envelope == nil, error == nil else { throw PrivateWatchError.invalid }
        case .grant: guard publicKey == nil, grant?.owner == .watch, envelope != nil, error == nil else { throw PrivateWatchError.invalid }
        case .revoke: guard publicKey == nil, grant?.owner == .phone, envelope == nil, error == nil else { throw PrivateWatchError.invalid }
        case .ack: guard publicKey == nil, grant?.owner == .phone, envelope == nil, error == nil else { throw PrivateWatchError.invalid }
        case .failed: guard publicKey == nil, grant == nil, envelope == nil, error != nil else { throw PrivateWatchError.invalid }
        }
    }
}
extension PrivateWatchError: Codable {}
#endif
