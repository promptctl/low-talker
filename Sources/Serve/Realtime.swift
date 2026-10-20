import Foundation
import LowTalkerCore

/// The Realtime transcription session a client configures with `session.update`: what it
/// can change and the server echoes back (epic low-serve-axq). Audio is always PCM16 at
/// 24 kHz and turns always end with the client's commit, so neither is state.
struct RealtimeSession: Sendable, Equatable {
    /// `transcription: null` until the client names one; an item is heard the same way
    /// either way, as English with no vocabulary.
    var transcription: Transcription?

    struct Transcription: Sendable, Equatable {
        let model: String?
        let language: Language?
        let prompt: String?
        let vocabulary: Vocabulary
    }

    var vocabulary: Vocabulary { transcription?.vocabulary ?? Vocabulary([]) }

    /// The session object as OpenAI writes it in `session.created` and `session.updated`.
    func json(id: String) -> [String: Any] {
        let transcription: Any = transcription.map {
            ["model": nullable($0.model), "language": nullable($0.language?.rawValue), "prompt": nullable($0.prompt)]
        } ?? NSNull()
        return [
            "type": "transcription", "object": "realtime.transcription_session", "id": id, "expires_at": 0, "include": NSNull(),
            "audio": ["input": [
                "format": RealtimeAudio.format, "transcription": transcription, "noise_reduction": NSNull(), "turn_detection": NSNull(),
            ]],
        ]
    }
}

/// The one audio format a Realtime transcription session takes: the spec allows only
/// 24 kHz for `audio/pcm`, and Pipecat sends it.
enum RealtimeAudio {
    static let rate = 24_000
    static var format: [String: Any] { ["type": "audio/pcm", "rate": rate] }

    /// Seconds in `bytes` of it, a trailing half sample counting for nothing.
    static func duration(bytes: Int) -> TimeInterval {
        Double(bytes / 2) / Double(rate)
    }
}

/// What a client sends, parsed. [LAW:parse-dont-validate] An update in hand is the whole
/// session the client asked for, already checked against what the server can do, and an
/// append is audio bytes, already decoded.
enum ClientEvent: Sendable {
    case update(RealtimeSession)
    case append(Data)
    case commit

