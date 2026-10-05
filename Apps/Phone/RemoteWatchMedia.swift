#if PERSONAL_DIAGNOSTICS
import Foundation
import DotCore
import DotCompanion

/// The phone owns allocation/stop through its Keychain account; only ephemeral
/// SDP/control crosses WatchConnectivity. No phone microphone is opened here.
@MainActor final class RemoteWatchMedia: DotVoiceMedia {
    let request: VoiceControl
    private let reply: VoiceControlReply
    private var answer: String?
    private var ready = false
    private var closed = false
    private var closeAcknowledged = false
    private var closeTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var muteTask: Task<Void, Never>?
    private var desiredMute: Bool?
    private var lastLease = ContinuousClock.now
    var onFailure: (() -> Void)?

    init(request: VoiceControl, reply: VoiceControlReply) { self.request = request; self.reply = reply }
    func prepareOffer() async throws -> String {
        guard !closed, let sdp = request.sdp else { throw DotError.disconnected }
        return sdp
    }
    func acceptAnswer(_ sdp: String) async throws {
        guard !closed, sdp.utf8.count <= 32 * 1024 else { throw DotError.invalidResponse }
        answer = sdp
    }
    func waitUntilReady() async throws {
        guard !closed, let answer else { throw DotError.disconnected }
        reply.send(request.reply(.answer, sdp: answer))
        self.answer = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !ready {
            guard !closed else { throw DotError.disconnected }
            guard ContinuousClock.now < deadline else { throw DotError.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func acknowledgeReady() { ready = true; lastLease = .now }
    func heartbeat() { lastLease = .now }
    func enableAudio(muted: Bool) async throws {
        guard !closed, ready else { throw DotError.disconnected }
        let activation = VoiceControl(.activate, sessionID: request.sessionID, muted: muted)
        let response = try await VoiceControlChannel.send(activation)
        guard !closed, response.kind == .ack else { throw DotError.disconnected }
        lastLease = .now
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.closed else { return }
                if ContinuousClock.now - self.lastLease > .seconds(12) { self.onFailure?(); return }
            }
        }
    }
    func setMuted(_ muted: Bool) {
        guard !closed else { return }
        desiredMute = muted
        guard muteTask == nil else { return }
        muteTask = Task { [weak self] in
            guard let self else { return }
            defer { self.muteTask = nil }
            do {
                while !self.closed, let desired = self.desiredMute {
                    self.desiredMute = nil
                    let response = try await VoiceControlChannel.send(VoiceControl(.mute, sessionID: request.sessionID, muted: desired))
                    guard response.kind == .ack else { throw DotError.disconnected }
                }
            } catch { if !self.closed { self.onFailure?() } }
        }
    }
    func acknowledgeClosed() { closeAcknowledged = true }
    func close() {
        closed = true; watchdog?.cancel(); watchdog = nil; answer = nil
        desiredMute = nil; muteTask?.cancel()
        reply.send(request.reply(.failed, error: .connectionFailed))
        guard !closeAcknowledged, closeTask == nil else { return }
        closeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.closeTask = nil }
            do {
                let result = try await VoiceControlChannel.send(VoiceControl(.end, sessionID: self.request.sessionID))
                if result.kind == .closed { self.closeAcknowledged = true }
            } catch { /* A missing Watch stop acknowledgement blocks transfer. */ }
        }
    }
    func waitUntilClosed() async throws {
        await closeTask?.value
        guard closeAcknowledged else { throw DotError.disconnected }
    }
}
#endif
