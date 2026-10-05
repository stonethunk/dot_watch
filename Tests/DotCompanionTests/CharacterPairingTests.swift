import Foundation
import Testing
@testable import DotCompanion

struct CharacterPairingTests {
    private var png: Data { Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7uoAAAAASUVORK5CYII=")! }
    private func appearance(account: String = "account-a", dot: String = "dot-a", version: String = "one", data: Data? = nil) throws -> PairedAppearance {
        try PairedAppearance(accountHash: PairedAppearance.hash(Data(account.utf8)),
                             dotHash: PairedAppearance.hash(Data(dot.utf8)),
                             version: PairedAppearance.hash(Data(version.utf8)),
                             imageHash: PairedAppearance.hash(data ?? png))
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func fileBeforeContextStaysHiddenUntilAuthoritativeContextArrives() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try WatchCharacterStore(directory: folder)
        let state = try CharacterPairing(installation: UUID(), revision: 1, appearance: appearance())
        try store.receiveImage(png, state: state)
        #expect(store.image() == nil)
        try store.receiveContext(state)
        #expect(store.image() == png)
        let cold = try WatchCharacterStore(directory: folder)
        #expect(cold.image() == png)
    }

    @Test func signOutSurvivesRestartAndRejectsLateFileAndContext() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try WatchCharacterStore(directory: folder)
        let id = UUID(), first = try CharacterPairing(installation: id, revision: 1, appearance: appearance())
        try store.receiveContext(first)
        try store.receiveImage(png, state: first)
        try store.receiveContext(CharacterPairing(installation: id, revision: 2, appearance: nil))
        let cold = try WatchCharacterStore(directory: folder)
        #expect(cold.image() == nil)
        #expect(throws: PairingError.self) { try cold.receiveImage(png, state: first) }
        #expect(throws: PairingError.self) { try cold.receiveContext(first) }
        #expect(cold.image() == nil)
    }

    @Test func accountOrDotChangeClearsOldImageBeforeNewFileArrives() throws {
        for replacement in [try appearance(account: "account-b"), try appearance(dot: "dot-b")] {
            let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
            let store = try WatchCharacterStore(directory: folder), id = UUID()
            let first = try CharacterPairing(installation: id, revision: 1, appearance: appearance())
            try store.receiveContext(first); try store.receiveImage(png, state: first)
            let next = try CharacterPairing(installation: id, revision: 2, appearance: replacement)
            try store.receiveContext(next)
            #expect(store.image() == nil)
            #expect(throws: PairingError.self) { try store.receiveImage(png, state: first) }
            try store.receiveImage(png, state: next)
            #expect(store.visibleAppearance == replacement)
        }
    }

    @Test func failedCustomizationRefreshRetainsOnlySameDotsLastValidAsset() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try WatchCharacterStore(directory: folder), id = UUID()
        let first = try CharacterPairing(installation: id, revision: 1, appearance: appearance())
        try store.receiveContext(first); try store.receiveImage(png, state: first)
        let next = try CharacterPairing(installation: id, revision: 2, appearance: appearance(version: "two"))
        try store.receiveContext(next)
        var damaged = png; damaged[32] ^= 1
        #expect(throws: PairingError.self) { try store.receiveImage(damaged, state: next) }
        #expect(store.image() == png)
        #expect(try WatchCharacterStore(directory: folder).image() == png)
    }

    @Test func futureFileCannotResurrectCacheAfterItsSignOut() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try WatchCharacterStore(directory: folder), id = UUID()
        let state = try CharacterPairing(installation: id, revision: 2, appearance: appearance())
        try store.receiveImage(png, state: state)
        try store.receiveContext(CharacterPairing(installation: id, revision: 3, appearance: nil))
        #expect(store.image() == nil)
        #expect(throws: PairingError.self) { try store.receiveContext(state) }
    }

    @Test func newPhoneInstallationFileCanPrecedeItsNewContext() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try WatchCharacterStore(directory: folder)
        try store.receiveContext(CharacterPairing(installation: UUID(), revision: 9, appearance: nil))
        let new = try CharacterPairing(installation: UUID(), revision: 1, appearance: appearance())
        try store.receiveImage(png, state: new)
        #expect(store.image() == nil)
        try store.receiveContext(new)
        #expect(store.image() == png)
    }

    @Test func duplicateRevisionCannotChangeAccount() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try WatchCharacterStore(directory: folder), id = UUID()
        try store.receiveContext(CharacterPairing(installation: id, revision: 1, appearance: appearance()))
        #expect(throws: PairingError.self) {
            try store.receiveContext(CharacterPairing(installation: id, revision: 1, appearance: appearance(account: "other")))
        }
    }

    @Test func publisherPersistsRevisionAcrossRenewalSignOutAndAccountChange() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let publisher = try PairingPublicationStore(directory: folder)
        let first = try publisher.publish(appearance: appearance(), image: png)
        #expect(try publisher.publish(appearance: appearance(), image: png) == first)
        let cleared = try publisher.publish(appearance: nil, image: nil)
        #expect(cleared.revision == first.revision + 1)
        #expect(!FileManager.default.fileExists(atPath: publisher.imageURL.path))
        let cold = try PairingPublicationStore(directory: folder)
        let second = try cold.publish(appearance: appearance(account: "second tester"), image: png)
        #expect(second.installation == first.installation)
        #expect(second.revision == cleared.revision + 1)
    }

    @Test func oversizedOrUnboundedPngAndInvalidMetadataAreRejected() throws {
        let value = try appearance()
        #expect(throws: PairingError.self) {
            try CompanionStorage.validateImage(Data(repeating: 0, count: 2 * 1024 * 1024 + 1), appearance: value)
        }
        var large = png
        large.replaceSubrange(16..<20, with: [0xff, 0xff, 0xff, 0xff])
        #expect(throws: PairingError.self) {
            try CompanionStorage.validateImage(large, appearance: appearance(data: large))
        }
        #expect(throws: PairingError.self) { try CharacterPairing.decode(Data(repeating: 0, count: 4097)) }
        #expect(throws: PairingError.self) { try CharacterPairing(installation: UUID(), revision: UInt64.max, appearance: nil) }
        #expect(throws: PairingError.self) {
            try PairedAppearance(accountHash: "../", dotHash: value.dotHash, version: value.version, imageHash: value.imageHash)
        }
    }
}
