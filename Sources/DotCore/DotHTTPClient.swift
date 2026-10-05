import Foundation
import CryptoKit

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Experimental endpoints are isolated here. No persisted cookies, cache, or redirects.
public final class DotHTTPClient: Sendable {
    private let session: URLSession
    private let credentials: ChatGPTCredentials

    public init(credentials: ChatGPTCredentials) {
        self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    init(credentials: ChatGPTCredentials, session: URLSession) {
        self.credentials = credentials
        self.session = session
    }

    deinit { session.invalidateAndCancel() }

    public func discover() async throws -> DotIdentity {
        try DotIdentity(primary: await authenticatedJSON(EndpointPolicy.api.appendingPathComponent("tbo/primary")))
    }

    public func verifyThread(_ dot: DotIdentity) async throws {
        let url = EndpointPolicy.cloud.appendingPathComponent("v1/threads").appendingPathComponent(dot.threadID)
        let response = try await authenticatedJSON(url)
        guard response["thread"]["id"].string == dot.threadID else { throw DotError.identityMismatch }
    }

    public func snapshot(_ dot: DotIdentity) async throws -> Data {
        try EndpointPolicy.validateSnapshot(dot.snapshotURL)
        // Signed asset URLs are sufficient. Never send account authorization to the CDN.
        var request = URLRequest(url: dot.snapshotURL)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard data.count <= 16 * 1024 * 1024 else { throw DotError.invalidResponse }
        guard Self.sha256(data) == dot.snapshotSHA256 else { throw DotError.snapshotMismatch }
        return data
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func authenticatedJSON(_ url: URL) async throws -> JSONValue {
        let (data, response) = try await authenticatedRequest(url)
        try Self.check(response)
        return try JSONValue.decode(data)
    }

    func authenticatedRequest(_ url: URL, method: String = "GET", body: JSONValue? = nil) async throws -> (Data, HTTPURLResponse) {
        try EndpointPolicy.validateAuthenticated(url)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex", forHTTPHeaderField: "X-OpenAI-Product-Sku")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DotWatchDiagnostic/0.1", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.encoded()
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DotError.invalidResponse }
        guard data.count <= 8 * 1024 * 1024 else { throw DotError.invalidResponse }
        return (data, response)
    }

    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw DotError.invalidResponse }
        guard response.statusCode == 200 else { throw DotError.http(response.statusCode) }
    }
}
