import CarPlay
import AVFAudio
import DotCore

@MainActor protocol CarPlaySessionOwner: AnyObject {
    var configured: Bool { get }
    var microphoneGranted: Bool { get }
    var state: DotSessionState { get }
    var status: String { get }
    var character: UIImage? { get }
    func start(_ surface: DotSurface) async
    func toggleMute()
    func end()
}

/// The same action/lifecycle path is used by the real scene and simulator tests.
/// This object never owns credentials, a microphone, or a second voice session.
@MainActor final class CarPlayExperience {
    enum Action { case talk, mute, end }
    private let owner: any CarPlaySessionOwner
    private(set) var connected = false
    private var connectionEpoch = 0
    init(owner: any CarPlaySessionOwner) { self.owner = owner }

    func connect() { connectionEpoch += 1; connected = true } // Attaching a display cannot record.
    func disconnect() {
        connected = false
        connectionEpoch += 1
        if owner.state.surface == .carPlay { owner.end() }
    }

    func perform(_ action: Action) async {
        guard connected else { return } // A stale button cannot restart after unplugging.
        switch action {
        case .talk:
            guard owner.configured, owner.microphoneGranted,
                  owner.state == .idle || owner.state.surface != .carPlay else { return }
            if case .blocked = owner.state { return }
            let epoch = connectionEpoch
            await owner.start(.carPlay)
            // Disconnect can occur while account resolution/startup is awaiting.
            if (!connected || epoch != connectionEpoch), owner.state.surface == .carPlay { owner.end() }
        case .mute:
            guard case .active(.carPlay, _) = owner.state else { return }
            owner.toggleMute()
        case .end:
            guard owner.state.surface == .carPlay else { return }
            owner.end()
        }
    }

    var renderingKey: String {
        let imageID = owner.character.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        return "\(owner.configured)|\(owner.microphoneGranted)|\(owner.status)|\(owner.state)|\(imageID)"
    }

    func template() -> CPVoiceControlTemplate {
        let ready = owner.configured && owner.microphoneGranted
        let title = ready ? owner.status : "Finish setup in Dot on iPhone"
        let state = CPVoiceControlState(identifier: "dot", titleVariants: [title], image: artwork(), repeats: false)
        if ready {
            if owner.state == .idle || owner.state.surface != .carPlay {
                let talk = button(.talk, title: owner.state == .idle ? "Talk" : "Talk here", symbol: "waveform")
                if case .blocked = owner.state { talk.isEnabled = false }
                state.actionButtons = [talk]
            } else {
                let muted: Bool
                if case .active(.carPlay, let value) = owner.state { muted = value } else { muted = false }
                let mute = button(.mute, title: muted ? "Unmute" : "Mute", symbol: muted ? "mic" : "mic.slash")
                if case .active(.carPlay, _) = owner.state {} else { mute.isEnabled = false }
                state.actionButtons = [mute, button(.end, title: "End", symbol: "stop.fill")]
            }
        }
        return CPVoiceControlTemplate(voiceControlStates: [state])
    }

    private func button(_ action: Action, title: String, symbol: String) -> CPButton {
        let button = CPButton(image: UIImage(systemName: symbol)!) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.perform(action) }
        }
        button.title = title
        return button
    }
    private func artwork() -> UIImage? {
        guard let image = owner.character, image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: 150, height: 150), format: format).image { _ in
            let ratio = min(150 / image.size.width, 150 / image.size.height)
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: (150 - size.width) / 2, y: (150 - size.height) / 2, width: size.width, height: size.height))
        }
    }
}
