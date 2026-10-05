import Foundation
import Testing
@testable import DotCore

final class MockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [(Int, [String: String], Data)] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    static func prepare(_ values: [(Int, [String: String], Data)]) { lock.withLock { responses = values; requests = [] } }
    static var recorded: [URLRequest] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.lock.withLock { () -> (Int, [String: String], Data) in
            Self.requests.append(request)
            return Self.responses.isEmpty ? (599, [:], Data()) : Self.responses.removeFirst()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: response.1)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.2)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct VoiceAPITests {
    func client() throws -> DotVoiceAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return DotVoiceAPI(http: DotHTTPClient(credentials: try ChatGPTCredentials(accessToken: "fixture-token", accountID: "fixture-account"), session: URLSession(configuration: config)))
    }
    func dot() throws -> DotIdentity { try DotIdentity(primary: IdentityTests().fixture()) }
    var created: (Int, [String: String], Data) { (201, ["Location": "https://untrusted.test/rtc_fixture"], Data("v=0\r\n".utf8)) }

    @Test func createAttachStopUseDotAndFixedOrigin() async throws {
        MockProtocol.prepare([created, (200, [:], Data()), (200, [:], Data())])
        let api = try client()
        let call = try await api.create(dot: dot(), offerSDP: "v=0\r\n")
        try await api.attach(call)
        try await api.stop(call)
        #expect(await api.ownedConnection == nil)
        let requests = MockProtocol.recorded
        #expect(requests.map { $0.url!.host } == ["chatgpt.com", "chatgpt.com", "chatgpt.com"])
        #expect(requests.map { $0.url!.path } == ["/backend-api/tbo/fixture-dot/voice/calls", "/backend-api/tbo/fixture-dot/voice/calls/rtc_fixture/attach", "/backend-api/tbo/fixture-dot/voice/calls/rtc_fixture/stop"])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
    }

    @Test func failedStopRetainsOwnershipAndBlocksSecondCall() async throws {
        MockProtocol.prepare([created, (503, [:], Data()), (200, [:], Data())])
        let api = try client()
        let call = try await api.create(dot: dot(), offerSDP: "v=0\r\n")
        await #expect(throws: DotError.http(503)) { try await api.stop(call) }
        #expect(await api.ownedConnection == call)
        await #expect(throws: DotError.callAlreadyActive) { try await api.create(dot: dot(), offerSDP: "v=0\r\n") }
        try await api.stop(call)
        #expect(await api.ownedConnection == nil)
    }

    @Test func failedAttachStillCanBeStopped() async throws {
        MockProtocol.prepare([created, (401, [:], Data()), (200, [:], Data())])
        let api = try client()
        let call = try await api.create(dot: dot(), offerSDP: "v=0\r\n")
        await #expect(throws: DotError.http(401)) { try await api.attach(call) }
        try await api.stop(call)
    }

    @Test func duplicateAttachDoesNotCreateAnotherRequest() async throws {
        MockProtocol.prepare([created, (200, [:], Data()), (200, [:], Data())])
        let api = try client()
        let call = try await api.create(dot: dot(), offerSDP: "v=0\r\n")
        try await api.attach(call)
        try await api.attach(call)
        #expect(MockProtocol.recorded.count == 2)
        try await api.stop(call)
    }

    @Test func invalidLocationCannotBecomeAnAuthenticatedPath() {
        #expect(throws: DotError.invalidResponse) {
            try DotVoiceConnection(dotID: "fixture-dot", location: "https://evil.test/../../credentials", answer: Data("v=0".utf8))
        }
    }

    @Test func unknownEventDoesNotTriggerAnAction() throws {
        #expect(try DotVoiceEvent(data: Data("{\"type\":\"approval.requested\",\"id\":\"fixture\"}".utf8)) == .unknown)
        #expect(try DotVoiceEvent(data: Data("{\"type\":\"session.started\"}".utf8)) == .sessionStarted)
    }

    @Test func malformedAllocationBlocksSilentDuplicateRetry() async throws {
        MockProtocol.prepare([(201, [:], Data("unrecognized".utf8))])
        let api = try client()
        await #expect(throws: DotError.invalidResponse) { try await api.create(dot: dot(), offerSDP: "v=0\r\n") }
        #expect(await api.allocationNeedsReconciliation)
        await #expect(throws: DotError.callAlreadyActive) { try await api.create(dot: dot(), offerSDP: "v=0\r\n") }
        #expect(MockProtocol.recorded.count == 1)
    }

    @Test func rejectedAuthorizationDoesNotMarkAnAllocationAsUncertain() async throws {
        MockProtocol.prepare([(401, [:], Data())])
        let api = try client()
        await #expect(throws: DotError.http(401)) { try await api.create(dot: dot(), offerSDP: "v=0\r\n") }
        #expect(await api.allocationNeedsReconciliation == false)
    }

    @Test func serverFailureCannotProveAllocationDidNotOccur() async throws {
        MockProtocol.prepare([(503, [:], Data())])
        let api = try client()
        await #expect(throws: DotError.http(503)) { try await api.create(dot: dot(), offerSDP: "v=0\r\n") }
        #expect(await api.allocationNeedsReconciliation)
    }

    @Test func recoveredStopUsesFixedOriginAndCanRetryWithoutAllocating() async throws {
        MockProtocol.prepare([(503, [:], Data()), (204, [:], Data())])
        let api = try client()
        await #expect(throws: DotError.http(503)) { try await api.stopRecovered(dotID: "fixture-dot", callID: "rtc_fixture") }
        try await api.stopRecovered(dotID: "fixture-dot", callID: "rtc_fixture")
        #expect(MockProtocol.recorded.count == 2)
        #expect(MockProtocol.recorded.allSatisfy { $0.url?.absoluteString == "https://chatgpt.com/backend-api/tbo/fixture-dot/voice/calls/rtc_fixture/stop" })
        #expect(await api.ownedConnection == nil)
    }

    @Test func recoveredStopRejectsUnsafeTargetsAndAnActiveAllocation() async throws {
        MockProtocol.prepare([created])
        let api = try client()
        await #expect(throws: DotError.invalidResponse) { try await api.stopRecovered(dotID: "../credentials", callID: "rtc_fixture") }
        _ = try await api.create(dot: dot(), offerSDP: "v=0\r\n")
        await #expect(throws: DotError.invalidResponse) { try await api.stopRecovered(dotID: "fixture-dot", callID: "rtc_fixture") }
        #expect(MockProtocol.recorded.count == 1)
    }
}
