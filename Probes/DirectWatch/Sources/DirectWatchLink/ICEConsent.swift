import CryptoKit
import Foundation

/// RFC 7675 consent on the single connected UDP candidate. This owns no bearer
/// token, audio or transcript. All time inputs are monotonic; tests advance time
/// without sleeping. The caller serializes access and stops media on expiration.
struct ICEConsent: Sendable {
    enum Incoming: Sendable { case forward, discard, reply([UInt8]) }
    private let localUsername: Data
    private let remoteUsername: Data
    private let localKey: SymmetricKey
    private let remoteKey: SymmetricKey
    private let remoteAddress: [UInt8]
    private let remotePort: UInt16
    private var lastResponse: Duration?
    private var nextCheck: Duration?
    private var pending: [Data: Duration] = [:]
    private(set) var expired = false
    private(set) var revoked = false
    private(set) var requests = 0
    private(set) var responses = 0
    private(set) var peerReplies = 0
    private(set) var invalidResponses = 0

    init(localUfrag: String, localPassword: String, remoteUfrag: String,
         remotePassword: String, remoteAddress: [UInt8], remotePort: UInt16) {
        localUsername = Data("\(localUfrag):\(remoteUfrag)".utf8)
        remoteUsername = Data("\(remoteUfrag):\(localUfrag)".utf8)
        localKey = SymmetricKey(data: Data(localPassword.utf8))
        remoteKey = SymmetricKey(data: Data(remotePassword.utf8))
        self.remoteAddress = remoteAddress; self.remotePort = remotePort
    }

    // Call only after the existing stack verifies the initial ICE response.
    mutating func start(at now: Duration) {
        guard lastResponse == nil, !expired, !revoked else { return }
        lastResponse = now
        nextCheck = now // Refresh during DTLS setup too, not just during audio.
    }

    mutating func poll(at now: Duration, interval: Duration) -> [UInt8]? {
        guard lastResponse != nil, !expired, !revoked else { return nil }
        expire(at: now)
        guard !expired, let nextCheck, now >= nextCheck else { return nil }
        // Randomized 4–6 seconds in production. Clamp the seam so a caller cannot
        // turn this into a high-rate keepalive or leave a long unchecked gap.
        self.nextCheck = now + min(.seconds(6), max(.seconds(4), interval))
        pending = pending.filter { now - $0.value < .seconds(30) }
        var random = SystemRandomNumberGenerator()
        let transaction = Data((0..<12).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        pending[transaction] = now
        requests += 1
        return ConsentSTUN.encode(type: 0x0001, transaction: transaction,
                                  attributes: [(0x0006, remoteUsername)], key: remoteKey)
    }

    mutating func receive(_ bytes: [UInt8], at now: Duration) -> Incoming {
        guard let message = ConsentSTUN.parse(bytes) else { return .forward }
        if message.type == 0x0101 || message.type == 0x0111 {
            guard pending[message.transaction] != nil else { return .forward }
            expire(at: now)
            guard !expired, !revoked else { return .discard }
            guard message.authenticated(key: remoteKey) else {
                invalidResponses += 1; return .discard
            }
            pending.removeValue(forKey: message.transaction)
            if message.type == 0x0101, message.validMappedAddress {
                lastResponse = now; responses += 1
            } else if message.type == 0x0111, message.errorCode == 403 {
                revoked = true; pending.removeAll()
            } else { invalidResponses += 1 }
            return .discard
        }
        guard message.type == 0x0001 else { return .forward }
        // The existing stack answers nomination/triggered ICE checks. Pure
        // consent requests need no PRIORITY or ICE role attribute (RFC 7675).
        guard !message.attributes.contains(where: { [0x0024, 0x0025, 0x8029, 0x802a].contains($0.type) }) else {
            return .forward
        }
        guard !expired, !revoked,
              message.attributes.allSatisfy({ $0.type >= 0x8000 || [0x0006, 0x0008].contains($0.type) }),
              message.value(0x0006) == localUsername,
              message.authenticated(key: localKey), remoteAddress.count == 4 else { return .discard }
        let cookie: [UInt8] = [0x21, 0x12, 0xa4, 0x42]
        let port = remotePort ^ 0x2112
        let mapped = Data([0, 1, UInt8(port >> 8), UInt8(truncatingIfNeeded: port)] +
                          zip(remoteAddress, cookie).map { $0 ^ $1 })
        peerReplies += 1
        return .reply(ConsentSTUN.encode(type: 0x0101, transaction: message.transaction,
                                        attributes: [(0x0020, mapped)], key: localKey))
    }

    mutating func expire(at now: Duration) {
        if let lastResponse, now - lastResponse >= .seconds(30) {
            expired = true; pending.removeAll(); nextCheck = nil
        }
    }

    var usable: Bool { lastResponse != nil && !expired && !revoked }
    func ageMilliseconds(at now: Duration) -> Int {
        guard let lastResponse else { return 0 }
        let age = now - lastResponse
        return max(0, Int(age.components.seconds * 1000 + age.components.attoseconds / 1_000_000_000_000_000))
    }
}

/// Small bounded STUN wire adapter with native HMAC-SHA1 for interoperability.
/// Authentication uses CryptoKit's constant-time MAC verification. Nothing from
/// an unauthenticated packet updates consent or appears in diagnostics.
enum ConsentSTUN {
    struct Attribute { let type: UInt16; let value: Data; let offset: Int }
    struct Message {
        let bytes: [UInt8]
        let type: UInt16
        let transaction: Data
        let attributes: [Attribute]
        func value(_ type: UInt16) -> Data? { attributes.first { $0.type == type }?.value }
        var validMappedAddress: Bool {
            guard let value = value(0x0020) else { return false }
            return (value.count == 8 && value[0] == 0 && value[1] == 1) ||
                   (value.count == 20 && value[0] == 0 && value[1] == 2)
        }
        var errorCode: Int? {
            guard let value = value(0x0009), value.count >= 4,
                  value[0] == 0, value[1] == 0, value[2] & 0xf8 == 0,
                  (3...6).contains(value[2]), value[3] <= 99 else { return nil }
            return Int(value[2]) * 100 + Int(value[3])
        }
        func authenticated(key: SymmetricKey) -> Bool {
            guard let integrity = attributes.first(where: { $0.type == 0x0008 }), integrity.value.count == 20 else { return false }
            var input = Array(bytes[..<integrity.offset])
            ConsentSTUN.setLength(&input, integrity.offset + 24 - 20)
            guard HMAC<Insecure.SHA1>.isValidAuthenticationCode(integrity.value, authenticating: Data(input), using: key) else { return false }
            if let fingerprint = attributes.first(where: { $0.type == 0x8028 }) {
                guard fingerprint.value.count == 4,
                      ConsentSTUN.read32(Array(fingerprint.value), 0) ==
                        ConsentSTUN.crc32(Array(bytes[..<fingerprint.offset])) ^ 0x5354554e else { return false }
            }
            return true
        }
    }

