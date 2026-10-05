import SwiftUI
@preconcurrency import WatchConnectivity
import DotCompanion

@MainActor final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var character: UIImage?
    @Published private(set) var message = "Open Dot on your iPhone to sync your character."
    @Published private(set) var phoneReachable = false
    private var store: WatchCharacterStore?
    private let session = WCSession.default
    #if PERSONAL_DIAGNOSTICS
    let voice = WatchVoiceController()
    var voicePairing: CharacterPairing? { store?.context }
    @Published private(set) var watchSignInReady = false
    @Published private(set) var syncingSignIn = false
    @Published private(set) var signInMessage = "Sync Watch sign-in once from your iPhone."
    #endif

    override init() {
        super.init()
        if ReadmeDemo.enabled {
            character = UIImage(named: "ReadmeDemoDot")
            message = "Demo preview · no account connected"
            return
        }
        do {
            #if !PERSONAL_DIAGNOSTICS
            try PrivateWatchKeychain.clearPublicUpgrade()
            #endif
            store = try WatchCharacterStore(directory: URL.applicationSupportDirectory.appendingPathComponent("DotCharacter", isDirectory: true))
            updateImage()
        } catch { message = "Your cached character could not load. Please sync again." }
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    func refresh() {
        guard session.activationState == .activated else {
            message = "Connecting to your iPhone…"; return
        }
        phoneReachable = session.isReachable
        if let context = session.receivedApplicationContext["dot-character-state"] as? Data { receive(context) }
        #if PERSONAL_DIAGNOSTICS
        // An explicit phone handover must not be undone by automatic refresh.
        if !watchSignInReady, !voice.busy, (try? PrivateWatchKeychain.record()) == nil {
            Task { await syncSignIn() }
        }
        #endif
        guard phoneReachable else {
            message = character == nil ? "Open Dot on your iPhone to sync your character." : "Showing your saved Dot. Open Dot on your iPhone to refresh."
            return
        }
        message = "Syncing with your iPhone…"
        session.sendMessageData(Data("refresh-character-v1".utf8), replyHandler: nil) { @Sendable [weak self] _ in
            Task { @MainActor in self?.message = "Open Dot on both devices to retry sync." }
        }
    }

    private func receive(_ encoded: Data) {
        do {
            try store?.receiveContext(CharacterPairing.decode(encoded))
            #if PERSONAL_DIAGNOSTICS
            if let record = try PrivateWatchKeychain.record(),
               store?.context.map({ VoiceControl.pairingMatches(record.grant.pairing, $0) }) != true {
                voice.end(reason: "pairing_changed")
                try PrivateWatchKeychain.clearCredential()
            }
            #endif
            updateImage()
        } catch PairingError.staleTransfer { /* Late context cannot undo sign-out. */ }
        catch { message = "Character sync could not finish. Please try again." }
    }

    private func receive(image: Data, state: Data) {
        do {
            guard let store else { throw PairingError.invalidState }
            try store.receiveImage(image, state: CharacterPairing.decode(state))
            updateImage()
        } catch PairingError.staleTransfer { /* Ignore obsolete artwork. */ }
        catch { message = "Character sync could not finish. Please try again." }
    }

    private func updateImage() {
        character = store?.image().flatMap(UIImage.init(data:))
        #if PERSONAL_DIAGNOSTICS
        voice.verifyPairing(store?.context)
        let credentialRecord = try? PrivateWatchKeychain.record()
        let credentialsStored = credentialRecord?.credential != nil
        voice.updateCredentialPresence(credentialsStored)
        watchSignInReady = credentialRecord.map { record in
            record.grant.owner == .watch && record.credential != nil &&
            store?.context.map { VoiceControl.pairingMatches(record.grant.pairing, $0) } == true
        } ?? false
        let voiceAvailable = watchSignInReady
        #else
        let credentialsStored = false, voiceAvailable = false
        #endif
        message = character == nil ? "Open Dot on your iPhone to sync your character." : "Your Dot · saved on this Watch"
        let report: [String: Any] = ["schema": 2, "authentic_character_loaded": character != nil,
                                    "voice_available": voiceAvailable, "credentials_stored": credentialsStored,
                                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) {
            try? CompanionStorage.write(data, to: URL.documentsDirectory.appendingPathComponent("diagnostics.json"))
        }
    }

    #if PERSONAL_DIAGNOSTICS
    func syncSignIn() async {
        guard !syncingSignIn, voice.canSyncSignIn else { return }
        syncingSignIn = true; signInMessage = "Syncing encrypted Watch sign-in…"
        defer { syncingSignIn = false }
        do {
            let key = try PrivateWatchKeychain.key()
            let response = try await PrivateWatchChannel.send(PrivateWatchMessage(.sync, publicKey: key.publicKey.rawRepresentation))
            guard response.kind == .grant, let grant = response.grant, let envelope = response.envelope else { throw PrivateWatchError.invalid }
            try grant.follows(PrivateWatchKeychain.record()?.grant)
            let value = try envelope.open(with: key, grant: grant)
            // This correlated response is from the paired app, like its context.
            receive(try grant.pairing.encoded())
            guard store?.context == grant.pairing else { throw PrivateWatchError.stale }
            try PrivateWatchKeychain.save(PrivateWatchRecord(grant: grant, credential: value))
            updateImage()
            signInMessage = "Watch sign-in saved · phone can stay locked"
        } catch {
            signInMessage = "Open Dot on iPhone, then retry Sync Watch sign-in."
        }
    }

    private func receivePrivate(_ message: PrivateWatchMessage, reply: PrivateWatchReply) async {
        guard message.kind == .revoke, let grant = message.grant, !syncingSignIn else {
            reply.send(PrivateWatchMessage(.failed, requestID: message.requestID, error: .busy)); return
        }
        syncingSignIn = true
        defer { syncingSignIn = false }
        do {
            try grant.follows(PrivateWatchKeychain.record()?.grant)
            try await voice.releaseForHandover()
            try PrivateWatchKeychain.save(PrivateWatchRecord(grant: grant, credential: nil))
            updateImage()
            signInMessage = "Voice moved to iPhone · sync again to use Watch"
            reply.send(PrivateWatchMessage(.ack, requestID: message.requestID, grant: grant))
        } catch {
            reply.send(PrivateWatchMessage(.failed, requestID: message.requestID, error: .release))
        }
    }
    #endif

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.phoneReachable = reachable
            if reachable { self?.refresh() }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["dot-character-state"] as? Data else { return }
        Task { @MainActor [weak self] in self?.receive(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard messageData.count <= 4096 else { return }
        Task { @MainActor [weak self] in self?.receive(messageData) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        #if PERSONAL_DIAGNOSTICS
        if let request = try? PrivateWatchMessage.decode(messageData) {
            let reply = PrivateWatchReply(replyHandler)
            Task { @MainActor [weak self] in
                guard let self else { reply.send(PrivateWatchMessage(.failed, requestID: request.requestID, error: .setup)); return }
                await self.receivePrivate(request, reply: reply)
            }
            return
        }
        guard let request = try? VoiceControl.decode(messageData) else { replyHandler(Data()); return }
        let reply = VoiceControlReply(replyHandler)
        Task { @MainActor [weak self] in await self?.voice.receive(request, reply: reply) }
        #else
        replyHandler(Data())
        #endif
    }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["dot-character"] as? Int == 1,
              let state = file.metadata?["dot-character-state"] as? Data,
              let size = try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: file.fileURL) else { return }
        // Copy before returning: WCSession removes the received temporary file.
        let latest = session.receivedApplicationContext["dot-character-state"] as? Data
        Task { @MainActor [weak self] in
            if let latest { self?.receive(latest) }
            self?.receive(image: data, state: state)
        }
    }
}
