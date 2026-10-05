import Foundation
import DotCore
import DotCompanion

struct CharacterCache {
    private let directory: URL
    private let accountHash: String

    init(accountID: String) throws {
        accountHash = DotHTTPClient.sha256(Data(accountID.utf8))
        directory = Self.root.appendingPathComponent(accountHash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var mutable = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    private static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("Characters", isDirectory: true) }
    private var metadataURL: URL { directory.appendingPathComponent("latest.json") }

    func load(dot: DotIdentity? = nil) -> Data? {
        guard let metadata = try? JSONValue.decode(Data(contentsOf: metadataURL)),
              let dotHash = metadata["dot"].string,
              dot == nil || dotHash == DotHTTPClient.sha256(Data(dot!.dotID.utf8)),
              let hash = metadata["sha256"].string, hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit }),
              let data = try? Data(contentsOf: directory.appendingPathComponent(hash + ".png")),
              DotHTTPClient.sha256(data) == hash else { return nil }
        return data
    }

    func save(_ data: Data, dot: DotIdentity) throws {
        guard DotHTTPClient.sha256(data) == dot.snapshotSHA256 else { throw DotError.snapshotMismatch }
        try data.write(to: directory.appendingPathComponent(dot.snapshotSHA256 + ".png"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let metadata: JSONValue = .object([
            "dot": .string(DotHTTPClient.sha256(Data(dot.dotID.utf8))),
            "version": .string(dot.appearanceVersion), "sha256": .string(dot.snapshotSHA256)
        ])
        try metadata.encoded().write(to: metadataURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func pairedCharacter() -> (PairedAppearance, Data)? {
        guard let data = load(), let metadata = try? JSONValue.decode(Data(contentsOf: metadataURL)),
              let dot = metadata["dot"].string, let version = metadata["version"].string,
              let hash = metadata["sha256"].string,
              let appearance = try? PairedAppearance(accountHash: accountHash, dotHash: dot,
                                                    version: version, imageHash: hash) else { return nil }
        return (appearance, data)
    }

    static func clearAll() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}
