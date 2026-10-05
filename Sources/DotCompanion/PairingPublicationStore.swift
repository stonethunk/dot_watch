import Foundation

/// The phone persists the latest revocation/publication before queuing delivery.
/// WCSession.applicationContext is the authoritative latest state; files are
/// accepted only with matching metadata, never as account-selection messages.
public final class PairingPublicationStore {
    private let directory: URL
    public private(set) var current: CharacterPairing?
    private var stateURL: URL { directory.appendingPathComponent("pairing.json") }
    public var imageURL: URL { directory.appendingPathComponent("character.png") }

    public init(directory: URL) throws {
        self.directory = directory
        try CompanionStorage.prepare(directory)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            current = try CharacterPairing.decode(Data(contentsOf: stateURL))
        }
    }

    @discardableResult public func publish(appearance: PairedAppearance?, image: Data?) throws -> CharacterPairing {
        if let appearance {
            guard let image else { throw PairingError.invalidImage }
            try CompanionStorage.validateImage(image, appearance: appearance)
        } else if image != nil { throw PairingError.invalidState }
        let previous = current
        let state: CharacterPairing
        if let previous, previous.appearance == appearance {
            state = previous
        } else {
            state = try CharacterPairing(installation: previous?.installation ?? UUID(),
                                         revision: (previous?.revision ?? 0) + 1, appearance: appearance)
        }
        if let image { try CompanionStorage.write(image, to: imageURL) }
        try CompanionStorage.write(state.encoded(), to: stateURL)
        current = state
        if appearance == nil, FileManager.default.fileExists(atPath: imageURL.path) {
            try FileManager.default.removeItem(at: imageURL)
        }
        return state
    }
}
