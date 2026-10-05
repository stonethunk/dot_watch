#if PERSONAL_DIAGNOSTICS
import SwiftUI
import AVFAudio
import Synchronization
import WatchAudioKit

/// Explicit, foreground-only hardware probe. No credentials, network or audio file.
@MainActor final class WatchAudioDiagnostic: ObservableObject {
    enum StopReason: String {
        case user, screenDimmed = "screen_dimmed", appInactive = "app_inactive"
        case viewClosed = "view_closed", interruption, outputRemoved = "output_removed", mediaReset = "media_reset"
    }

    @Published private(set) var message = "Record five seconds, then hear them back. The sample stays on this Watch."
    @Published private(set) var busy = false
    private var operation: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var capture: BoundedCaptureBuffer?
    private var playbackBuffer: AVAudioPCMBuffer?
    private var tapInstalled = false
    private var sessionActive = false
    private var foregroundActive = false
    private var observers: [NSObjectProtocol] = []
    private var evidence: [String: Any] = [:]

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue
            if began { Task { @MainActor in self?.stop(reason: .interruption) } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let removed = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            if removed { Task { @MainActor in self?.stop(reason: .outputRemoved) } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: .mediaReset) }
        })
    }

    func start() {
        guard operation == nil, !sessionActive else { return }
        busy = true
        message = "Preparing microphone…"
        evidence = ["schema": 2, "probe": "watch_local_audio", "network_opened": false,
                    "started_at": ISO8601DateFormatter().string(from: Date()),
                    "audio_file_written": false, "credentials_used": false,
                    "capture_started": false, "capture_stopped": false,
                    "codec_round_trip": false, "playback_started": false, "playback_completed": false]
        operation = Task { [weak self] in await self?.run() }
    }

    func stop(reason: StopReason = .user) {
        guard operation != nil || sessionActive else { return }
        if evidence["stop_reason"] == nil { evidence["stop_reason"] = reason.rawValue }
        operation?.cancel()
        releaseAudio()
        busy = operation != nil || sessionActive
        message = busy ? "Ending audio test…" : "Audio test ended. The sample was discarded."
        saveEvidence()
        // An outstanding system permission/activation callback must finish before
        // another test starts, so late activation cannot revive a stopped test.
    }

    func sceneChanged(active: Bool, dimmed: Bool) {
        foregroundActive = active && !dimmed
        // The system microphone permission sheet can briefly make the scene
        // inactive. Do not cancel permission itself; never capture while dimmed.
        if !foregroundActive && sessionActive { stop(reason: dimmed ? .screenDimmed : .appInactive) }
    }

    private func run() async {
        defer {
            releaseAudio()
            operation = nil
            busy = sessionActive
            if sessionActive { message = "Audio is off, but its session needs another stop. Tap Stop audio test." }
            saveEvidence()
        }
        var phase = "permission"
        do {
            checkpoint("permission")
            guard await AVAudioApplication.requestRecordPermission() else { throw ProbeError.permission }
            try Task.checkCancellation()
            let foregroundDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !foregroundActive {
                try Task.checkCancellation()
                guard ContinuousClock.now < foregroundDeadline else { throw ProbeError.foreground }
                try await Task.sleep(for: .milliseconds(50))
            }
            phase = "session"
            checkpoint("session_activation")
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.activate(options: []) { @Sendable active, _ in
                    if active { continuation.resume() }
                    else { continuation.resume(throwing: ProbeError.session) }
                }
            }
            sessionActive = true
            try Task.checkCancellation()
            guard foregroundActive else { throw ProbeError.foreground }
            // Establish codec availability before opening the microphone.
            _ = try NativeOpusCodec()
            phase = "capture"
            checkpoint("capture_setup")
            let captureEngine = AVAudioEngine()
            engine = captureEngine
            try captureEngine.inputNode.setVoiceProcessingEnabled(true)
            let format = captureEngine.inputNode.outputFormat(forBus: 0)
            guard (8_000...96_000).contains(format.sampleRate), (1...2).contains(format.channelCount),
                  format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw ProbeError.format }
            let recorder = try BoundedCaptureBuffer(sampleRate: format.sampleRate)
            capture = recorder
            captureEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format,
                block: WatchAudioCallbacks.captureTap(into: recorder))
            tapInstalled = true
            captureEngine.prepare()
            checkpoint("engine_start")
            try captureEngine.start()
            evidence["capture_started"] = true
            checkpoint("recording")
            for remaining in (1...5).reversed() {
                message = "Recording: \(remaining) seconds. Keep your wrist raised."
                try await Task.sleep(for: .seconds(1))
            }
            var samples = recorder.take()
            defer { samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; samples.removeAll() }
            stopEngine()
            evidence["capture_stopped"] = true
            evidence["captured_frames"] = samples.count
            guard !samples.isEmpty, !recorder.invalidInput else { throw ProbeError.capture }
            phase = "codec"
            checkpoint("codec")
            message = "Checking audio…"
            let result = try await roundTrip(samples, sampleRate: format.sampleRate)
            playbackBuffer = result.buffer
            evidence["encoded_packets"] = result.packets
            evidence["decoded_frames"] = result.buffer.frameLength
            evidence["input_signal_present"] = result.signalPresent
            evidence["codec_round_trip"] = true
            try Task.checkCancellation()
            phase = "playback"
            let playbackEngine = AVAudioEngine()
            let playback = AVAudioPlayerNode()
            engine = playbackEngine
            player = playback
            playbackEngine.attach(playback)
            playbackEngine.connect(playback, to: playbackEngine.mainMixerNode, format: result.buffer.format)
            let completed = Mutex(false)
            playback.scheduleBuffer(result.buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
                completed.withLock { $0 = true }
            }
            playbackEngine.prepare()
            checkpoint("playback_start")
            try playbackEngine.start()
            playback.play()
            evidence["playback_started"] = true
            checkpoint("playing")
            message = "Playing your sample…"
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while !completed.withLock({ $0 }) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ProbeError.playback }
                try await Task.sleep(for: .milliseconds(50))
            }
            evidence["playback_completed"] = true
            checkpoint("completed")
            message = result.signalPresent ? "Audio test finished. Did you hear your voice?" : "The sample was very quiet. Try speaking closer."
        } catch is CancellationError {
            evidence["cancelled"] = true
            evidence["cancelled_at"] = phase
            switch evidence["stop_reason"] as? String {
            case StopReason.screenDimmed.rawValue:
                message = "Test stopped when the screen dimmed. Keep your wrist raised through playback and retry."
            case StopReason.appInactive.rawValue, StopReason.viewClosed.rawValue:
                message = "Test stopped when Dot left the foreground. Keep Dot visible through playback and retry."
            case StopReason.interruption.rawValue:
                message = "Another audio activity interrupted the test. Retry when it ends."
            case StopReason.outputRemoved.rawValue:
                message = "The audio output disconnected. Reconnect it and retry."
            case StopReason.mediaReset.rawValue:
                message = "Watch audio restarted during the test. Please retry."
            default:
                message = "Audio test ended. The sample was discarded."
            }
        } catch {
            evidence["failed_at"] = phase
            evidence["error"] = (error as? ProbeError)?.rawValue ?? (error as? WatchAudioError)?.rawValue ?? "audio_error"
            switch error as? ProbeError {
            case .permission: message = "Allow microphone access in Watch Settings to run this test."
            case .foreground: message = "Keep Dot open and your wrist raised for the audio test."
            default: message = "Audio test could not finish. Please tell me this message."
            }
        }
    }

    private func roundTrip(_ samples: [Float], sampleRate: Double) async throws -> (buffer: AVAudioPCMBuffer, packets: Int, signalPresent: Bool) {
        let codec = try NativeOpusCodec()
        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let pointer = source.floatChannelData?[0],
              let converter = AVAudioConverter(from: sourceFormat, to: codec.pcmFormat),
              let converted = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: 240_000) else { throw ProbeError.format }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: $0.count) }
        defer {
            source.floatChannelData?[0].update(repeating: 0, count: Int(source.frameLength))
            converted.floatChannelData?[0].update(repeating: 0, count: Int(converted.frameLength))
            codec.reset()
        }
        converter.primeMethod = .none
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, state in
            guard !supplied else { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard status != .error, conversionError == nil, let input = converted.floatChannelData?[0],
              converted.frameLength >= 960 else { throw ProbeError.capture }
        var decoded: [Float] = []
        defer { decoded.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; decoded.removeAll() }
        var packets = 0
        var peak: Float = 0
        for start in stride(from: 0, through: Int(converted.frameLength) - 960, by: 960) {
            try Task.checkCancellation()
            let frame = (0..<960).map { index -> Float in
                let value = input[start + index]
                peak = max(peak, abs(value))
                return min(1, max(-1, value))
            }
            for packet in try codec.encode(frame) {
                let output = try codec.decode(packet)
                guard decoded.count + output.count <= 240_000 else { throw ProbeError.capture }
                decoded.append(contentsOf: output)
                packets += 1
            }
            if packets.isMultiple(of: 8) { await Task.yield() }
        }
        guard !decoded.isEmpty,
              let output = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: AVAudioFrameCount(decoded.count)),
              let channel = output.floatChannelData?[0] else { throw ProbeError.capture }
        output.frameLength = AVAudioFrameCount(decoded.count)
        decoded.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        return (output, packets, peak > 0.01)
    }

    private func stopEngine() {
        capture?.close()
        capture = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player?.stop()
        player?.reset()
        player = nil
        engine?.stop()
        engine?.reset()
        engine = nil
        if let playbackBuffer {
            playbackBuffer.floatChannelData?[0].update(repeating: 0, count: Int(playbackBuffer.frameLength))
        }
        playbackBuffer = nil
        if evidence["capture_started"] as? Bool == true { evidence["capture_stopped"] = true }
    }

    private func releaseAudio() {
        stopEngine()
        if sessionActive {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
            } catch { evidence["session_release_failed"] = true }
        }
        evidence["audio_released"] = !sessionActive
    }

    private func saveEvidence() {
        evidence["updated_at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) else { return }
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("audio-diagnostics.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func checkpoint(_ stage: String) {
        evidence["stage"] = stage
        saveEvidence()
    }

    #if targetEnvironment(simulator)
    /// Headless simulator preflight. Uses a generated sine wave; no permission,
    /// audio session, engine, speaker, microphone, network or account is opened.
    func runSimulatorCheck() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var report: [String: Any] = ["schema": 1, "mode": "synthetic_simulator",
                                    "microphone_opened": false, "playback_opened": false,
                                    "network_opened": false, "credentials_used": false, "passed": false]
        do {
            let capture = try BoundedCaptureBuffer(sampleRate: 48_000)
            let callback = SimulatorTapHarness(WatchAudioCallbacks.captureTap(into: capture))
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    callback.invokeSyntheticFrames(50)
                    continuation.resume()
                }
            }
            var samples = capture.take()
            defer { samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; samples.removeAll() }
            report["background_callback_completed"] = callback.backgroundInvocation
            report["captured_frames"] = samples.count
            let result = try await roundTrip(samples, sampleRate: 48_000)
            defer { result.buffer.floatChannelData?[0].update(repeating: 0, count: Int(result.buffer.frameLength)) }
            report["encoded_packets"] = result.packets
            report["decoded_frames"] = result.buffer.frameLength
            report["signal_present"] = result.signalPresent
            report["passed"] = callback.backgroundInvocation && samples.count == 48_000 && result.packets >= 49 && result.signalPresent
            message = "Simulator audio callback check finished."
        } catch {
            report["error"] = (error as? ProbeError)?.rawValue ?? (error as? WatchAudioError)?.rawValue ?? "audio_error"
            message = "Simulator audio check failed."
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("simulator-audio-check.json"), options: .atomic)
        }
    }
    #endif
}

private enum ProbeError: String, Error { case permission, foreground, session, format, capture, playback }

#if targetEnvironment(simulator)
// Simulator-only model of AVFAudio's legacy block invoked by a service queue.
// The supplied production callback is Sendable; the SDK's type is not annotated.
private final class SimulatorTapHarness: @unchecked Sendable {
    private let callback: AVAudioNodeTapBlock
    private let invokedOnBackground = Mutex(false)
    init(_ callback: @escaping AVAudioNodeTapBlock) { self.callback = callback }
    var backgroundInvocation: Bool { invokedOnBackground.withLock { $0 } }
    func invokeSyntheticFrames(_ count: Int) {
        // Create and clear SDK objects on this queue; no non-Sendable audio
        // buffer crosses actors or queues in the simulator harness.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = 960
        for index in 0..<960 { channel[index] = Float(0.2 * sin(2 * .pi * 440 * Double(index) / 48_000)) }
        defer { channel.update(repeating: 0, count: 960) }
        let time = AVAudioTime(sampleTime: 0, atRate: 48_000)
        invokedOnBackground.withLock { $0 = !Thread.isMainThread }
        for _ in 0..<count { callback(buffer, time) }
    }
}
#endif

#endif
