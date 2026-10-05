#if PERSONAL_DIAGNOSTICS
import SwiftUI
import AVFAudio
import Synchronization
import DotCompanion
import DotCore
import DirectWatchLink
import WatchAudioKit

/// Networking callbacks only touch this bounded, thread-safe inbox. No UI
/// actor, transcript, SDK audio buffer, or account credential crosses a callback.
private final class WatchVoiceInbox: Sendable {
    private struct State: Sendable {
        var closed = false
        var packets: [WatchOpusPacket] = []
        var events: [Data] = []
        var droppedPackets = 0
    }
    private let state = Mutex(State())
    func audio(_ packet: WatchOpusPacket) {
        state.withLock { value in
            guard !value.closed else { return }
            if value.packets.count >= 32 { value.packets.removeFirst(); value.droppedPackets += 1 }
            value.packets.append(packet)
        }
    }
    func event(_ data: Data) {
        state.withLock { value in
            guard !value.closed, data.count <= 64 * 1024 else { return }
            if value.events.count >= 8 { value.events.removeFirst() }
            value.events.append(data)
        }
    }
    func drain() -> ([WatchOpusPacket], [Data]) {
        state.withLock { value in
            let result = (value.packets, value.events)
            value.packets.removeAll(); value.events.removeAll()
            return result
        }
    }
    func close() { state.withLock { $0.closed = true; $0.packets.removeAll(); $0.events.removeAll() } }
    var droppedPackets: Int { state.withLock { $0.droppedPackets } }
}

@MainActor final class WatchVoiceController: ObservableObject {
    @Published private(set) var message = "Ready to talk to your Dot."
    @Published private(set) var busy = false
    @Published private(set) var active = false
    @Published private(set) var muted = false
    @Published private(set) var level = 0.0
    private var sessionID: UUID?
    private var lastClosedID: UUID?
    private var pairing: CharacterPairing?
    private var operation: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var stream: Task<Void, Never>?
    private var api: DotVoiceAPI?
    private var audio = WatchVoiceAudio()
    private var link: DirectWatchLink?
    private var transportDiagnostics: [String: Any] = [:]
    private var inbox: WatchVoiceInbox?
    private var stopped = false
    private var connected = false
    private var phase = "idle"
    private var stoppedAt = "idle"
    private var failure: String?
    private var credentialsStored = false
    private var receivedPackets = 0
    private var sentPackets = 0
    private var eventCount = 0
    private var inputEvents = 0
    private var outputEvents = 0
    private var mutePending = false
    private var jitterLostPackets = 0
    private var jitterLatePackets = 0
    private var jitterDuplicatePackets = 0
    private var jitterOverflowDrops = 0
    private var inboxDrops = 0
    private var lateAudioTicks = 0
    private var observers: [NSObjectProtocol] = []
    var canSyncSignIn: Bool { !active && (!busy || (stopped && operation == nil && cleanup == nil && audio.fullyClosed)) }

