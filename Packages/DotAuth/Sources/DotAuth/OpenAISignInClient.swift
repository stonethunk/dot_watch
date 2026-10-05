import Foundation

private final class NoAuthRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class OpenAISignInClient: Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: NoAuthRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func discover() async throws -> OpenAIMetadata {
        let data = try await request(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!))
        let metadata = try JSONDecoder().decode(OpenAIMetadata.self, from: data)
        try metadata.validate()
        return metadata
    }

    /// Identity-only public-client exchange. An ID token never becomes Dot API auth.
    public func complete(code: String, verifier: String, nonce: String,
                         configuration: OpenAIClientConfiguration, metadata: OpenAIMetadata) async throws -> OpenAIIdentity {
        try metadata.validate()
        var exchange = URLRequest(url: metadata.tokenEndpoint)
        exchange.httpMethod = "POST"
        exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        exchange.setValue("application/json", forHTTPHeaderField: "Accept")
        exchange.httpBody = Self.form([
            "grant_type": "authorization_code", "client_id": configuration.clientID,
            "code": code, "code_verifier": verifier, "redirect_uri": configuration.redirectURI.absoluteString,
        ])
        let response = try JSONDecoder().decode(TokenResponse.self, from: await request(exchange))
        let jwks = try await request(URLRequest(url: metadata.jwksURI))
        return try await OpenAIIdentityVerifier().verify(idToken: response.idToken, jwks: jwks,
            configuration: configuration, nonce: nonce)
    }

    private struct TokenResponse: Decodable {
        let idToken: String
        enum CodingKeys: String, CodingKey { case idToken = "id_token" }
    }
    private func request(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1024 * 1024 else { throw SignInError.network }
            return data
        } catch { throw SignInError.network }
    }
    private static func form(_ fields: [String: String]) -> Data {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let text = fields.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: safe)! + "=" + fields[key]!.addingPercentEncoding(withAllowedCharacters: safe)!
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}
