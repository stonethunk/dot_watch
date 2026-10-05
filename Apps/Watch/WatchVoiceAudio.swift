#if PERSONAL_DIAGNOSTICS
import AVFAudio
import SwiftUI
import WatchAudioKit

/// User-started live audio. MainActor serializes converters and playback;
/// the actual microphone callback only copies into its Sendable bounded buffer.
@MainActor final class WatchVoiceAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var capture: StreamingCaptureBuffer?
    private var codec: NativeOpusCodec?
    private var resampler: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var inputFrames = StreamingPCMFramer()
    private var heldBuffers: [UUID: AVAudioPCMBuffer] = [:]
    private var connectingBuffer: AVAudioPCMBuffer?
    private let playbackFrames = PlaybackFrameCounter()
    private var tapInstalled = false
    private var sessionActive = false
    private var activating = false
    private var started = false
    private var muted = true
    private(set) var capturedFrames = 0
    private(set) var playedFrames = 0
    private(set) var resampledFrames = 0
    private(set) var encodedFrames = 0
    private(set) var emptyPlaybackRefills = 0
    private(set) var level = 0.0
    var queuedPlaybackFrames: Int { playbackFrames.frames }
    var captureSampleRate: Double { inputFormat?.sampleRate ?? 0 }
    var droppedCaptureFrames: Int { capture?.droppedFrames ?? finalDroppedCaptureFrames }
    var droppedResampledFrames: Int { inputFrames.droppedFrames }
    private var finalDroppedCaptureFrames = 0
    var fullyClosed: Bool { !sessionActive && !activating && engine == nil }

    func prepare() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw WatchVoiceFailure.permission }
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        activating = true
        defer { activating = false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { @Sendable active, _ in
                if active { continuation.resume() }
                else { continuation.resume(throwing: WatchVoiceFailure.audio) }
            }
        }
        sessionActive = true
        try Task.checkCancellation()
        let codec = try NativeOpusCodec()
        self.codec = codec
        let engine = AVAudioEngine()
        self.engine = engine
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard (1...2).contains(format.channelCount), format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let resampler = AVAudioConverter(from: mono, to: codec.pcmFormat) else { throw WatchVoiceFailure.audio }
        inputFormat = mono
        self.resampler = resampler
        resampler.primeMethod = .none
        let capture = try StreamingCaptureBuffer(sampleRate: format.sampleRate)
        capture.setMuted(true)
        self.capture = capture
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format,
                                   block: StreamingCaptureBuffer.tap(into: capture))
        tapInstalled = true
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: codec.pcmFormat)
        engine.prepare()
    }

    func enable(muted: Bool) throws {
        guard let engine, sessionActive else { throw WatchVoiceFailure.audio }
        stopConnectingTone()
        if !started { try engine.start(); player?.play(); started = true }
        setMuted(muted)
    }
    /// Local ringback only. The input tap discards samples while connecting,
    /// and no RTP is sent until the authenticated session is ready.
    func startConnectingTone() throws {
        guard let engine, let player, let codec, sessionActive, connectingBuffer == nil else { throw WatchVoiceFailure.audio }
        setMuted(true)
        let frames = ConnectingTone.frameCount
        guard let buffer = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { throw WatchVoiceFailure.audio }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { samples[index] = ConnectingTone.sample(at: index) }
        connectingBuffer = buffer
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        if !started { try engine.start(); started = true }
        player.play()
    }
    private func stopConnectingTone() {
        guard let buffer = connectingBuffer else { return }
        player?.stop()
        connectingBuffer = nil
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
        if started { player?.play() }
    }
    func setMuted(_ muted: Bool) {
        self.muted = muted
        capture?.setMuted(muted)
        clearInput()
        resampler?.reset()
        codec?.resetEncoder()
    }

    /// Drain up to 60 ms of fresh speech after a delayed tick. The microphone
    /// clock determines available frames; a UI scheduling delay cannot slow it.
    func outgoing() throws -> [Data] {
        guard started, let codec else { return [] }
        // Keep RTP time and server turn detection running while muted. These
        // packets contain generated silence, never a retained microphone sample.
        if muted { return try codec.encode(Array(repeating: 0, count: NativeOpusCodec.frameCount)) }
        guard let capture, let resampler, let inputFormat else { return [] }
        guard !capture.invalidInput else { throw WatchVoiceFailure.audio }
        var samples = capture.drain()
        defer { samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; samples.removeAll() }
        capturedFrames += samples.count
        if !samples.isEmpty {
            guard let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                  let input = source.floatChannelData?[0],
                  let output = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: 8_192) else { throw WatchVoiceFailure.audio }
            source.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { input.update(from: $0.baseAddress!, count: $0.count) }
            defer { input.update(repeating: 0, count: samples.count); output.floatChannelData?[0].update(repeating: 0, count: Int(output.frameLength)) }
            var supplied = false
            var failure: NSError?
            let status = resampler.convert(to: output, error: &failure) { _, state in
                guard !supplied else { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return source
            }
            guard status != .error, failure == nil, let channel = output.floatChannelData?[0] else { throw WatchVoiceFailure.audio }
            resampledFrames += Int(output.frameLength)
            inputFrames.append(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        }
        var packets: [Data] = []
        var frames = inputFrames.takeFrames()
        defer { for index in frames.indices { frames[index].withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) } } }
        for frame in frames { packets += try codec.encode(frame); encodedFrames += frame.count }
        return packets
    }

    func interruptPlayback() {
        player?.stop()
        for buffer in heldBuffers.values { buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength)) }
        heldBuffers.removeAll(); playbackFrames.clear(); level = 0
        if started { player?.play() }
    }

    func play(_ packet: Data) throws {
        guard started, let codec, let player else { return }
        var samples = try codec.decode(packet)
        defer { samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; samples.removeAll() }
        guard !samples.isEmpty else { return }
        // Bound latency to 240 ms; discard received audio rather than growing
        // an unbounded scheduled queue after suspension or a delayed callback.
        guard playbackFrames.frames + samples.count <= 11_520 else { return }
        guard let output = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = output.floatChannelData?[0] else { throw WatchVoiceFailure.audio }
        output.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let id = UUID(), frames = samples.count
        if playbackFrames.frames == 0, playedFrames > 0 { emptyPlaybackRefills += 1 }
        heldBuffers[id] = output
        let counter = playbackFrames
        let generation = counter.enqueue(frames)
        playedFrames += frames
        level = min(1, Double(samples.map(abs).max() ?? 0) * 3)
        player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            counter.complete(frames, generation: generation)
            Task { @MainActor in
                guard let self, let buffer = self.heldBuffers.removeValue(forKey: id) else { return }
                buffer.floatChannelData?[0].update(repeating: 0, count: frames)
                if self.playbackFrames.frames == 0 { self.level = 0 }
            }
        }
    }

    @discardableResult func close() -> Bool {
        finalDroppedCaptureFrames = capture?.droppedFrames ?? finalDroppedCaptureFrames
        capture?.close(); capture = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        stopConnectingTone()
        player?.stop(); player?.reset(); player = nil
        engine?.stop(); engine?.reset(); engine = nil
        for buffer in heldBuffers.values { buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength)) }
        heldBuffers.removeAll(); playbackFrames.clear(); level = 0; started = false
        clearInput(); codec?.reset(); codec = nil; resampler = nil
        if sessionActive {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); sessionActive = false }
            catch { /* Retry End; never acknowledge a still-active audio session. */ }
        }
        return fullyClosed
    }
    private func clearInput() {
        inputFrames.clear()
    }
}

enum WatchVoiceFailure: String, Error { case permission, audio, noPairing, phone, transport, lease, stopped }
#endif
