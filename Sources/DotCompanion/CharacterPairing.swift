import Foundation
import CryptoKit

public enum PairingError: Error { case invalidState, invalidImage, staleTransfer }

/// Hashed identities and appearance metadata only. No login, conversation or URL.
public struct PairedAppearance: Codable, Sendable, Equatable {
    public let accountHash: String
    public let dotHash: String
    public let version: String
    public let imageHash: String

    public init(accountHash: String, dotHash: String, version: String, imageHash: String) throws {
        self.accountHash = accountHash; self.dotHash = dotHash
        self.version = version; self.imageHash = imageHash
        try validate()
    }

    public func validate() throws {
        guard [accountHash, dotHash, version, imageHash].allSatisfy(Self.isHash) else {
            throw PairingError.invalidState
        }
    }

    public func sameDot(as other: Self) -> Bool {
        accountHash == other.accountHash && dotHash == other.dotHash
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// A nil appearance explicitly revokes the cached character. Revisions persist
/// across sign-out so late file deliveries cannot restore another person's Dot.
public struct CharacterPairing: Codable, Sendable, Equatable {
    public let schema: Int
    public let installation: UUID
    public let revision: UInt64
    public let appearance: PairedAppearance?

    public init(installation: UUID, revision: UInt64, appearance: PairedAppearance?) throws {
        schema = 1; self.installation = installation
        self.revision = revision; self.appearance = appearance
        try validate()
    }

    public func validate() throws {
        guard schema == 1, revision > 0, revision < UInt64.max else { throw PairingError.invalidState }
        try appearance?.validate()
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw PairingError.invalidState }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
}

public enum CompanionStorage {
    public static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: directory.path)
        #endif
        var url = directory, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    public static func write(_ data: Data, to url: URL) throws {
        #if os(iOS) || os(watchOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    public static func validateImage(_ data: Data, appearance: PairedAppearance) throws {
        // PNG is the observed snapshot format. Bound bytes and dimensions before
        // UIKit decodes it on the Watch; never decode an unbounded transferred file.
        guard data.count >= 33, data.count <= 2 * 1024 * 1024,
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              data[12..<16] == Data("IHDR".utf8),
              data[8..<12] == Data([0, 0, 0, 13]),
              PairedAppearance.hash(data) == appearance.imageHash else { throw PairingError.invalidImage }
        func uint32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard (1...2048).contains(uint32(16)), (1...2048).contains(uint32(20)) else {
            throw PairingError.invalidImage
        }
    }
}
