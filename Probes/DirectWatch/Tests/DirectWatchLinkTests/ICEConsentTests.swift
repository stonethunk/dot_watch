import CryptoKit
import Foundation
import Testing
@testable import DirectWatchLink

// Synthetic ICE keys only. No account credentials or captured service packets.
private let localPassword = "synthetic-local-ice-password"
private let remotePassword = "synthetic-remote-ice-password"
private let peer = [UInt8]([203, 0, 113, 7])
private func consent() -> ICEConsent {
    ICEConsent(localUfrag: "local", localPassword: localPassword, remoteUfrag: "remote",
               remotePassword: remotePassword, remoteAddress: peer, remotePort: 12345)
}
private func required(_ value: [UInt8]?) throws -> [UInt8] { try #require(value) }
private func response(to request: [UInt8], type: UInt16 = 0x0101, password: String = remotePassword) -> [UInt8] {
    let attributes: [(UInt16, Data)] = type == 0x0111 ? [(UInt16(0x0009), Data([0, 0, 4, 3]))] :
        [(UInt16(0x0020), Data([0, 1, 0x11, 0x22, 0xe2, 0x12, 0xd5, 0x49]))]
    return ConsentSTUN.encode(type: type, transaction: Data(request[8..<20]), attributes: attributes,
                              key: SymmetricKey(data: Data(password.utf8)))
}

@Test func authenticatedRefreshSustainsTenMinutesOfVirtualTime() throws {
    var link = consent(); link.start(at: .zero)
    for second in stride(from: 0, through: 600, by: 5) {
        let now = Duration.seconds(second)
        let request = try required(link.poll(at: now, interval: .seconds(5)))
        let parsed = try #require(ConsentSTUN.parse(request))
        #expect(parsed.type == 0x0001)
        #expect(parsed.value(0x0006) == Data("remote:local".utf8))
        #expect(parsed.authenticated(key: SymmetricKey(data: Data(remotePassword.utf8))))
        _ = link.receive(response(to: request), at: now + .milliseconds(20))
        #expect(link.usable)
    }
    #expect(link.requests == 121)
    #expect(link.responses == 121)
    #expect(!link.expired)
}

@Test func unansweredChecksExpireAtThirtySecondsAndCannotRevive() throws {
    var link = consent(); link.start(at: .zero)
    var latest: [UInt8] = []
    for second in stride(from: 0, through: 25, by: 5) {
        latest = try required(link.poll(at: .seconds(second), interval: .seconds(5)))
    }
    #expect(link.poll(at: .seconds(30), interval: .seconds(5)) == nil)
    #expect(link.expired && !link.usable)
    _ = link.receive(response(to: latest), at: .seconds(31))
    link.start(at: .seconds(32))
    #expect(!link.usable)
    #expect(link.responses == 0)
}

@Test func forgedReplayAndUnmatchedResponsesDoNotRenewConsent() throws {
    var link = consent(); link.start(at: .zero)
    let request = try required(link.poll(at: .zero, interval: .seconds(5)))
    _ = link.receive(response(to: request, password: "wrong-synthetic-key"), at: .seconds(10))
    #expect(link.responses == 0)
    _ = link.receive(response(to: request), at: .seconds(11))
    #expect(link.responses == 1)
    _ = link.receive(response(to: request), at: .seconds(25))
    link.expire(at: .seconds(41))
    #expect(link.expired)
    #expect(link.responses == 1)
    #expect(link.invalidResponses == 1)
}

@Test func delayedEarlierTransactionAcceptedAndIdentifiersAreFresh() throws {
    var link = consent(); link.start(at: .zero)
    let first = try required(link.poll(at: .zero, interval: .seconds(5)))
    let second = try required(link.poll(at: .seconds(5), interval: .seconds(5)))
    #expect(first[8..<20] != second[8..<20])
    _ = link.receive(response(to: first), at: .seconds(7))
    #expect(link.responses == 1)
    #expect(link.ageMilliseconds(at: .seconds(9)) == 2000)
}

@Test func onlyAuthenticatedForbiddenRevokesImmediately() throws {
    var link = consent(); link.start(at: .zero)
    let request = try required(link.poll(at: .zero, interval: .seconds(5)))
    _ = link.receive(response(to: request, type: 0x0111, password: "forged"), at: .seconds(1))
    #expect(link.usable)
    _ = link.receive(response(to: request, type: 0x0111), at: .seconds(2))
    #expect(link.revoked && !link.usable)
    #expect(link.poll(at: .seconds(5), interval: .seconds(5)) == nil)
}

@Test func reciprocalConsentWithoutPriorityGetsAuthenticatedAddressResponse() throws {
    var link = consent()
    let key = SymmetricKey(data: Data(localPassword.utf8))
    let request = ConsentSTUN.encode(type: 0x0001, transaction: Data(repeating: 3, count: 12),
        attributes: [(0x0006, Data("local:remote".utf8))], key: key)
    guard case .reply(let bytes) = link.receive(request, at: .seconds(1)) else {
        Issue.record("A pure consent check must get a response without ICE nomination attributes."); return
    }
    let result = try #require(ConsentSTUN.parse(bytes))
    #expect(result.type == 0x0101)
    #expect(result.transaction == Data(repeating: 3, count: 12))
    #expect(result.authenticated(key: key))
    #expect(result.validMappedAddress)
    let port = UInt16(12345) ^ 0x2112
    #expect(result.value(0x0020) == Data([0, 1, UInt8(port >> 8), UInt8(truncatingIfNeeded: port), 0xea, 0x12, 0xd5, 0x45]))
    #expect(link.peerReplies == 1)
    #expect(!link.usable) // Answering the peer does not authorize our own media.
}

@Test func invalidPeerRequestAndNominationCannotBypassExistingICEStack() {
    var link = consent()
    let request = ConsentSTUN.encode(type: 0x0001, transaction: Data(repeating: 4, count: 12),
        attributes: [(0x0006, Data("local:remote".utf8))], key: SymmetricKey(data: Data("forged".utf8)))
    guard case .discard = link.receive(request, at: .zero) else { Issue.record("Invalid MAC admitted"); return }
    let nomination = ConsentSTUN.encode(type: 0x0001, transaction: Data(repeating: 5, count: 12),
        attributes: [(0x0006, Data("local:remote".utf8)), (0x0024, Data([1, 2, 3, 4]))],
        key: SymmetricKey(data: Data(localPassword.utf8)))
    guard case .forward = link.receive(nomination, at: .zero) else { Issue.record("Nomination intercepted"); return }
    #expect(link.peerReplies == 0)
}

@Test func noMediaBeforeInitialVerificationAndCheckIntervalIsBounded() throws {
    var link = consent()
    #expect(!link.usable)
    #expect(link.poll(at: .zero, interval: .zero) == nil)
    link.start(at: .seconds(1))
    _ = try required(link.poll(at: .seconds(1), interval: .zero))
    #expect(link.poll(at: .seconds(4), interval: .zero) == nil)
    _ = try required(link.poll(at: .seconds(5), interval: .seconds(99)))
    #expect(link.poll(at: .seconds(10), interval: .seconds(99)) == nil)
    _ = try required(link.poll(at: .seconds(11), interval: .seconds(99)))
}

@Test func malformedLengthAndBadFingerprintDoNotAuthenticate() throws {
    var link = consent(); link.start(at: .zero)
    let request = try required(link.poll(at: .zero, interval: .seconds(5)))
    var reply = response(to: request)
    reply[reply.count - 1] ^= 1
    _ = link.receive(reply, at: .seconds(20))
    #expect(link.responses == 0)
    reply = response(to: request) + [0]
    #expect(ConsentSTUN.parse(reply) == nil)
    #expect(ConsentSTUN.parse(Array(repeating: 0, count: 2049)) == nil)
}

@Test func rfc5769PublishedRequestAuthenticates() throws {
    // Public RFC 5769 section 2.1 test vector; not a service credential.
    let hex = "000100582112a442b7e7a701bc34d686fa87dfae802200105354554e207465737420636c69656e74002400046e0001ff80290008932ff9b151263b36000600096576746a3a68367659202020000800149aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a280280004e57a3bcf"
    let bytes = stride(from: 0, to: hex.count, by: 2).map { index -> UInt8 in
        let start = hex.index(hex.startIndex, offsetBy: index)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
    let message = try #require(ConsentSTUN.parse(bytes))
    #expect(message.authenticated(key: SymmetricKey(data: Data("VOkJxbRl1RmTxUk/WvJxBt".utf8))))
}