    func updateCredentialPresence(_ stored: Bool) { credentialsStored = stored }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { @Sendable [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            if began { Task { @MainActor in self?.end(reason: "interruption") } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { @Sendable [weak self] note in
            let removed = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            if removed { Task { @MainActor in self?.end(reason: "output_removed") } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor in self?.end(reason: "media_reset") }
        })
    }

    func start(pairing: CharacterPairing?) {
        guard !busy else { return }
        guard let pairing, pairing.appearance != nil else { message = "Refresh Dot from your iPhone first."; return }
        let credentials: ChatGPTCredentials
        do {
            guard let record = try PrivateWatchKeychain.record(), record.grant.owner == .watch,
                  VoiceControl.pairingMatches(record.grant.pairing, pairing),
                  let value = record.credential else { throw PrivateWatchError.setup }
            credentials = try value.checked()
            credentialsStored = true
            if try PrivateWatchKeychain.journal() != nil {
                sessionID = UUID(); busy = true
                message = "A previous voice connection needs release. Tap End first."
                return
            }
        } catch { message = "Sync Watch sign-in from Dot on your iPhone first."; return }
        let id = UUID()
        sessionID = id; self.pairing = pairing
        busy = true; active = false; muted = false; stopped = false; connected = false
        failure = nil; receivedPackets = 0; sentPackets = 0; eventCount = 0; inputEvents = 0; outputEvents = 0
        transportDiagnostics = [:]
        jitterLostPackets = 0; jitterLatePackets = 0; jitterDuplicatePackets = 0; jitterOverflowDrops = 0; inboxDrops = 0; lateAudioTicks = 0
        audio = WatchVoiceAudio()
        let inbox = WatchVoiceInbox()
        self.inbox = inbox
        checkpoint("preparing", message: "Preparing Watch audio…")
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            do {
                try await self.audio.prepare()
                try self.checkRunning(id)
                try self.audio.startConnectingTone()
                let link = try DirectWatchLink()
                self.link = link
                link.setHandlers(audio: { @Sendable packet in inbox.audio(packet) },
                                 event: { @Sendable data in inbox.event(data) })
                self.checkpoint("signaling", message: "Connecting directly from your Watch…")
                let http = DotHTTPClient(credentials: credentials)
                let dot = try await http.discover()
                try self.checkRunning(id)
                guard pairing.appearance?.accountHash == PairedAppearance.hash(Data(credentials.accountID.utf8)),
                      pairing.appearance?.dotHash == PairedAppearance.hash(Data(dot.dotID.utf8)) else { throw DotError.identityMismatch }
                try await http.verifyThread(dot)
                try self.checkRunning(id)
                let api = DotVoiceAPI(http: http); self.api = api
                try PrivateWatchKeychain.saveJournal(WatchCallJournal(dotID: dot.dotID, callID: nil))
                let call: DotVoiceConnection
                do { call = try await api.create(dot: dot, offerSDP: link.offer) }
                catch {
                    if !(await api.allocationNeedsReconciliation) { try PrivateWatchKeychain.saveJournal(nil) }
                    throw error
                }
                try PrivateWatchKeychain.saveJournal(WatchCallJournal(dotID: dot.dotID, callID: call.callID))
                try self.checkRunning(id)
                try link.accept(call.answerSDP)
                try await api.attach(call)
                try self.checkRunning(id)
                self.checkpoint("transport", message: "Connecting Watch voice…")
                try await link.connect()
                try self.checkRunning(id)
                self.connected = true
                try self.audio.enable(muted: false)
                self.active = true
                self.checkpoint("active", message: "Listening")
                self.startStreaming(id)
            } catch {
                if !self.stopped {
                    self.failure = (error as? WatchVoiceFailure)?.rawValue ?? (error as? LinkError)?.rawValue ?? (error as? PrivateWatchError)?.rawValue ?? Self.safeFailure(error)
                    self.message = Self.safeMessage(error)
                    self.end(reason: self.failure ?? "connection_failed", preserveMessage: true)
                }
            }
        }
    }

    func verifyPairing(_ current: CharacterPairing?) {
        guard let pairing, busy else { return }
        guard let current, VoiceControl.pairingMatches(pairing, current) else { end(reason: "pairing_changed"); return }
    }

    func toggleMute() {
        guard active else { return }
        muted.toggle(); audio.setMuted(muted)
        message = muted ? "Microphone muted" : "Listening"
    }

    func receive(_ request: VoiceControl, reply: VoiceControlReply) async {
        // Legacy phone-signaled commands cannot activate a standalone microphone.
        reply.send(request.reply(.failed, error: .invalidMessage))
    }

    func end(reason: String = "user", preserveMessage: Bool = false) {
        guard let id = sessionID else { return }
        stopLocal(reason: reason)
        if !preserveMessage { message = "Ending voice…" }
        guard cleanup == nil else { return }
        cleanup = Task { [weak self] in
            guard let self else { return }
            defer { self.cleanup = nil }
            await self.operation?.value
            guard self.audio.close() else { self.message = "Audio release needs another End."; self.save(); return }
            do {
                try await self.releaseServer()
                if self.sessionID == id {
                    self.lastClosedID = id; self.sessionID = nil; self.pairing = nil; self.busy = false
                    self.phase = "idle"
                    if !preserveMessage { self.message = "Voice ended." }
                    self.save()
                }
            } catch {
                if self.sessionID == id { self.message = "Audio is off. Reconnect the Watch and retry End. An uncertain startup needs review in ChatGPT."; self.save() }
            }
        }
    }