    /// A client message as the JSON object every event is.
    static func object(_ text: String) throws(RealtimeError) -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw .notJSON(String(text.prefix(80)))
        }
        return object
    }

    /// The event `object` is, applied to `session` when it is an update.
    static func parse(_ object: [String: Any], onto session: RealtimeSession) throws(RealtimeError) -> ClientEvent {
        guard let type = object["type"] as? String else { throw .missing("type") }
        switch type {
        case "session.update":
            return .update(try update(session, with: fields(object["session"], at: "session", allowing: ["type", "audio", "include"]) ?? [:]))
        case "input_audio_buffer.append":
            guard let audio = object["audio"] as? String else { throw .missing("audio") }
            guard let bytes = Data(base64Encoded: audio) else { throw .invalidValue("audio", "is not base64") }
            return .append(bytes)
        case "input_audio_buffer.commit":
            return .commit
        default:
            throw .unknownEvent(type)
        }
    }

    /// `session` with every field `update` names changed to what it names, or refused
    /// whole. [LAW:no-silent-failure] A field asking for what the server does not do
    /// (server-side turn detection, noise reduction, another format) is refused by name.
    private static func update(_ session: RealtimeSession, with update: [String: Any]) throws(RealtimeError) -> RealtimeSession {
        if let type = update["type"], type as? String != "transcription" {
            throw .invalidValue("session.type", "must be transcription; this server holds transcription sessions only")
        }
        try requireNull(update["include"], at: "session.include", "no extra output is offered")
        let audio = try fields(update["audio"], at: "session.audio", allowing: ["input"])
        let input = try fields(audio?["input"], at: "session.audio.input", allowing: ["format", "transcription", "noise_reduction", "turn_detection"]) ?? [:]
        if let format = input["format"] {
            let given = format as? [String: Any]
            guard given?["type"] as? String == "audio/pcm", given?["rate"] as? Int == RealtimeAudio.rate else {
                throw .invalidValue("session.audio.input.format", "must be {\"type\": \"audio/pcm\", \"rate\": 24000}")
            }
        }
        try requireNull(input["noise_reduction"], at: "session.audio.input.noise_reduction", "noise reduction is not offered")
        try requireNull(input["turn_detection"], at: "session.audio.input.turn_detection", "server-side turn detection is not offered; send null and commit each turn")
        var session = session
        switch input["transcription"] {
        case nil: break
        case is NSNull: session.transcription = nil
        default: session.transcription = try transcription(input["transcription"])
        }
        return session
    }

    private static func transcription(_ value: Any?) throws(RealtimeError) -> RealtimeSession.Transcription {
        let path = "session.audio.input.transcription"
        let fields = try fields(value, at: path, allowing: ["model", "language", "prompt"]) ?? [:]
        let model = try string(fields["model"], at: "\(path).model")
        let prompt = try string(fields["prompt"], at: "\(path).prompt")
        let language = try string(fields["language"], at: "\(path).language").map { name throws(RealtimeError) in
            guard let language = Language(rawValue: name) else { throw .invalidValue("\(path).language", "\(name) is not supported; use \(Language.accepted)") }
            return language
        }
        let vocabulary: Vocabulary
        do {
            vocabulary = try Vocabulary(prompt: prompt)
        } catch {
            throw .promptRefused("\(error)")
        }
        return RealtimeSession.Transcription(model: model, language: language, prompt: prompt, vocabulary: vocabulary)
    }

    /// An object's fields, nil when it is absent or null, refused when it is anything else
    /// or names a field outside `allowing`.
    private static func fields(_ value: Any?, at path: String, allowing: Set<String>) throws(RealtimeError) -> [String: Any]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let fields = value as? [String: Any] else { throw .invalidValue(path, "must be an object") }
        if let unknown = fields.keys.sorted().first(where: { !allowing.contains($0) }) { throw .unknownParameter("\(path).\(unknown)") }
        return fields
    }

    private static func string(_ value: Any?, at path: String) throws(RealtimeError) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw .invalidValue(path, "must be a string") }
        return string
    }

    private static func requireNull(_ value: Any?, at path: String, _ reason: String) throws(RealtimeError) {
        guard value == nil || value is NSNull else { throw .invalidValue(path, "must be null: \(reason)") }
    }
}

/// Every way a client event can be refused, and every way an item can fail, in OpenAI's
/// error shape. [LAW:one-source-of-truth] Each case's code, words and parameter are read
/// off it, so an `error` event and a failed item say the same thing.
enum RealtimeError: Error, Equatable, Sendable {
    case invalidAPIKey
    case notJSON(String)
    case missing(String)
    case unknownEvent(String)
    case unknownParameter(String)
    case invalidValue(String, String)
    case bufferEmpty
    /// An append that would take the open item to `seconds`, past the `limit` any item holds.
    case audioTooLong(seconds: TimeInterval, limit: TimeInterval)
    case promptRefused(String)
    case engineFailed(String)

    var type: String {
        switch self {
        case .engineFailed: "server_error"
        case .invalidAPIKey, .notJSON, .missing, .unknownEvent, .unknownParameter, .invalidValue, .bufferEmpty, .audioTooLong, .promptRefused: "invalid_request_error"
        }
    }

    var code: String {
        switch self {
        case .invalidAPIKey: "invalid_api_key"
        case .notJSON: "invalid_json"
        case .missing: "missing_required_parameter"
        case .unknownEvent: "unknown_event"
        case .unknownParameter: "unknown_parameter"
        case .invalidValue, .promptRefused: "invalid_value"
        case .bufferEmpty: "input_audio_buffer_commit_empty"
        case .audioTooLong: "audio_too_long"
        case .engineFailed: "transcription_failed"
        }
    }

    var message: String {
        switch self {
        case .invalidAPIKey: "Incorrect API key provided."
        case .notJSON(let text): "The event is not a JSON object: \(text)"
        case .missing(let param): "The \(param) field is required."
        case .unknownEvent(let type): "The event type \(type) is not supported."
        case .unknownParameter(let param): "The \(param) parameter is not supported."
        case .invalidValue(let param, let reason): "The \(param) \(reason)."
        case .bufferEmpty: "The input audio buffer is empty; append audio before committing it."
        case .audioTooLong(let seconds, let limit): "The append would take what this session holds, the audio in the input audio buffer and in items not yet transcribed and a second for each item, to \(Int(seconds.rounded(.up))) seconds; the limit is \(Int(limit))."
        case .promptRefused(let reason): "The prompt cannot be used: \(reason)."
        case .engineFailed(let reason): "Transcription failed: \(reason)."
        }
    }

