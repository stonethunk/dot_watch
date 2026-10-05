import Foundation
import CryptoKit
import Testing
import DotCore
import DotCompanion
@testable import DotPrivateWatch

struct WatchCredentialTests {
    func pairing() throws -> CharacterPairing {
        try CharacterPairing(installation: UUID(), revision: 1,
            appearance: PairedAppearance(accountHash: PairedAppearance.hash(Data("fixture-account".utf8)),
                dotHash: String(repeating: "b", count: 64), version: String(repeating: "c", count: 64), imageHash: String(repeating: "d", count: 64)))
    }
    func grant(_ key: Curve25519.KeyAgreement.PrivateKey, generation: UInt64 = 1, pairing: CharacterPairing? = nil,
               owner: PrivateWatchGrant.Owner = .watch) throws -> PrivateWatchGrant {
        try PrivateWatchGrant(generation: generation, pairing: pairing ?? self.pairing(), owner: owner, recipient: key.publicKey.rawRepresentation)
    }
    var credentials: ChatGPTCredentials { get throws { try ChatGPTCredentials(accessToken: "fixture-access-token", accountID: "fixture-account") } }

    @Test func encryptionRoundTripAndNoPlaintextOnWire() throws {
        let key = Curve25519.KeyAgreement.PrivateKey(), grant = try grant(key)
        let envelope = try PrivateWatchEnvelope.seal(credentials, for: grant)
        let wire = try PrivateWatchMessage(.grant, grant: grant, envelope: envelope).encoded()
        #expect(!String(decoding: wire, as: UTF8.self).contains("fixture-access-token"))
        #expect(!String(decoding: wire, as: UTF8.self).contains("fixture-account"))
        let message = try PrivateWatchMessage.decode(wire)
        let opened = try #require(message.envelope).open(with: key, grant: grant)
        let expected = try credentials
        #expect(opened.accessToken == expected.accessToken)
        #expect(opened.accountID == expected.accountID)
    }
    @Test func otherWatchAndTamperedGrantCannotDecrypt() throws {
        let key = Curve25519.KeyAgreement.PrivateKey(), pairing = try pairing(), grant = try grant(key, pairing: pairing)
        let envelope = try PrivateWatchEnvelope.seal(credentials, for: grant)
        #expect(throws: (any Error).self) { try envelope.open(with: .init(), grant: grant) }
        let changed = try self.grant(key, generation: 2, pairing: pairing)
        #expect(throws: (any Error).self) { try envelope.open(with: key, grant: changed) }
        var bytes = envelope.ciphertext; bytes[bytes.count - 1] ^= 1
        #expect(throws: (any Error).self) { try PrivateWatchEnvelope(ephemeralPublicKey: envelope.ephemeralPublicKey, ciphertext: bytes).open(with: key, grant: grant) }
    }
    @Test func replayCannotRestoreRevokedCredential() throws {
        let key = Curve25519.KeyAgreement.PrivateKey(), pairing = try pairing()
        let old = try grant(key, pairing: pairing)
        let revoke = try grant(key, generation: 2, pairing: pairing, owner: .phone)
        #expect(throws: PrivateWatchError.stale) { try old.follows(revoke) }
        try revoke.follows(revoke)
        try grant(key, generation: 3, pairing: pairing).follows(revoke)
    }
    @Test func accountAndInstallationCannotChangeUnderAnOutstandingGrant() throws {
        let key = Curve25519.KeyAgreement.PrivateKey(), old = try grant(key)
        #expect(throws: PrivateWatchError.stale) { try grant(key, generation: 2).follows(old) }
        #expect(throws: PrivateWatchError.invalid) {
            try PrivateWatchEnvelope.seal(ChatGPTCredentials(accessToken: "fixture", accountID: "other-account"), for: old)
        }
    }
    @Test func noCredentialToPhoneAndBoundedStrictMessages() throws {
        let key = Curve25519.KeyAgreement.PrivateKey(), grant = try grant(key, owner: .phone)
        #expect(throws: PrivateWatchError.invalid) { try PrivateWatchEnvelope.seal(credentials, for: grant) }
        #expect(throws: PrivateWatchError.invalid) { try PrivateWatchMessage.decode(Data(repeating: 0, count: 65 * 1024)) }
        let data = try PrivateWatchMessage(.sync, publicKey: key.publicKey.rawRepresentation).encoded()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["refreshToken"] = "fixture"
        #expect(throws: PrivateWatchError.invalid) { try PrivateWatchMessage.decode(JSONSerialization.data(withJSONObject: object)) }
    }
}