    private func stopLocal(reason: String) {
        if !stopped { stoppedAt = phase }
        stopped = true; active = false; level = 0
        mutePending = false
        // Let a bounded allocation response finish so its call ID can be stopped.
        // Local audio and transport close immediately; checkRunning prevents activation.
        stream?.cancel(); stream = nil
        inboxDrops = inbox?.droppedPackets ?? inboxDrops
        inbox?.close(); inbox = nil
        if let link { transportDiagnostics = link.diagnostics }
        link?.close(); link = nil
        audio.close(); phase = "stopping"
        if reason != "user" && reason != "phone_ended" { failure = reason }
        save()
    }

    private func startStreaming(_ id: UUID) {
        guard stream == nil, let link, let inbox else { return }
        stream = Task { [weak self] in
            var jitter = OpusJitterBuffer(), tick = 0
            var next = ContinuousClock.now
            while !Task.isCancelled {
                guard let self, self.active, self.sessionID == id else { break }
                let now = ContinuousClock.now
                if next.duration(to: now) > .milliseconds(10) { self.lateAudioTicks += 1 }
                // Retain the 20 ms cadence rather than adding scheduling drift
                // each cycle. Long suspension cannot cause an unbounded catch-up.
                if next.duration(to: now) > .milliseconds(60) { next = now }
                next = next.advanced(by: .milliseconds(20))
                do {
                    guard link.healthy else { throw WatchVoiceFailure.transport }
                    let (packets, events) = inbox.drain()
                    self.receivedPackets += packets.count; self.eventCount += events.count
                    for packet in packets { jitter.insert(sequence: packet.sequence, payload: packet.payload, at: now) }
                    for data in events { if self.activity(data) { jitter.reset() } }
                    // Decode until a small PCM cushion is scheduled. Server Opus
                    // packets may represent 10–120 ms, rather than our 20 ms input.
                    for _ in 0..<12 where self.audio.queuedPlaybackFrames < 5_760 && jitter.count > 0 {
                        guard let packet = jitter.pop(at: now) else { break }
                        try self.audio.play(packet)
                    }
                    self.jitterLostPackets = jitter.lostPackets
                    self.jitterLatePackets = jitter.latePackets
                    self.jitterDuplicatePackets = jitter.duplicatePackets
                    self.jitterOverflowDrops = jitter.overflowDrops
                    self.inboxDrops = inbox.droppedPackets
                    for packet in try self.audio.outgoing() { try link.sendOpus(packet); self.sentPackets += 1 }
                    tick += 1
                    if tick % 5 == 0 { self.level = self.audio.level }
                    if tick % 50 == 0 { self.save() }
                    try await Task.sleep(until: next, clock: .continuous)
                } catch {
                    if !Task.isCancelled {
                        self.end(reason: (error as? WatchVoiceFailure)?.rawValue ?? (error is LinkError ? "transport" : "audio_failed"))
                    }
                    break
                }
            }
            jitter.reset()
        }
    }

    private func releaseServer() async throws {
        if let api, let call = await api.ownedConnection {
            do { try await api.stop(call) }
            catch DotError.http(401) {
                // A renewed token must also be usable to release the old call.
                guard let credentials = try PrivateWatchKeychain.record()?.credential?.checked() else { throw PrivateWatchError.release }
                let renewed = DotVoiceAPI(http: DotHTTPClient(credentials: credentials))
                try await renewed.stopRecovered(dotID: call.dotID, callID: call.callID)
                self.api = nil
            }
        } else if let journal = try PrivateWatchKeychain.journal() {
            guard let callID = journal.callID,
                  let credentials = try PrivateWatchKeychain.record()?.credential?.checked() else { throw PrivateWatchError.release }
            let recovered = DotVoiceAPI(http: DotHTTPClient(credentials: credentials))
            try await recovered.stopRecovered(dotID: journal.dotID, callID: callID)
        }
        if let api, await api.allocationNeedsReconciliation { throw PrivateWatchError.release }
        try PrivateWatchKeychain.saveJournal(nil)
        api = nil
    }