    var param: String? {
        switch self {
        case .missing(let param), .unknownParameter(let param), .invalidValue(let param, _): param
        case .unknownEvent: "type"
        case .promptRefused: "session.audio.input.transcription.prompt"
        case .audioTooLong: "audio"
        case .invalidAPIKey, .notJSON, .bufferEmpty, .engineFailed: nil
        }
    }
}

/// What the server sends. [LAW:types-are-the-program] Each event is a case carrying exactly
/// its own facts; `json` is the one place they meet OpenAI's field names.
enum ServerEvent: Sendable {
    case sessionCreated(id: String, RealtimeSession)
    case sessionUpdated(id: String, RealtimeSession)
    case delta(item: String, String)
    case committed(item: String, previous: String?)
    case itemAdded(item: String, previous: String?)
    case itemDone(item: String, previous: String?)
    /// Only the transcript of what was heard is sent; its quiet and nothing-spoken peak are the
    /// server's own record of the item, for which OpenAI's event has no field, as are the
    /// passes the engine failed to read, on either answer.
    case completed(item: String, heard: Heard, usage: Usage, unread: Partial.Unread?)
    case failed(item: String, RealtimeError, unread: Partial.Unread?)
    /// A refusal of the client event whose `event_id` is given, when it gave one.
    case error(RealtimeError, clientEvent: String?)

    var type: String {
        switch self {
        case .sessionCreated: "session.created"
        case .sessionUpdated: "session.updated"
        case .delta: "conversation.item.input_audio_transcription.delta"
        case .committed: "input_audio_buffer.committed"
        case .itemAdded: "conversation.item.added"
        case .itemDone: "conversation.item.done"
        case .completed: "conversation.item.input_audio_transcription.completed"
        case .failed: "conversation.item.input_audio_transcription.failed"
        case .error: "error"
        }
    }

    /// The event as one text message, with an `event_id` of its own.
    var json: Data {
        var fields: [String: Any] = ["type": type, "event_id": "event_\(ID.fresh())"]
        switch self {
        case .sessionCreated(let id, let session), .sessionUpdated(let id, let session):
            fields["session"] = session.json(id: id)
        case .delta(let item, let text):
            fields.merge(["item_id": item, "content_index": 0, "delta": text]) { $1 }
        case .committed(let item, let previous):
            fields.merge(["item_id": item, "previous_item_id": nullable(previous)]) { $1 }
        case .itemAdded(let item, let previous), .itemDone(let item, let previous):
            fields["previous_item_id"] = nullable(previous)
            fields["item"] = [
                "id": item, "type": "message", "status": "completed", "role": "user",
                "content": [["type": "input_audio", "transcript": NSNull()]],
            ]
        case .completed(let item, let heard, let usage, _):
            fields.merge(["item_id": item, "content_index": 0, "transcript": heard.transcription.transcript.served,
                          "usage": ["type": usage.type, "seconds": usage.seconds]]) { $1 }
        case .failed(let item, let error, _):
            fields.merge(["item_id": item, "content_index": 0, "error": Self.detail(error, clientEvent: nil)]) { $1 }
        case .error(let error, let clientEvent):
            fields["error"] = Self.detail(error, clientEvent: clientEvent)
        }
        // [LAW:no-silent-failure] Strings, numbers, nulls and containers of them only,
        // so a throw here is a programming error and traps.
        return try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func detail(_ error: RealtimeError, clientEvent: String?) -> [String: Any] {
        ["type": error.type, "code": error.code, "message": error.message, "param": nullable(error.param), "event_id": nullable(clientEvent)]
    }
}

/// Session, item and event ids: a prefix OpenAI's ids carry and 24 hex digits.
enum ID {
    static func fresh() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
    }
}

/// A JSON value that is null when absent, as OpenAI writes every field it has no value for.
private func nullable(_ value: Any?) -> Any {
    value ?? NSNull()
}
