import Foundation

/// Safe for diagnostics: never embeds server bodies, URLs, identifiers or credentials.
public enum DotError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCredentials, invalidResponse, unavailable, identityMismatch, unsafeURL
    case http(Int), rpc(Int), timeout, disconnected, unsupportedRequest, invalidAudio
    case snapshotMismatch, fileExists
    case callAlreadyActive, callNotActive
    case accountChangeRequiresSignOut

    public var description: String {
        switch self {
        case .invalidCredentials: "ChatGPT credentials are missing or invalid."
        case .invalidResponse: "The service returned an unrecognized response."
        case .unavailable: "The primary Dot is unavailable."
        case .identityMismatch: "Dot and conversation identity could not be verified."
        case .unsafeURL: "The request failed the endpoint safety check."
        case .http(let status): "The service returned HTTP \(status)."
        case .rpc(let code): "The service returned RPC error \(code)."
        case .timeout: "The operation timed out."
        case .disconnected: "The connection ended."
        case .unsupportedRequest: "An interaction requires the official ChatGPT client."
        case .invalidAudio: "Audio must be mono PCM16 WAV at 24 kHz."
        case .snapshotMismatch: "The downloaded character does not match its published hash."
        case .fileExists: "The output already exists; choose a fresh path."
        case .callAlreadyActive: "A voice connection is already starting or active."
        case .callNotActive: "This voice connection is no longer active."
        case .accountChangeRequiresSignOut: "Sign out before connecting a different account."
        }
    }
}

public struct ChatGPTCredentials: Sendable {
    public let accessToken: String
    public let accountID: String

    public init(accessToken: String, accountID: String) throws {
        guard !accessToken.isEmpty, !accountID.isEmpty,
              !accessToken.contains(where: \.isWhitespace),
              !accountID.contains(where: { $0.isNewline || $0 == "\r" }) else { throw DotError.invalidCredentials }
        self.accessToken = accessToken
        self.accountID = accountID
    }
}
