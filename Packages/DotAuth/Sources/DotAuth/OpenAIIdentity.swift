import Foundation
import JWTKit

public struct OpenAIIdentity: Codable, Sendable, Equatable {
    public let issuer: String
    public let clientID: String
    public let subject: String
    public let email: String?
    public let name: String?
    public let authenticatedAt: Date
    public let validUntil: Date
    // This is verified application identity, never a credential for Dot endpoints.
}

enum TokenAudience: Codable, Sendable {
    case one(String), many([String])
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let one = try? value.decode(String.self) { self = .one(one) }
        else { self = .many(try value.decode([String].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .one(let one): try value.encode(one); case .many(let many): try value.encode(many) }
    }
    var values: [String] { switch self { case .one(let one): [one]; case .many(let many): many } }
}

struct IdentityToken: JWTPayload {
    let iss: String
    let sub: String
    let aud: TokenAudience
    let exp: Double
    let iat: Double
    let nbf: Double?
    let nonce: String
    let azp: String?
    let email: String?
    let name: String?
    func verify(using algorithm: some JWTAlgorithm) throws {
        guard exp.isFinite, iat.isFinite, nbf?.isFinite != false else { throw SignInError.invalidIdentity }
    }
}

public struct OpenAIIdentityVerifier: Sendable {
    public init() {}
    public func verify(idToken: String, jwks: Data, configuration: OpenAIClientConfiguration,
                       nonce: String, now: Date = Date()) async throws -> OpenAIIdentity {
        guard idToken.utf8.count <= 128 * 1024, jwks.count <= 1024 * 1024 else { throw SignInError.invalidIdentity }
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let headerData = Self.decodeURL(String(segments[0])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String, !kid.isEmpty,
              header["crit"] == nil, header["jku"] == nil, header["x5u"] == nil, header["b64"] == nil,
              let document = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = document["keys"] as? [[String: Any]] else { throw SignInError.invalidIdentity }
        // Bind kid to exactly one issuer-supplied public signing key. Never follow
        // a key URL supplied inside the token or accept symmetric/none algorithms.
        let matches = keys.filter { $0["kid"] as? String == kid }
        guard matches.count == 1, let key = matches.first,
              key["kty"] as? String == "RSA", key["d"] == nil,
              key["alg"] == nil || key["alg"] as? String == "RS256",
              key["use"] == nil || key["use"] as? String == "sig",
              let modulus = key["n"] as? String, let modulusData = Self.decodeURL(modulus),
              (256...1024).contains(modulusData.count),
              let exponent = key["e"] as? String, Self.decodeURL(exponent) != nil else { throw SignInError.invalidIdentity }
        if let value = key["key_ops"] {
            guard let operations = value as? [String], operations.contains("verify") else { throw SignInError.invalidIdentity }
        }
        let filtered = try JSONSerialization.data(withJSONObject: ["keys": [key]])
        guard let json = String(data: filtered, encoding: .utf8) else { throw SignInError.invalidIdentity }
        let collection = JWTKeyCollection()
        let token: IdentityToken
        do {
            try await collection.add(jwksJSON: json)
            token = try await collection.verify(idToken, as: IdentityToken.self)
        } catch { throw SignInError.invalidIdentity }
        let time = now.timeIntervalSince1970
        guard token.iss == "https://auth.openai.com", !token.sub.isEmpty, token.sub.utf8.count <= 1024,
              token.aud.values.contains(configuration.clientID),
              token.aud.values.count == 1 || token.azp == configuration.clientID,
              token.azp == nil || token.azp == configuration.clientID,
              token.nonce == nonce, token.exp > time, token.iat <= time + 5,
              token.exp > token.iat, token.nbf == nil || token.nbf! <= time + 5 else { throw SignInError.invalidIdentity }
        return OpenAIIdentity(issuer: token.iss, clientID: configuration.clientID, subject: token.sub,
                              email: token.email, name: token.name, authenticatedAt: now,
                              validUntil: Date(timeIntervalSince1970: token.exp))
    }

    private static func decodeURL(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
}
