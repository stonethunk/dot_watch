import Foundation

/// Serial access required. Keeps one valid character and at most one pending
/// file. A transfer may precede its context; it remains invisible until matched.
public final class WatchCharacterStore {
    private let directory: URL
    private var contextURL: URL { directory.appendingPathComponent("context.json") }
    private var visibleURL: URL { directory.appendingPathComponent("visible.json") }
    private var imageURL: URL { directory.appendingPathComponent("character.png") }
    private var pending: (CharacterPairing, Data)?
    public private(set) var context: CharacterPairing?
    public private(set) var visibleAppearance: PairedAppearance?

    public init(directory: URL) throws {
        self.directory = directory
        try CompanionStorage.prepare(directory)
        context = (try? Data(contentsOf: contextURL)).flatMap { try? CharacterPairing.decode($0) }
        if let desired = context?.appearance,
           let data = try? Data(contentsOf: visibleURL),
           let visible = try? JSONDecoder().decode(PairedAppearance.self, from: data),
           (try? visible.validate()) != nil, visible.sameDot(as: desired),
           let image = try? Data(contentsOf: imageURL),
           (try? CompanionStorage.validateImage(image, appearance: visible)) != nil {
            visibleAppearance = visible
        } else { try clearImage() }
    }

    public func image() -> Data? {
        guard let visibleAppearance, let data = try? Data(contentsOf: imageURL),
              (try? CompanionStorage.validateImage(data, appearance: visibleAppearance)) != nil else { return nil }
        return data
    }

    public func receiveContext(_ value: CharacterPairing) throws {
        try value.validate()
        if let context, context.installation == value.installation {
            guard value.revision >= context.revision else { throw PairingError.staleTransfer }
            guard value.revision != context.revision || value == context else { throw PairingError.invalidState }
        }
        // Persist the revocation first. A crash cannot resurrect a prior cache.
        let installationChanged = context?.installation != value.installation
        try CompanionStorage.write(value.encoded(), to: contextURL)
        context = value
        if let visibleAppearance,
           installationChanged || value.appearance?.sameDot(as: visibleAppearance) != true { try clearImage() }
        if let pending {
            if pending.0 == value {
                try commit(pending.1, state: pending.0)
            } else if pending.0.installation != value.installation || pending.0.revision <= value.revision {
                self.pending = nil
            }
        }
    }

    public func receiveImage(_ data: Data, state: CharacterPairing) throws {
        try state.validate()
        guard let appearance = state.appearance else { throw PairingError.invalidState }
        try CompanionStorage.validateImage(data, appearance: appearance)
        if state == context { try commit(data, state: state); return }
        if let context, state.installation == context.installation {
            guard state.revision > context.revision else {
                throw PairingError.staleTransfer
            }
        }
        if let pending, pending.0.installation == state.installation, pending.0.revision > state.revision {
            throw PairingError.staleTransfer
        }
        pending = (state, data)
    }

    private func commit(_ data: Data, state: CharacterPairing) throws {
        guard state == context, let appearance = state.appearance else { throw PairingError.staleTransfer }
        try CompanionStorage.write(data, to: imageURL)
        try CompanionStorage.write(JSONEncoder().encode(appearance), to: visibleURL)
        visibleAppearance = appearance
        pending = nil
    }

    private func clearImage() throws {
        visibleAppearance = nil
        for file in [imageURL, visibleURL] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
