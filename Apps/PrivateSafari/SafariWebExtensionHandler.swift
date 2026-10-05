import Foundation
import SafariServices
import DotCore

/// Safari routes native messages only from this app's own signed extension.
/// Nothing is read from the official ChatGPT application's Keychain.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
              message["operation"] as? String == "connect",
              let credentials = message["credentials"] as? [String: Any],
              let token = credentials["access_token"] as? String, token.utf8.count <= 60_000,
              let account = credentials["account_id"] as? String, account.utf8.count <= 128,
              let data = try? JSONSerialization.data(withJSONObject: ["access_token": token, "account_id": account]),
              let transfer = try? PrivateCredentialTransfer(data: data, existingAccountID: nil) else {
            Self.reply(context, code: "invalid_session")
            return
        }
        let reply = ReplyContext(context)
        Task {
            do {
                // Server authentication, Dot discovery and conversation validation
                // establish actual access; locally decoded JWT claims are only a
                // routing hint. This does not start voice or alter a conversation.
                let http = DotHTTPClient(credentials: transfer.credentials)
                let dot = try await http.discover()
                try await http.verifyThread(dot)
                try await BrowserStagingWorker.shared.stage(transfer)
                reply.complete(code: "ready")
            } catch {
                if (error as? DotError) == .accountChangeRequiresSignOut { reply.complete(code: "sign_out_first") }
                else { reply.complete(code: "access_unavailable") }
            }
        }
    }

    private static func reply(_ context: NSExtensionContext, code: String) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: ["ok": code == "ready", "code": code]]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    private final class ReplyContext: @unchecked Sendable {
        let context: NSExtensionContext
        init(_ context: NSExtensionContext) { self.context = context }
        func complete(code: String) { SafariWebExtensionHandler.reply(context, code: code) }
    }
}

private actor BrowserStagingWorker {
    static let shared = BrowserStagingWorker()
    func stage(_ transfer: PrivateCredentialTransfer) throws { try PrivateBrowserStaging.stage(transfer) }
}
