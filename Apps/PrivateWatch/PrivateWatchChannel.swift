#if PERSONAL_DIAGNOSTICS && (os(iOS) || os(watchOS))
import Foundation
@preconcurrency import WatchConnectivity

@MainActor enum PrivateWatchChannel {
    static func send(_ message: PrivateWatchMessage, timeout: Duration = .seconds(35)) async throws -> PrivateWatchMessage {
        let session = WCSession.default
        guard session.activationState == .activated else { throw PrivateWatchError.unreachable }
        #if os(iOS)
        guard session.isReachable else { throw PrivateWatchError.unreachable }
        #endif
        let data = try message.encoded()
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = PrivateWatchReplyGate(continuation)
            session.sendMessageData(data, replyHandler: { @Sendable data in
                Task { @MainActor in gate.finish(.success(data)) }
            }, errorHandler: { @Sendable _ in
                Task { @MainActor in gate.finish(.failure(PrivateWatchError.unreachable)) }
            })
            Task { @MainActor in
                try? await Task.sleep(for: timeout); gate.finish(.failure(PrivateWatchError.timeout))
            }
        }
        let decoded = try PrivateWatchMessage.decode(response)
        guard decoded.requestID == message.requestID else { throw PrivateWatchError.invalid }
        if decoded.kind == .failed { throw decoded.error ?? .invalid }
        return decoded
    }
}
@MainActor private final class PrivateWatchReplyGate {
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ value: CheckedContinuation<Data, Error>) { continuation = value }
    func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }; self.continuation = nil; continuation.resume(with: result)
    }
}
final class PrivateWatchReply: @unchecked Sendable {
    private let block: (Data) -> Void
    private let lock = NSLock()
    private var sent = false
    init(_ block: @escaping (Data) -> Void) { self.block = block }
    func send(_ message: PrivateWatchMessage) {
        guard let data = try? message.encoded() else { return }
        lock.lock(); let accepted = !sent; sent = true; lock.unlock()
        if accepted { block(data) }
    }
}
#endif
