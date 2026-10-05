import Foundation

/// Decodes only observed event envelopes. Unknown events remain non-actionable.
public enum DotVoiceEvent: Sendable, Equatable {
    case sessionStarted
    case contextAppended
    case inputTranscript(JSONValue)
    case outputTranscript(JSONValue)
    case turnCreated(JSONValue)
    case turnDelta(JSONValue)
    case turnDone(JSONValue)
    case usage(JSONValue)
    case serviceError
    case unknown

    public init(data: Data) throws {
        guard data.count <= 1024 * 1024 else { throw DotError.invalidResponse }
        let value = try JSONValue.decode(data)
        switch value["type"].string {
        case "session.started": self = .sessionStarted
        case "session.context.appended": self = .contextAppended
        case "input_transcript.added": self = .inputTranscript(value)
        case "output_transcript.added": self = .outputTranscript(value)
        case "turn.created": self = .turnCreated(value)
        case "turn.delta": self = .turnDelta(value)
        case "turn.done": self = .turnDone(value)
        case "session.usage.updated": self = .usage(value)
        case "error": self = .serviceError
        default: self = .unknown
        }
    }
}
