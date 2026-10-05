import SwiftUI
import AVFAudio
import DotCore
import DotAuth
import DotCompanion

extension PhoneModel: CarPlaySessionOwner {
    var microphoneGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }
}

@MainActor final class PhoneModel: ObservableObject {
    static let shared = PhoneModel()
    @Published private(set) var state: DotSessionState = .idle
    @Published private(set) var character: UIImage?
    @Published private(set) var configured = false
    @Published private(set) var identity: OpenAIIdentity?
    @Published private(set) var busy = false
    @Published private(set) var level = 0.0
    private var carPlayDisplayConnected = false
    private var carPlayTemplateAccepted: Bool?
    var diagnosticsURL: URL { URL.documentsDirectory.appendingPathComponent("diagnostics.json") }
    var buildLabel: String { "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))" }

    func recordCarPlayDisplay(connected: Bool, templateAccepted: Bool? = nil) {
        carPlayDisplayConnected = connected
        carPlayTemplateAccepted = templateAccepted
        saveDiagnostics()
    }
    @Published private(set) var activity = "Ready"
    @Published private(set) var watchStatus = "Watch setup pending"
    @Published var message: String?
    private var http: DotHTTPClient?
    private var dot: DotIdentity?
    private var coordinator: DotSessionCoordinator?
    private var cache: CharacterCache?
    private var observers: [NSObjectProtocol] = []
    private var inputEvents = 0
    private var outputEvents = 0
    private var setupStep = "not_started"
    private var setupFailure: String?
    private var privateCredentialsCached = false
    private let signInPresenter = OpenAISignInPresenter()
    private let watchBridge = PhoneCharacterBridge()
    #if PERSONAL_DIAGNOSTICS
    private var watchMedia: RemoteWatchMedia?
    #endif

