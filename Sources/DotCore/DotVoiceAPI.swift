import Foundation

public struct DotVoiceConnection: Sendable, Equatable {
    public let callID: String
    public let dotID: String
    public let answerSDP: String

    init(dotID: String, location: String?, answer: Data) throws {
        guard let location, let url = URL(string: location),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let callID = components.path.split(separator: "/").last.map(String.init),
              callID.range(of: "^rtc_[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let sdp = String(data: answer, encoding: .utf8), sdp.hasPrefix("v=0"),
              sdp.utf8.count <= 1024 * 1024 else { throw DotError.invalidResponse }
        self.dotID = dotID
        self.callID = callID
        self.answerSDP = sdp
    }
}

/// The observed Dot-specific API. The service chooses context, model, voice and capabilities.
/// WebRTC supplies the SDP; nothing here starts a generic assistant or changes Dot's instructions.
public actor DotVoiceAPI {
    private let http: DotHTTPClient
    private var connection: DotVoiceConnection?
    private var operationInFlight = false
    private var attached = false
    private var uncertainAllocation = false

    public init(http: DotHTTPClient) { self.http = http }

    public func create(dot: DotIdentity, offerSDP: String) async throws -> DotVoiceConnection {
        guard connection == nil, !operationInFlight, !uncertainAllocation else { throw DotError.callAlreadyActive }
        guard offerSDP.hasPrefix("v=0"), offerSDP.utf8.count <= 1024 * 1024 else { throw DotError.invalidResponse }
        operationInFlight = true
        defer { operationInFlight = false }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.authenticatedRequest(Self.base(dot.dotID), method: "POST",
                                                                  body: .object(["sdp": .string(offerSDP)]))
        } catch {
            // A cancelled/failed HTTP response cannot prove that allocation did not occur.
            uncertainAllocation = true
            throw error
        }
        guard [200, 201].contains(response.statusCode) else {
            if response.statusCode >= 500 || response.statusCode == 408 { uncertainAllocation = true }
            throw DotError.http(response.statusCode)
        }
        let created: DotVoiceConnection
        do { created = try DotVoiceConnection(dotID: dot.dotID, location: response.value(forHTTPHeaderField: "Location"), answer: data) }
        catch { uncertainAllocation = true; throw error }
        connection = created
        attached = false
        return created
    }

    /// Apply the returned SDP locally first, then attach. Keep input muted until both complete.
    public func attach(_ call: DotVoiceConnection) async throws {
        guard connection == call, !operationInFlight else { throw DotError.callNotActive }
        if attached { return }
        operationInFlight = true
        defer { operationInFlight = false }
        let (_, response) = try await http.authenticatedRequest(Self.actionURL(call, "attach"), method: "POST")
        guard [200, 204].contains(response.statusCode) else { throw DotError.http(response.statusCode) }
        attached = true
    }

    /// Stop local capture/playback before calling. A failed stop retains ownership for retry.
    public func stop(_ call: DotVoiceConnection) async throws {
        guard connection == call, !operationInFlight else { throw DotError.callNotActive }
        operationInFlight = true
        defer { operationInFlight = false }
        let (_, response) = try await http.authenticatedRequest(Self.actionURL(call, "stop"), method: "POST")
        guard [200, 204].contains(response.statusCode) else { throw DotError.http(response.statusCode) }
        connection = nil
        attached = false
    }

    public var ownedConnection: DotVoiceConnection? { connection }
    public var allocationNeedsReconciliation: Bool { uncertainAllocation }

    /// Recover only a persisted stop target after process termination. No SDP is
    /// restored and this cannot open a microphone or create/attach a connection.
    public func stopRecovered(dotID: String, callID: String) async throws {
        guard connection == nil, !operationInFlight, !uncertainAllocation,
              dotID.range(of: "^[A-Za-z0-9_~-]{1,128}$", options: .regularExpression) != nil,
              callID.range(of: "^rtc_[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw DotError.invalidResponse }
        operationInFlight = true
        defer { operationInFlight = false }
        let url = Self.base(dotID).appendingPathComponent(callID).appendingPathComponent("stop")
        let (_, response) = try await http.authenticatedRequest(url, method: "POST")
        guard [200, 204].contains(response.statusCode) else { throw DotError.http(response.statusCode) }
    }

    private static func base(_ dotID: String) -> URL {
        EndpointPolicy.api.appendingPathComponent("tbo").appendingPathComponent(dotID).appendingPathComponent("voice/calls")
    }

    private static func actionURL(_ call: DotVoiceConnection, _ action: String) -> URL {
        // Location is never followed; only a validated identifier is used with the fixed origin.
        base(call.dotID).appendingPathComponent(call.callID).appendingPathComponent(action)
    }
}
