import AuthenticationServices
import UIKit
import DotAuth

enum PublicSignInConfiguration {
    /// Set only after OpenAI registers this native public client and its exact
    /// callback. A client ID is public; no client secret belongs in an app.
    static var current: OpenAIClientConfiguration? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "DotOpenAIClientID") as? String,
              let text = Bundle.main.object(forInfoDictionaryKey: "DotOpenAIRedirectURI") as? String,
              let uri = URL(string: text), uri.scheme == "dev.dotwatch.app.auth" else { return nil }
        return try? OpenAIClientConfiguration(clientID: id, redirectURI: uri)
    }
}

@MainActor final class OpenAISignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var window: UIWindow?
    private var running = false

    func signIn(configuration: OpenAIClientConfiguration) async throws -> OpenAIIdentity {
        guard !running else { throw SignInError.busy }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow }) else { throw SignInError.denied }
        running = true
        self.window = window
        defer { running = false; self.window = nil; session = nil }
        let transaction = try SignInTransaction(configuration: configuration)
        let client = OpenAISignInClient()
        do {
            let metadata = try await client.discover()
            try Task.checkCancellation()
            let url = try transaction.authorizationURL(metadata: metadata)
            let callback = try await withTaskCancellationHandler {
                try await authorize(url: url, scheme: configuration.redirectURI.scheme!)
            } onCancel: {
                Task { @MainActor [weak self] in self?.session?.cancel() }
            }
            let code = try transaction.consume(callback: callback)
            try Task.checkCancellation()
            return try await client.complete(code: code, verifier: transaction.verifier, nonce: transaction.nonce,
                                            configuration: configuration, metadata: metadata)
        } catch {
            transaction.cancel()
            throw (error as? SignInError) ?? SignInError.network
        }
    }

    private func authorize(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if error != nil { continuation.resume(throwing: SignInError.denied) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: SignInError.invalidCallback) }
            }
            session.presentationContextProvider = self
            // OpenAI owns the login screen. Existing system-browser sign-in can
            // be reused; this app never reads browser cookies or passwords.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: SignInError.denied)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window!
    }
}
