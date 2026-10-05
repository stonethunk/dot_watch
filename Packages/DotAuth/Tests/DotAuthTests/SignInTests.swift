import Foundation
import CryptoKit
import Security
import JWTKit
import Testing
@testable import DotAuth

private func config() throws -> OpenAIClientConfiguration {
    try .init(clientID: "oaiapp_synthetic_test", redirectURI: URL(string: "dev.dotwatch.app.auth://signin/oauth/callback")!)
}
private func metadata() throws -> OpenAIMetadata {
    try JSONDecoder().decode(OpenAIMetadata.self, from: Data("""
    {"issuer":"https://auth.openai.com","authorization_endpoint":"https://auth.openai.com/api/accounts/authorize","token_endpoint":"https://auth.openai.com/api/accounts/oauth/token","jwks_uri":"https://auth.openai.com/.well-known/jwks.json"}
    """.utf8))
}
@MainActor private func callback(_ transaction: SignInTransaction, state: String? = nil) -> URL {
    var value = URLComponents(url: transaction.configuration.redirectURI, resolvingAgainstBaseURL: false)!
    value.queryItems = [.init(name: "code", value: "synthetic-code"), .init(name: "state", value: state ?? transaction.state)]
    return value.url!
}

@Test @MainActor func randomPKCEAndMinimalScope() throws {
    let first = try SignInTransaction(configuration: config())
    let second = try SignInTransaction(configuration: config())
    #expect(first.state != second.state && first.nonce != second.nonce && first.verifier != second.verifier)
    #expect((43...128).contains(first.verifier.count))
    #expect(first.challenge == SignInTransaction.base64URL(Data(SHA256.hash(data: Data(first.verifier.utf8)))))
    let items = URLComponents(url: try first.authorizationURL(metadata: metadata()), resolvingAgainstBaseURL: false)!.queryItems!
    #expect(items.first { $0.name == "scope" }?.value == "openid profile email")
    #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
    #expect(!items.contains { $0.name == "client_secret" })
}

@Test @MainActor func callbackIsBoundToStateAndOneUse() throws {
    let valid = try SignInTransaction(configuration: config())
    #expect(try valid.consume(callback: callback(valid)) == "synthetic-code")
    #expect(throws: SignInError.consumedTransaction) { try valid.consume(callback: callback(valid)) }
    let invalid = try SignInTransaction(configuration: config())
    #expect(throws: SignInError.invalidCallback) { try invalid.consume(callback: callback(invalid, state: "wrong")) }
    #expect(throws: SignInError.consumedTransaction) { try invalid.consume(callback: callback(invalid)) }
}

@Test @MainActor func redirectAndDuplicateParametersAreRejected() throws {
    for transform in [
        { (value: String) in value.replacingOccurrences(of: "/oauth/callback", with: "/other") },
        { (value: String) in value.replacingOccurrences(of: "://signin/", with: "://attacker/") },
        { (value: String) in value + "&code=another" },
        { (value: String) in value + "&state=another" },
        { (value: String) in value + "#fragment" }
    ] {
        let transaction = try SignInTransaction(configuration: config())
        let url = URL(string: transform(callback(transaction).absoluteString))!
        #expect(throws: SignInError.invalidCallback) { try transaction.consume(callback: url) }
    }
}

@Test @MainActor func cancellationAndExpiration() throws {
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let expired = try SignInTransaction(configuration: config(), now: start)
    #expect(throws: SignInError.expiredTransaction) { try expired.consume(callback: callback(expired), now: start.addingTimeInterval(600)) }
    let cancelled = try SignInTransaction(configuration: config())
    cancelled.cancel()
    #expect(throws: SignInError.consumedTransaction) { try cancelled.consume(callback: callback(cancelled)) }
}

@Test func configurationAndIssuerOriginAreRestricted() throws {
    for uri in ["http://example.com/callback", "file:///callback", "javascript:callback", "dot://signin/callback", "dev.dotwatch.app.auth://signin/callback?extra=yes"] {
        #expect(throws: SignInError.notConfigured) { try OpenAIClientConfiguration(clientID: "oaiapp_test", redirectURI: URL(string: uri)!) }
    }
    #expect(throws: SignInError.notConfigured) { try OpenAIClientConfiguration(clientID: "dynamic_agent_client", redirectURI: config().redirectURI) }
    try metadata().validate()
    for endpoint in ["https://auth.openai.com.attacker.invalid/token", "http://auth.openai.com/token", "https://auth.openai.com:444/token", "https://user:pass@auth.openai.com/token"] {
        let data = try JSONSerialization.data(withJSONObject: ["issuer": "https://auth.openai.com", "authorization_endpoint": endpoint, "token_endpoint": endpoint, "jwks_uri": endpoint])
        let value = try JSONDecoder().decode(OpenAIMetadata.self, from: data)
        #expect(throws: SignInError.invalidMetadata) { try value.validate() }
    }
}