    private init() {
        if ReadmeDemo.enabled {
            character = UIImage(named: "ReadmeDemoDot")
            configured = true
            message = "Simulator preview · demo artwork"
            watchStatus = "Demo preview · no account connected"
            return
        }
        watchBridge.onStatus = { [weak self] in self?.watchStatus = $0 }
        #if PERSONAL_DIAGNOSTICS
        watchBridge.onVoiceControl = { [weak self] request, reply in
            Task { @MainActor in await self?.receiveWatchControl(request, reply: reply) }
        }
        watchBridge.onPrivateWatchControl = { [weak self] request, reply in
            Task { @MainActor in
                guard let self else { reply.send(PrivateWatchMessage(.failed, requestID: request.requestID, error: .setup)); return }
                await self.receivePrivateWatchControl(request, reply: reply)
            }
        }
        #endif
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue
            if began { Task { @MainActor in self?.end() } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let removed = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            if removed { Task { @MainActor in self?.end() } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.end() }
        })
    }

    func load() async {
        guard !ReadmeDemo.enabled else { return }
        guard !busy, state == .idle else { return }
        busy = true
        setupStep = "credential_import"
        setupFailure = nil
        defer { busy = false; saveDiagnostics() }
        do {
            try CredentialStore.importPairedSessionIfPresent()
            if let configuration = PublicSignInConfiguration.current {
                identity = try IdentityStore.read(configuration: configuration)
            }
            #if PERSONAL_DIAGNOSTICS
            guard let credentials = try CredentialStore.read() else {
                privateCredentialsCached = false
                try watchBridge.clear()
                message = browserSetupAvailable ? "Sign in to your own ChatGPT account in Safari, then connect it to Dot." : "Connect to your Mac to finish this diagnostic build’s sign-in."
                return
            }
            privateCredentialsCached = true
            let cache = try CharacterCache(accountID: credentials.accountID)
            self.cache = cache
            if let data = cache.load() { character = UIImage(data: data) }
            syncCharacter(cache)
            let http = DotHTTPClient(credentials: credentials)
            setupStep = "dot_discovery"
            let dot = try await http.discover()
            setupStep = "conversation_verification"
            try await http.verifyThread(dot)
            self.http = http
            self.dot = dot
            let coordinator = DotSessionCoordinator(signaling: DotVoiceAPI(http: http))
            coordinator.onChange = { [weak self] value in
                self?.state = value
                if value == .idle { self?.activity = "Ready"; self?.level = 0 }
                #if PERSONAL_DIAGNOSTICS
                if value == .idle { self?.watchMedia = nil }
                #endif
                self?.saveDiagnostics()
            }
            coordinator.onError = { [weak self] in self?.message = $0 }
            self.coordinator = coordinator
            configured = true
            message = nil
            if cache.pairedCharacter()?.0.dotHash != DotHTTPClient.sha256(Data(dot.dotID.utf8)) {
                try watchBridge.clear()
            }
            // Preserve only this Dot's last valid cached artwork if refresh fails.
            character = cache.load(dot: dot).flatMap(UIImage.init(data:))
            do {
                setupStep = "appearance_refresh"
                let data = try await http.snapshot(dot)
                guard let image = UIImage(data: data) else { throw DotError.invalidResponse }
                try cache.save(data, dot: dot)
                character = image
                syncCharacter(cache)
            } catch { setupFailure = safeFailure(error); message = "Dot is connected, but its appearance could not refresh." }
            setupStep = "ready"
            #else
            configured = false
            character = nil
            try CharacterCache.clearAll()
            try watchBridge.clear()
            message = identity == nil ? "Connect your OpenAI account to get started." : "You’re signed in. Dot access is awaiting OpenAI availability."
            #endif
        } catch {
            setupFailure = safeFailure(error)
            configured = false
            dot = nil
            coordinator = nil
            if (error as? DotError) == .http(401) {
                message = browserSetupAvailable ? "Your private sign-in needs renewal. Sign in again using Safari setup." : "Your private sign-in needs renewal. Renew it on your Mac, then connect this phone again."
            } else {
                message = (error as? DotError)?.description ?? "Setup could not finish. Please reconnect."
            }
        }
    }

    var signInAvailable: Bool { PublicSignInConfiguration.current != nil }
    var browserSetupAvailable: Bool {
        #if PERSONAL_DIAGNOSTICS
        Bundle.main.object(forInfoDictionaryKey: "DotPrivateBrowserSetup") as? Bool == true
        #else
        false
        #endif
    }

    func consumePrivateTransferIfPresent() async {
        guard !ReadmeDemo.enabled else { return }
        guard CredentialStore.privateTransferPending else { return }
        await load()
    }
    var personalBuild: Bool {
        #if PERSONAL_DIAGNOSTICS
        true
        #else
        false
        #endif
    }

    func signIn() async {
        guard state == .idle, !busy, let configuration = PublicSignInConfiguration.current else { return }
        busy = true
        defer { busy = false }
        do {
            let identity = try await signInPresenter.signIn(configuration: configuration)
            try IdentityStore.save(identity)
            self.identity = identity
            message = "You’re signed in. Dot access is awaiting OpenAI availability."
        } catch {
            message = (error as? SignInError) == .denied ? "Sign-in was cancelled." : "OpenAI sign-in could not finish. Please try again."
        }
    }

    func start(_ surface: DotSurface) async {
        guard configured, !busy, let dot, let coordinator else { return }
        if surface == .carPlay {
            guard AVAudioApplication.shared.recordPermission == .granted else {
                message = "Allow microphone access in Dot on your iPhone."
                return
            }
        } else {
            guard await AVAudioApplication.requestRecordPermission() else {
                message = "Allow microphone access in iPhone Settings to speak with Dot."
                return
            }
        }
        guard configured, !busy, self.coordinator === coordinator else { return }
        #if PERSONAL_DIAGNOSTICS
        busy = true
        do { try await reclaimWatch() }
        catch {
            busy = false
            message = "Watch owns voice. Open Dot on your Watch to release it, then retry."
            return
        }
        busy = false
        guard configured, self.coordinator === coordinator else { return }
        #endif
        message = nil
        coordinator.start(surface: surface, dot: dot) { [weak self] in
            let media = NativeVoiceMedia(surface: surface)
            media.onFailure = { [weak self] in self?.coordinator?.mediaFailed() }
            media.onLevel = { [weak self] value in self?.level = value }
            media.onEvent = { [weak self] event in
                switch event {
                case .turnCreated: self?.activity = "Thinking"
                case .turnDone: self?.activity = "Listening"
                case .outputTranscript: self?.activity = "Speaking"; self?.outputEvents += 1
                case .inputTranscript: self?.activity = "Listening"; self?.inputEvents += 1
                case .sessionStarted: self?.activity = "Listening"
                case .serviceError: self?.message = "Dot reported a voice error."; self?.end()
                default: break
                }
                // No response text, approval payload, or tool request is executed here.
            }
            return media
        }
    }

    func end() { coordinator?.end() }
    #if PERSONAL_DIAGNOSTICS
    private func receivePrivateWatchControl(_ request: PrivateWatchMessage, reply: PrivateWatchReply) async {
        guard request.kind == .sync, let publicKey = request.publicKey else {
            reply.send(PrivateWatchMessage(.failed, requestID: request.requestID, error: .invalid)); return
        }
        if !configured, !busy, state == .idle { await load() }
        guard configured, !busy, let pairing = watchBridge.currentPairing, pairing.appearance != nil else {
            reply.send(PrivateWatchMessage(.failed, requestID: request.requestID, error: .setup)); return
        }
        busy = true
        defer { busy = false; saveDiagnostics() }
        do {
            // Await the phone/CarPlay coordinator's actual stop acknowledgement.
            if state != .idle {
                coordinator?.end()
                let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                while state != .idle {
                    guard ContinuousClock.now < deadline else { throw PrivateWatchError.release }
                    if case .blocked = state { throw PrivateWatchError.release }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            guard let credentials = try CredentialStore.read(), watchBridge.currentPairing == pairing,
                  pairing.appearance?.accountHash == PairedAppearance.hash(Data(credentials.accountID.utf8)) else { throw PrivateWatchError.setup }
            let previous = try PrivateWatchKeychain.record()?.grant
            if let previous, previous.owner == .watch {
                guard previous.recipient == publicKey,
                      previous.pairing.installation == pairing.installation,
                      previous.pairing.appearance?.sameDot(as: pairing.appearance!) == true else { throw PrivateWatchError.busy }
            }
            let grant = try PrivateWatchGrant(generation: (previous?.generation ?? 0) + 1, pairing: pairing, owner: .watch, recipient: publicKey)
            let envelope = try PrivateWatchEnvelope.seal(credentials, for: grant)
            // Persist ownership BEFORE delivery, including timeout/lost-reply cases.
            try PrivateWatchKeychain.save(PrivateWatchRecord(grant: grant, credential: nil))
            watchStatus = "Watch owns voice · phone may stay locked"
            reply.send(PrivateWatchMessage(.grant, requestID: request.requestID, grant: grant, envelope: envelope))
        } catch {
            reply.send(PrivateWatchMessage(.failed, requestID: request.requestID, error: (error as? PrivateWatchError) ?? .setup))
        }
    }

    private func reclaimWatch() async throws {
        guard let previous = try PrivateWatchKeychain.record()?.grant, previous.owner == .watch else { return }
        let revoked = try PrivateWatchGrant(generation: previous.generation + 1, pairing: previous.pairing, owner: .phone, recipient: previous.recipient)
        let reply = try await PrivateWatchChannel.send(PrivateWatchMessage(.revoke, grant: revoked))
        guard reply.kind == .ack, reply.grant == revoked else { throw PrivateWatchError.release }
        try PrivateWatchKeychain.save(PrivateWatchRecord(grant: revoked, credential: nil))
        watchStatus = "Voice moved to iPhone · sync sign-in to use Watch again"
    }

    private func receiveWatchControl(_ request: VoiceControl, reply: VoiceControlReply) async {
        if request.kind == .start {
            do {
                guard try PrivateWatchKeychain.record()?.grant.owner != .watch else {
                    reply.send(request.reply(.failed, error: .busy)); return
                }
            } catch { reply.send(request.reply(.failed, error: .setupNeeded)); return }
            if !configured, !busy, state == .idle { await load() }
            guard configured, !busy, let dot, let coordinator else { reply.send(request.reply(.failed, error: .setupNeeded)); return }
            guard let requestedPairing = request.pairing, let current = watchBridge.currentPairing,
                  VoiceControl.pairingMatches(requestedPairing, current) else { reply.send(request.reply(.failed, error: .pairingMismatch)); return }
            guard watchMedia == nil, state.surface != .watch,
                  state != .blocked(state.surface ?? .watch) else { reply.send(request.reply(.failed, error: .busy)); return }
            let media = RemoteWatchMedia(request: request, reply: reply)
            media.onFailure = { [weak self] in self?.coordinator?.mediaFailed() }
            watchMedia = media
            message = nil
            coordinator.start(surface: .watch, dot: dot) { [weak self] in
                // A transfer emits idle after releasing the previous surface.
                // Restore this reference when the queued Watch start actually runs.
                self?.watchMedia = media
                return media
            }
            return
        }
        guard let media = watchMedia, media.request.sessionID == request.sessionID else {
            reply.send(request.reply(state == .idle && request.kind == .closed ? .closed : .failed,
                                     error: state == .idle && request.kind == .closed ? nil : .unknownSession))
            return
        }
        switch request.kind {
        case .ready: media.acknowledgeReady(); reply.send(request.reply(.ack))
        case .heartbeat:
            guard case .active(.watch, _) = state else { reply.send(request.reply(.failed, error: .busy)); return }
            media.heartbeat(); reply.send(request.reply(.ack))
        case .mute:
            guard case .active(.watch, _) = state, let muted = request.muted else { reply.send(request.reply(.failed, error: .busy)); return }
            coordinator?.setMuted(muted); reply.send(request.reply(.ack, muted: muted))
        case .closed:
            media.acknowledgeClosed()
            if state.surface != .watch {
                coordinator?.cancelPendingStart(for: .watch)
                watchMedia = nil
                reply.send(request.reply(.closed))
                return
            }
            coordinator?.end()
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            while state != .idle && ContinuousClock.now < deadline {
                if case .blocked = state { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            reply.send(request.reply(state == .idle ? .closed : .failed, error: state == .idle ? nil : .connectionFailed))
        default: reply.send(request.reply(.failed, error: .invalidMessage))
        }
        saveDiagnostics()
    }
    #endif
    func toggleMute() {
        if case .active(_, let muted) = state { coordinator?.setMuted(!muted) }
    }

    func signOut() {
        guard state == .idle, !busy else { return }
        do {
            try watchBridge.clear()
            try CredentialStore.delete()
            try IdentityStore.delete()
            http = nil; dot = nil; coordinator = nil; cache = nil
            character = nil; configured = false; identity = nil; message = nil
            privateCredentialsCached = false; setupStep = "signed_out"; setupFailure = nil
            inputEvents = 0; outputEvents = 0
            try CharacterCache.clearAll()
            saveDiagnostics()
        } catch { message = "Sign-out cleanup did not finish. Please try again." }
    }

    var status: String {
        switch state {
        case .idle: configured ? "Ready" : "Setup needed"
        case .starting: "Connecting"
        case .active(_, let muted): muted ? "Microphone muted" : activity
        case .stopping: "Ending"
        case .blocked: "Audio off · retry End"
        }
    }

    private func syncCharacter(_ cache: CharacterCache) {
        guard let (appearance, data) = cache.pairedCharacter() else { return }
        do { try watchBridge.publish(appearance, image: data) }
        catch { watchStatus = "Dot is available on your iPhone. Character sync needs another try." }
    }

    private func safeFailure(_ error: Error) -> String {
        if case .http(let status) = error as? DotError { return "http_\(status)" }
        if let error = error as? URLError { return "network_\(error.code.rawValue)" }
        return "setup_error"
    }

    /// Explicit prototype diagnostics: booleans, state and event counts only.
    /// Never writes transcripts, identifiers, audio, URLs or error payloads.
    private func saveDiagnostics() {
        let report: JSONValue = .object([
            "schema": .number(3), "configured": .bool(configured),
            "build": .string(buildLabel),
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
            "carplay_display_connected": .bool(carPlayDisplayConnected),
            "carplay_template_accepted": carPlayTemplateAccepted.map(JSONValue.bool) ?? .null,
            "private_credentials_cached": .bool(privateCredentialsCached),
            "setup_step": .string(setupStep),
            "setup_failure": setupFailure.map(JSONValue.string) ?? .null,
            "authentic_character_loaded": .bool(character != nil),
            "state": .string(String(describing: state)),
            "input_transcript_events": .number(Double(inputEvents)),
            "output_transcript_events": .number(Double(outputEvents))
        ])
        try? report.encoded().write(to: diagnosticsURL,
                                  options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
