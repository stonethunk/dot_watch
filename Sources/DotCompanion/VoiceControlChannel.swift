#if os(iOS) || os(watchOS)
import Foundation
@preconcurrency import WatchConnectivity

@MainActor public enum VoiceControlChannel {
    public static func send(_ message: VoiceControl, timeout: Duration = .seconds(8)) async throws -> VoiceControl {
        let session = WCSession.default
        guard session.activationState == .activated else { throw VoiceControlError.unreachable }
        #if os(iOS)
        guard session.isReachable else { throw VoiceControlError.unreachable }
        #endif
        let data = try message.encoded()
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = ReplyGate(continuation)
            session.sendMessageData(data, replyHandler: { @Sendable data in
                Task { @MainActor in gate.finish(.success(data)) }
            }, errorHandler: { @Sendable _ in
                Task { @MainActor in gate.finish(.failure(VoiceControlError.unreachable)) }
            })
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.finish(.failure(VoiceControlError.timeout))
            }
        }
        let decoded = try VoiceControl.decode(response)
        guard decoded.matches(message) else { throw VoiceControlError.invalidMessage }
        if decoded.kind == .failed { throw VoiceControlError(rawValue: decoded.error ?? "") ?? .connectionFailed }
        return decoded
    }
}

@MainActor private final class ReplyGate {
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ value: CheckedContinuation<Data, Error>) { continuation = value }
    func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// SDK reply blocks may be invoked on either queue. Only a bounded control
/// envelope can leave this wrapper; no actor or UI state is captured.
public final class VoiceControlReply: @unchecked Sendable {
    private let block: (Data) -> Void
    private let lock = NSLock()
    private var sent = false
    public init(_ block: @escaping (Data) -> Void) { self.block = block }
    public func send(_ message: VoiceControl) {
        guard let data = try? message.encoded() else { return }
        lock.lock()
        let accepted = !sent
        sent = true
        lock.unlock()
        if accepted { block(data) }
    }
}
#endif