/// Fresh, nonpersistent test keys. Apple Security signs the fixtures independently
/// of JWTKit, which the implementation uses only for signature verification.
private struct SignedFixture {
    let key: SecKey
    let jwk: [String: String]
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    init() throws {
        let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(options as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let data = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let pem = "-----BEGIN RSA PUBLIC KEY-----\n" + data.base64EncodedString(options: .lineLength64Characters) + "\n-----END RSA PUBLIC KEY-----"
        let (modulus, exponent) = try Insecure.RSA.PublicKey(pem: pem).getKeyPrimitives()
        self.key = key
        jwk = ["kid": "fixture", "kty": "RSA", "alg": "RS256", "use": "sig", "n": SignInTransaction.base64URL(modulus), "e": SignInTransaction.base64URL(exponent)]
    }
    func token(overrides: [String: Any] = [:], headerOverrides: [String: Any] = [:]) throws -> String {
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": "synthetic-user", "aud": "oaiapp_synthetic_test", "nonce": "synthetic-nonce", "iat": now.timeIntervalSince1970, "exp": now.timeIntervalSince1970 + 300]
        claims.merge(overrides) { _, new in new }
        var header = ["alg": "RS256", "kid": "fixture", "typ": "JWT"] as [String: Any]
        header.merge(headerOverrides) { _, new in new }
        let text = SignInTransaction.base64URL(try JSONSerialization.data(withJSONObject: header)) + "." + SignInTransaction.base64URL(try JSONSerialization.data(withJSONObject: claims))
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(text.utf8) as CFData, nil) as Data?)
        return text + "." + SignInTransaction.base64URL(signature)
    }
    func jwks(keys: [[String: String]]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["keys": keys ?? [jwk]])
    }
}

@Test func signedIdentityAndClaimBinding() async throws {
    let fixture = try SignedFixture()
    let verifier = OpenAIIdentityVerifier()
    let identity = try await verifier.verify(idToken: fixture.token(), jwks: fixture.jwks(), configuration: config(), nonce: "synthetic-nonce", now: fixture.now)
    #expect(identity.subject == "synthetic-user")
    #expect(identity.clientID == "oaiapp_synthetic_test")
    for override in [
        ["iss": "https://attacker.invalid"], ["aud": "another-app"], ["nonce": "another-nonce"],
        ["sub": ""], ["exp": fixture.now.timeIntervalSince1970 - 1], ["iat": fixture.now.timeIntervalSince1970 + 60],
        ["nbf": fixture.now.timeIntervalSince1970 + 60], ["azp": "another-app"],
        ["aud": ["oaiapp_synthetic_test", "another-app"]]
    ] as [[String: Any]] {
        let token = try fixture.token(overrides: override)
        await #expect(throws: SignInError.invalidIdentity) { try await verifier.verify(idToken: token, jwks: fixture.jwks(), configuration: config(), nonce: "synthetic-nonce", now: fixture.now) }
    }
    let multiple = try fixture.token(overrides: ["aud": ["oaiapp_synthetic_test", "another-app"], "azp": "oaiapp_synthetic_test"])
    _ = try await verifier.verify(idToken: multiple, jwks: fixture.jwks(), configuration: config(), nonce: "synthetic-nonce", now: fixture.now)
}

@Test func untrustedAlgorithmsAndTokenKeyURLsAreRejected() async throws {
    let fixture = try SignedFixture()
    for header in [["alg": "none"], ["alg": "HS256"], ["kid": "unknown"], ["jku": "https://attacker.invalid/keys"], ["x5u": "https://attacker.invalid/cert"], ["b64": false], ["crit": ["unexpected"]]] as [[String: Any]] {
        let token = try fixture.token(headerOverrides: header)
        await #expect(throws: SignInError.invalidIdentity) { try await OpenAIIdentityVerifier().verify(idToken: token, jwks: fixture.jwks(), configuration: config(), nonce: "synthetic-nonce", now: fixture.now) }
    }
}

@Test func tamperedSignatureDuplicateKeysAndRotation() async throws {
    let fixture = try SignedFixture()
    let token = try fixture.token()
    let pieces = token.split(separator: ".")
    let tampered = pieces[0] + "." + pieces[1] + "." + SignInTransaction.base64URL(Data(repeating: 0, count: 256))
    await #expect(throws: SignInError.invalidIdentity) { try await OpenAIIdentityVerifier().verify(idToken: tampered, jwks: fixture.jwks(), configuration: config(), nonce: "synthetic-nonce", now: fixture.now) }
    await #expect(throws: SignInError.invalidIdentity) { try await OpenAIIdentityVerifier().verify(idToken: token, jwks: fixture.jwks(keys: [fixture.jwk, fixture.jwk]), configuration: config(), nonce: "synthetic-nonce", now: fixture.now) }
    // A fresh key with a fresh JWKS succeeds; a previously fetched key cannot.
    let rotated = try SignedFixture()
    let rotatedToken = try rotated.token()
    await #expect(throws: SignInError.invalidIdentity) { try await OpenAIIdentityVerifier().verify(idToken: rotatedToken, jwks: fixture.jwks(), configuration: config(), nonce: "synthetic-nonce", now: fixture.now) }
    _ = try await OpenAIIdentityVerifier().verify(idToken: rotatedToken, jwks: rotated.jwks(), configuration: config(), nonce: "synthetic-nonce", now: fixture.now)
}
