import Foundation
import AVFAudio
import DotCore
@preconcurrency import PhoneWebRTC

@MainActor final class NativeVoiceMedia: NSObject, DotVoiceMedia {
    private let surface: DotSurface
    private let factory: RTCPeerConnectionFactory
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var input: RTCAudioTrack?
    private var closed = false
    private var audioActivated = false
    private var meterTask: Task<Void, Never>?
    var onFailure: (() -> Void)?
    var onEvent: ((DotVoiceEvent) -> Void)?
    var onLevel: ((Double) -> Void)?

    init(surface: DotSurface) {
        self.surface = surface
        RTCSetMinDebugLogLevel(.none)
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory()
        super.init()
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
    }

    func prepareOffer() async throws -> String {
        guard !closed else { throw DotError.disconnected }
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.iceServers = []
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self) else { throw DotError.invalidResponse }
        self.peer = peer
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: "dot-microphone")
        track.isEnabled = false
        input = track
        peer.add(track, streamIds: ["dot-voice"])
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else { throw DotError.invalidResponse }
        channel.delegate = self
        self.channel = channel
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)) { offer, _ in
                if let offer { continuation.resume(returning: offer) }
                else { continuation.resume(throwing: DotError.invalidResponse) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in
                if error != nil { continuation.resume(throwing: DotError.invalidResponse) }
                else { continuation.resume() }
            }
        }
        // REST signaling has no trickle endpoint. Include gathered candidates.
        try await wait(seconds: 10) { peer.iceGatheringState == .complete }
        guard let sdp = peer.localDescription?.sdp else { throw DotError.invalidResponse }
        return sdp
    }

    func acceptAnswer(_ sdp: String) async throws {
        guard !closed, let peer else { throw DotError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                if error != nil { continuation.resume(throwing: DotError.invalidResponse) }
                else { continuation.resume() }
            }
        }
    }

    func waitUntilReady() async throws {
        try await wait(seconds: 25) { [self] in peer?.connectionState == .connected && channel?.readyState == .open }
    }

    func enableAudio(muted: Bool) throws {
        guard !closed, peer?.connectionState == .connected else { throw DotError.disconnected }
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.default.rawValue
        configuration.categoryOptions = surface == .carPlay ? [] : [.allowBluetoothHFP, .defaultToSpeaker]
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.setConfiguration(configuration, active: true)
        audioActivated = true
        input?.isEnabled = !muted
        session.isAudioEnabled = true
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleLevel()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func setMuted(_ muted: Bool) { input?.isEnabled = !muted && !closed }

    func close() {
        guard !closed else { return }
        closed = true
        input?.isEnabled = false
        meterTask?.cancel()
        meterTask = nil
        let session = RTCAudioSession.sharedInstance()
        session.isAudioEnabled = false
        channel?.delegate = nil
        channel?.close()
        channel = nil
        peer?.delegate = nil
        peer?.close()
        peer = nil
        input = nil
        if audioActivated {
            session.lockForConfiguration()
            try? session.setActive(false)
            session.unlockForConfiguration()
            audioActivated = false
        }
        onLevel?(0)
    }

    private func wait(seconds: Int, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !ready() {
            guard !closed, peer?.connectionState != .failed else { throw DotError.disconnected }
            guard ContinuousClock.now < deadline else { throw DotError.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !closed else { throw DotError.disconnected }
    }

    private func sampleLevel() {
        peer?.statistics { [weak self] report in
            let level = report.statistics.values.filter { $0.type == "inbound-rtp" }
                .compactMap { $0.values["audioLevel"] as? NSNumber }.map(\.doubleValue).max() ?? 0
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.onLevel?(min(1, max(0, level)))
            }
        }
    }
}

extension NativeVoiceMedia: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        if newState == .failed || newState == .disconnected {
            Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.onFailure?() }
        }
    }
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed {
            Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.onFailure?() }
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let event = try? DotVoiceEvent(data: buffer.data) else { return }
        Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.onEvent?(event) }
    }
}