    static func parse(_ bytes: [UInt8]) -> Message? {
        guard (20...2048).contains(bytes.count), bytes[0] & 0xc0 == 0,
              Array(bytes[4..<8]) == [0x21, 0x12, 0xa4, 0x42],
              Int(read16(bytes, 2)) + 20 == bytes.count, read16(bytes, 2) % 4 == 0 else { return nil }
        var offset = 20
        var attributes: [Attribute] = []
        var integritySeen = false
        var fingerprintSeen = false
        while offset < bytes.count {
            guard offset + 4 <= bytes.count, !fingerprintSeen else { return nil }
            let type = read16(bytes, offset)
            let length = Int(read16(bytes, offset + 2))
            let end = offset + 4 + ((length + 3) & ~3)
            guard end <= bytes.count, !integritySeen || type == 0x8028 else { return nil }
            // Duplicate attributes are ambiguous and never accepted as consent.
            guard !attributes.contains(where: { $0.type == type }) else { return nil }
            attributes.append(Attribute(type: type, value: Data(bytes[(offset + 4)..<(offset + 4 + length)]), offset: offset))
            if type == 0x0008 { integritySeen = true }
            if type == 0x8028 { fingerprintSeen = true }
            offset = end
        }
        return Message(bytes: bytes, type: read16(bytes, 0), transaction: Data(bytes[8..<20]), attributes: attributes)
    }

    static func encode(type: UInt16, transaction: Data, attributes: [(UInt16, Data)], key: SymmetricKey) -> [UInt8] {
        precondition(transaction.count == 12)
        var bytes: [UInt8] = [UInt8(type >> 8), UInt8(truncatingIfNeeded: type), 0, 0, 0x21, 0x12, 0xa4, 0x42] + transaction
        for (type, value) in attributes { append(type, value, to: &bytes) }
        setLength(&bytes, bytes.count + 24 - 20)
        let tag = HMAC<Insecure.SHA1>.authenticationCode(for: Data(bytes), using: key)
        append(0x0008, Data(tag), to: &bytes)
        setLength(&bytes, bytes.count + 8 - 20)
        let fingerprint = crc32(bytes) ^ 0x5354554e
        append(0x8028, Data([UInt8(truncatingIfNeeded: fingerprint >> 24), UInt8(truncatingIfNeeded: fingerprint >> 16),
                             UInt8(truncatingIfNeeded: fingerprint >> 8), UInt8(truncatingIfNeeded: fingerprint)]), to: &bytes)
        return bytes
    }
    private static func append(_ type: UInt16, _ value: Data, to bytes: inout [UInt8]) {
        let length = UInt16(value.count)
        bytes += [UInt8(type >> 8), UInt8(truncatingIfNeeded: type), UInt8(length >> 8), UInt8(truncatingIfNeeded: length)] + value
        bytes += Array(repeating: 0, count: (4 - value.count % 4) % 4)
    }
    fileprivate static func setLength(_ bytes: inout [UInt8], _ length: Int) {
        bytes[2] = UInt8(truncatingIfNeeded: length >> 8); bytes[3] = UInt8(truncatingIfNeeded: length)
    }
    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
    fileprivate static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        }
        return ~crc
    }
}
