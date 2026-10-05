import Foundation
@preconcurrency import WatchConnectivity
import DotCompanion

/// Character/revocation and private setup. Tokens cross only inside a Watch-key
/// encrypted, correlated setup reply, never character context or transfer files.
@MainActor final class PhoneCharacterBridge: NSObject, WCSessionDelegate {
    var onStatus: ((String) -> Void)?
    #if PERSONAL_DIAGNOSTICS
    var onVoiceControl: ((VoiceControl, VoiceControlReply) -> Void)?
    var onPrivateWatchControl: ((PrivateWatchMessage, PrivateWatchReply) -> Void)?
    var currentPairing: CharacterPairing? { store?.current }
    #endif
    private var store: PairingPublicationStore?
    private let outbox = URL.applicationSupportDirectory.appendingPathComponent("WatchOutbox", isDirectory: true)
    private let session = WCSession.default

    override init() {
        super.init()
        guard !ReadmeDemo.enabled else { return }
        store = try? PairingPublicationStore(directory: URL.applicationSupportDirectory.appendingPathComponent("WatchPairing", isDirectory: true))
        #if !PERSONAL_DIAGNOSTICS
        // Public upgrades revoke private artwork before WCSession can publish it.
        do { try store?.publish(appearance: nil, image: nil) }
        catch { store = nil }
        #endif
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func publish(_ appearance: PairedAppearance, image: Data) throws {
        guard let store else { throw PairingError.invalidState }
        try store.publish(appearance: appearance, image: image)
        flush()
    }

    func clear() throws {
        guard let store else { throw PairingError.invalidState }
        try store.publish(appearance: nil, image: nil)
        for transfer in session.outstandingFileTransfers where transfer.file.metadata?["dot-character"] as? Int == 1 {
            transfer.cancel()
        }
        if FileManager.default.fileExists(atPath: outbox.path) { try FileManager.default.removeItem(at: outbox) }
        flush()
    }

    private func flush() {
        guard session.activationState == .activated else { return }
        guard session.isPaired else { onStatus?("Pair your Apple Watch to sync Dot."); return }
        guard session.isWatchAppInstalled else { onStatus?("Install Dot on your Apple Watch."); return }
        guard let store, let state = store.current else {
            onStatus?("Open Dot on your iPhone to finish Watch setup."); return
        }
        do {
            let encoded = try state.encoded()
            for transfer in session.outstandingFileTransfers where transfer.file.metadata?["dot-character"] as? Int == 1 && transfer.file.metadata?["dot-character-state"] as? Data != encoded {
                transfer.cancel()
            }
            try session.updateApplicationContext(["dot-character-state": encoded])
            if session.isReachable { session.sendMessageData(encoded, replyHandler: nil, errorHandler: nil) }
            guard let appearance = state.appearance else {
                onStatus?("Watch sign-out queued."); return
            }
            if session.outstandingFileTransfers.contains(where: { $0.file.metadata?["dot-character-state"] as? Data == encoded }) {
                onStatus?("Sending Dot to your Watch…"); return
            }
            let image = try Data(contentsOf: store.imageURL)
            try CompanionStorage.validateImage(image, appearance: appearance)
            try CompanionStorage.prepare(outbox)
            // Each transfer owns an immutable file until WCSession finishes it.
            let file = outbox.appendingPathComponent("\(state.installation.uuidString)-\(state.revision).png")
            if !FileManager.default.fileExists(atPath: file.path) {
                try CompanionStorage.write(image, to: file)
            }
            session.transferFile(file, metadata: ["dot-character": 1, "dot-character-state": encoded])
            onStatus?("Sending Dot to your Watch…")
        } catch { onStatus?("Open Dot on both devices to retry character sync.") }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in self?.flush() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.flush() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard messageData == Data("refresh-character-v1".utf8) else { return }
        Task { @MainActor [weak self] in self?.flush() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        #if PERSONAL_DIAGNOSTICS
        if let message = try? PrivateWatchMessage.decode(messageData) {
            let reply = PrivateWatchReply(replyHandler)
            Task { @MainActor [weak self] in
                guard let handler = self?.onPrivateWatchControl else {
                    reply.send(PrivateWatchMessage(.failed, requestID: message.requestID, error: .setup)); return
                }
                handler(message, reply)
            }
            return
        }
        guard let message = try? VoiceControl.decode(messageData) else { replyHandler(Data()); return }
        let reply = VoiceControlReply(replyHandler)
        Task { @MainActor [weak self] in
            guard let self, let handler = self.onVoiceControl else { reply.send(message.reply(.failed, error: .setupNeeded)); return }
            handler(message, reply)
        }
        #else
        replyHandler(Data())
        #endif
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard fileTransfer.file.metadata?["dot-character"] as? Int == 1 else { return }
        let url = fileTransfer.file.fileURL
        let succeeded = error == nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Never remove a file still referenced by another transfer.
            if url.deletingLastPathComponent() == outbox,
               !self.session.outstandingFileTransfers.contains(where: { $0.file.fileURL == url }) {
                try? FileManager.default.removeItem(at: url)
            }
            onStatus?(succeeded ? "Dot character sent to your Watch." : "Open Dot on both devices to retry character sync.")
        }
    }
}
