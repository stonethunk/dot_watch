import Foundation

public enum DotSurface: String, Sendable { case phone, watch, carPlay }

public enum DotSessionState: Sendable, Equatable {
    case idle
    case starting(DotSurface)
    case active(DotSurface, muted: Bool)
    case stopping(DotSurface)
    case blocked(DotSurface)

    public var surface: DotSurface? {
        switch self {
        case .idle: nil
        case .starting(let value), .active(let value, _), .stopping(let value), .blocked(let value): value
        }
    }
}

public protocol DotVoiceSignaling: Sendable {
    func create(dot: DotIdentity, offerSDP: String) async throws -> DotVoiceConnection
    func attach(_ call: DotVoiceConnection) async throws
    func stop(_ call: DotVoiceConnection) async throws
    var allocationNeedsReconciliation: Bool { get async }
}

extension DotVoiceAPI: DotVoiceSignaling {}

/// Media must not capture or play until enableAudio is called. close must immediately
/// discard buffers and release local audio, even if a server stop is still pending.
@MainActor public protocol DotVoiceMedia: AnyObject {
    func prepareOffer() async throws -> String
    func acceptAnswer(_ sdp: String) async throws
    func waitUntilReady() async throws
    func enableAudio(muted: Bool) async throws
    func setMuted(_ muted: Bool)
    func close()
    func waitUntilClosed() async throws
}

extension DotVoiceMedia {
    /// Native local media closes synchronously. Remote media must acknowledge.
    public func waitUntilClosed() async throws {}
}

/// Owns one microphone across phone and CarPlay, independently of their visible scenes.
/// Startup is allowed to finish its bounded HTTP operation after End so the allocated
/// call ID can still be stopped. A failed server stop blocks replacement sessions.
@MainActor public final class DotSessionCoordinator {
    public private(set) var state: DotSessionState = .idle { didSet { onChange?(state) } }
    public var onChange: ((DotSessionState) -> Void)?
    public var onError: ((String) -> Void)?
    private let signaling: any DotVoiceSignaling
    private var media: (any DotVoiceMedia)?
    private var call: DotVoiceConnection?
    private var operation: Task<Void, Never>?
    private var stopRequested = false
    private var pendingStart: (() -> Void)?
    private var pendingSurface: DotSurface?

    public init(signaling: any DotVoiceSignaling) { self.signaling = signaling }

    public func start(surface: DotSurface, dot: DotIdentity,
                      makeMedia: @escaping @MainActor () throws -> any DotVoiceMedia) {
        guard state != .blocked(state.surface ?? surface) else { return }
        guard state == .idle else {
            // Tapping Start twice cannot create duplicate calls. Transfers must receive
            // the previous call's stop acknowledgement before allocating another.
            guard state.surface != surface else { return }
            pendingStart = { [weak self] in self?.start(surface: surface, dot: dot, makeMedia: makeMedia) }
            pendingSurface = surface
            requestEnd(clearPending: false)
            return
        }
        stopRequested = false
        state = .starting(surface)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let transport = try makeMedia()
                self.media = transport
                let offer = try await transport.prepareOffer()
                try self.checkStarting()
                self.call = try await self.signaling.create(dot: dot, offerSDP: offer)
                try self.checkStarting()
                try await transport.acceptAnswer(self.call!.answerSDP)
                try self.checkStarting()
                try await self.signaling.attach(self.call!)
                try self.checkStarting()
                try await transport.waitUntilReady()
                try self.checkStarting()
                try await transport.enableAudio(muted: false)
                try self.checkStarting()
                self.state = .active(surface, muted: false)
                self.operation = nil
            } catch {
                if !self.stopRequested { self.onError?(Self.safeMessage(error)) }
                await self.release(surface: surface)
            }
        }
    }

    public func setMuted(_ muted: Bool) {
        guard case .active(let surface, _) = state else { return }
        media?.setMuted(muted)
        state = .active(surface, muted: muted)
    }

    public func end() { requestEnd(clearPending: true) }

    /// A Watch can cancel its queued start without ending the surface that is
    /// still being released. A newer queued surface must remain untouched.
    public func cancelPendingStart(for surface: DotSurface) {
        if pendingSurface == surface { pendingStart = nil; pendingSurface = nil }
    }

    /// Loss/interruption closes media immediately. No buffered speech is replayed.
    public func mediaFailed() { end() }

    private func requestEnd(clearPending: Bool) {
        if clearPending { pendingStart = nil; pendingSurface = nil }
        guard let surface = state.surface else { return }
        stopRequested = true
        media?.close()
        state = .stopping(surface)
        if operation == nil {
            operation = Task { [weak self] in await self?.release(surface: surface) }
        }
    }

    private func checkStarting() throws {
        if stopRequested { throw CancellationError() }
    }

    private func release(surface: DotSurface) async {
        media?.close()
        state = .stopping(surface)
        do {
            var closureFailed = false
            do { try await media?.waitUntilClosed() } catch { closureFailed = true }
            if let call { try await signaling.stop(call); self.call = nil }
            guard !closureFailed else { throw DotError.disconnected }
            guard !(await signaling.allocationNeedsReconciliation) else { throw DotError.callAlreadyActive }
            media = nil
            state = .idle
            operation = nil
            let next = pendingStart
            pendingStart = nil
            pendingSurface = nil
            next?()
        } catch {
            pendingStart = nil
            pendingSurface = nil
            state = .blocked(surface)
            operation = nil
            onError?("Audio is off. The previous connection could not be released; retry End before starting again.")
        }
    }

    private static func safeMessage(_ error: any Error) -> String {
        (error as? DotError)?.description ?? "Voice could not connect. Please try again."
    }
}