    /// Called before granting phone/CarPlay permission or deleting a token.
    func releaseForHandover() async throws {
        if sessionID == nil, try PrivateWatchKeychain.journal() != nil { sessionID = UUID(); busy = true }
        if busy { end(reason: "handover"); await cleanup?.value }
        guard !busy, audio.fullyClosed, try PrivateWatchKeychain.journal() == nil else { throw PrivateWatchError.release }
    }

    private func activity(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = value["type"] as? String else { return false }
        switch type {
        case "input_audio_buffer.speech_started":
            if !muted { message = "Listening"; audio.interruptPlayback(); return true }
        case "response.created": if !muted { message = "Thinking" }
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta": outputEvents += 1; if !muted { message = "Speaking" }
        case "conversation.item.input_audio_transcription.completed": inputEvents += 1
        case "response.done": if !muted { message = "Listening" }
        case "error": end(reason: "service_error")
        default: break // No tool execution or approval substitution.
        }
        return false
    }
    private func checkRunning(_ id: UUID) throws {
        try Task.checkCancellation()
        guard !stopped, sessionID == id else { throw WatchVoiceFailure.stopped }
    }
    private func checkpoint(_ phase: String, message: String) { self.phase = phase; self.message = message; save() }
    private func save() {
        let report: [String: Any] = ["schema": 3, "phase": phase, "stopped_at_phase": stoppedAt, "active": active, "muted": muted,
            "build": "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))",
            "updated_at": ISO8601DateFormatter().string(from: Date()), "failure": failure as Any? ?? NSNull(),
            "captured_frames": audio.capturedFrames, "scheduled_playback_frames": audio.playedFrames,
            "received_rtp_packets": receivedPackets, "sent_rtp_packets": sentPackets, "data_events": eventCount,
            "capture_sample_rate": audio.captureSampleRate, "resampled_frames": audio.resampledFrames, "encoded_frames": audio.encodedFrames,
            "dropped_capture_frames": audio.droppedCaptureFrames, "dropped_resampled_frames": audio.droppedResampledFrames,
            "playback_empty_refills": audio.emptyPlaybackRefills, "late_audio_ticks": lateAudioTicks,
            "inbox_dropped_packets": inboxDrops, "jitter_missing_packets": jitterLostPackets,
            "jitter_late_packets": jitterLatePackets, "jitter_duplicate_packets": jitterDuplicatePackets, "jitter_overflow_drops": jitterOverflowDrops,
            "input_transcript_events": inputEvents, "output_transcript_events": outputEvents,
            "audio_released": audio.fullyClosed, "credentials_stored": credentialsStored,
            "session_owner": "watch", "phone_heartbeat_required": false, "audio_file_written": false,
            "transport": link?.diagnostics ?? transportDiagnostics]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) {
            try? CompanionStorage.write(data, to: URL.documentsDirectory.appendingPathComponent("voice-diagnostics.json"))
        }
    }
    private static func safeMessage(_ error: Error) -> String {
        if error as? WatchVoiceFailure == .permission { return "Allow Dot microphone access in Watch Settings." }
        if error as? DotError == .http(401) { return "Watch sign-in expired. Renew in Safari on iPhone, then sync Watch sign-in." }
        if error as? DotError == .identityMismatch { return "Dot changed. Sync your character and sign-in again." }
        switch error as? VoiceControlError {
        case .setupNeeded: return "Open Dot on iPhone and finish sign-in."
        case .pairingMismatch: return "Refresh Dot from your iPhone and retry."
        case .busy: return "End the existing Dot session on your iPhone first."
        default: return "Watch voice could not connect. Check Watch Wi-Fi or cellular, then retry."
        }
    }
    private static func safeFailure(_ error: Error) -> String {
        if case .http(let status) = error as? DotError { return "http_\(status)" }
        if let error = error as? URLError { return "network_\(error.code.rawValue)" }
        return "connection_failed"
    }
}
#endif
