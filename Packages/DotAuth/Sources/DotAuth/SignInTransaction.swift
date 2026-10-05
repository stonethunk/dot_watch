import Foundation
import CryptoKit
import Security

public enum SignInError: Error, Sendable, Equatable {
    case notConfigured, invalidMetadata, invalidCallback, expiredTransaction, consumedTransaction
    case denied, invalidIdentity, network, randomGeneration, busy
}

public struct OpenAIClientConfiguration: Sendable {
    public let clientID: String
    public let redirectURI: URL
    public init(clientID: String, redirectURI: URL) throws {
        guard clientID.hasPrefix("oaiapp_"), clientID.count <= 256,
              clientID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let scheme = redirectURI.scheme,
              scheme == "https" || scheme.range(of: "^[a-z][a-z0-9-]*(\\.[a-z0-9-]+){2,}$", options: .regularExpression) != nil,
              redirectURI.host != nil, redirectURI.port == nil,
              redirectURI.user == nil, redirectURI.password == nil,
              redirectURI.query == nil, redirectURI.fragment == nil,
              !redirectURI.path.isEmpty else { throw SignInError.notConfigured }
        self.clientID = clientID; self.redirectURI = redirectURI
    }
}

public struct OpenAIMetadata: Decodable, Sendable {
    public let issuer: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let jwksURI: URL
    enum CodingKeys: String, CodingKey {
        case issuer, authorizationEndpoint = "authorization_endpoint", tokenEndpoint = "token_endpoint", jwksURI = "jwks_uri"
    }
    public func validate() throws {
        guard issuer == "https://auth.openai.com" else { throw SignInError.invalidMetadata }
        for url in [authorizationEndpoint, tokenEndpoint, jwksURI] {
            guard url.scheme == "https", url.host == "auth.openai.com",
                  url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
                  url.port == nil || url.port == 443 else { throw SignInError.invalidMetadata }
        }
    }
}

/// A one-use transaction, confined to the native UI's actor. Tokens and state never
/// enter user defaults, browser scripts, logs, or an app-owned password form.
@MainActor public final class SignInTransaction {
    public let state: String
    public let nonce: String
    public let verifier: String
    public let challenge: String
    public let configuration: OpenAIClientConfiguration
    private let expires: Date
    private var consumed = false

    public init(configuration: OpenAIClientConfiguration, now: Date = Date()) throws {
        self.configuration = configuration
        state = try Self.random(32); nonce = try Self.random(32); verifier = try Self.random(64)
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        expires = now.addingTimeInterval(600)
    }

    public func authorizationURL(metadata: OpenAIMetadata) throws -> URL {
        try metadata.validate()
        guard !consumed else { throw SignInError.consumedTransaction }
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "code_challenge", value: challenge),
        ]
        guard let url = components.url else { throw SignInError.invalidMetadata }
        return url
    }

    public func consume(callback: URL, now: Date = Date()) throws -> String {
        guard !consumed else { throw SignInError.consumedTransaction }
        consumed = true
        guard now < expires else { throw SignInError.expiredTransaction }
        guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: configuration.redirectURI, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host, actual.port == expected.port,
              actual.percentEncodedPath == expected.percentEncodedPath,
              actual.user == nil, actual.password == nil, actual.fragment == nil else { throw SignInError.invalidCallback }
        let items = actual.queryItems ?? []
        func one(_ key: String) -> String? {
            let matches = items.filter { $0.name == key }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard one("state") == state else { throw SignInError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw SignInError.denied }
        guard let code = one("code"), !code.isEmpty, code.utf8.count <= 8192 else { throw SignInError.invalidCallback }
        return code
    }

    public func cancel() { consumed = true }
    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func random(_ count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw SignInError.randomGeneration }
        return base64URL(Data(bytes))
    }
}
