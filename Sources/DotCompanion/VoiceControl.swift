import Foundation

public enum VoiceControlError: String, Error, Sendable {
    case invalidMessage, unreachable, timeout, setupNeeded, pairingMismatch, busy, connectionFailed, unknownSession
}

/// Ephemeral session control only. SDP has temporary ICE credentials; it is never
/// cached or mixed into character context. Account login remains on the phone.
public struct VoiceControl: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case start, answer, ready, activate, ack, mute, end, closed, heartbeat, failed
    }
    public let schema: Int
    public let kind: Kind
    public let sessionID: UUID
    public let requestID: UUID
    public var pairing: CharacterPairing?
    public var sdp: String?
    public var muted: Bool?
    public var error: String?

    public init(_ kind: Kind, sessionID: UUID, requestID: UUID = UUID(), pairing: CharacterPairing? = nil,
                sdp: String? = nil, muted: Bool? = nil, error: VoiceControlError? = nil) {
        schema = 1; self.kind = kind; self.sessionID = sessionID; self.requestID = requestID
        self.pairing = pairing; self.sdp = sdp; self.muted = muted; self.error = error?.rawValue
    }
    public func reply(_ kind: Kind, sdp: String? = nil, muted: Bool? = nil, error: VoiceControlError? = nil) -> Self {
        Self(kind, sessionID: sessionID, requestID: requestID, sdp: sdp, muted: muted, error: error)
    }
    public func encoded() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 48 * 1024,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys).isSubset(of: ["schema", "kind", "sessionID", "requestID", "pairing", "sdp", "muted", "error"]) else {
            throw VoiceControlError.invalidMessage
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    public func validate() throws {
        guard schema == 1 else { throw VoiceControlError.invalidMessage }
        try pairing?.validate()
        if let error { guard VoiceControlError(rawValue: error) != nil else { throw VoiceControlError.invalidMessage } }
        if let sdp { guard sdp.hasPrefix("v=0"), sdp.utf8.count <= 32 * 1024 else { throw VoiceControlError.invalidMessage } }
        switch kind {
        case .start: guard pairing?.appearance != nil, sdp != nil, error == nil else { throw VoiceControlError.invalidMessage }
        case .answer: guard sdp != nil, pairing == nil, error == nil else { throw VoiceControlError.invalidMessage }
        case .mute, .activate: guard muted != nil, sdp == nil, pairing == nil, error == nil else { throw VoiceControlError.invalidMessage }
        case .failed: guard error != nil, sdp == nil, pairing == nil else { throw VoiceControlError.invalidMessage }
        default: guard sdp == nil, pairing == nil, error == nil else { throw VoiceControlError.invalidMessage }
        }
    }
    public func matches(_ request: Self) -> Bool { sessionID == request.sessionID && requestID == request.requestID }
    public static func pairingMatches(_ watch: CharacterPairing, _ phone: CharacterPairing) -> Bool {
        watch.installation == phone.installation && watch.revision <= phone.revision &&
        watch.appearance != nil && phone.appearance?.sameDot(as: watch.appearance!) == true
    }
}
