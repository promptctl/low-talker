import Foundation

/// The settings the app runs on: the model the engine loads, what the microphone does
/// between presses, the modes a chord can start, and where the transcription server
/// listens. Nothing here is read from disk;
/// `Config(toml:)` is where a file becomes one.
///
public struct Config: Hashable, Sendable {
    public let model: ModelName
    /// What the microphone does while nobody is dictating. The config file is its only
    /// writer, so a microphone held at rest is one the user asked for in writing.
    /// [LAW:single-enforcer]
    public let microphone: MicrophoneAtRest
    public let modes: Modes
    public let serve: ServeBinding

    public init(model: ModelName, microphone: MicrophoneAtRest, modes: [Mode], serve: ServeBinding) throws(ConfigError) {
        self.model = model
        self.microphone = microphone
        self.modes = try Modes(modes)
        self.serve = serve
    }

    /// What the app runs on when no file says otherwise: dictation, on the default chord,
    /// with the default model, the microphone shut between presses, and the server on
    /// loopback.
    ///
    /// [LAW:one-source-of-truth] The model and the modes are the values their own owners
    /// already name, so the no-file behaviour cannot drift from the behaviour those owners
    /// describe. `shut` and `loopback` have no owner elsewhere to name, and are spelled here
    /// because here is what they mean: with no file to ask for anything, the microphone is
    /// closed and nothing off this Mac reaches the server. The
    /// force-try says the author vouches for this one: a default that does not hold
    /// together is a bug in this file, and it traps where it is written.
    public static let `default` = try! Config(model: .default, microphone: .shut, modes: [.dictation], serve: .loopback)
}

/// The modes a config runs, in the order the file declared them, because that is the order
/// any listing should speak of them in.
///
/// [LAW:parse-dont-validate] Modes in hand hold together: there is at least one, and no two
/// answer to one chord, share a name, or go without one. The initializer is the only way to
/// make them, so those facts are established once here and never asked again downstream -
/// which is why a chord pressed selects *the* mode it belongs to.
public struct Modes: RandomAccessCollection, Hashable, Sendable, CustomStringConvertible {
    private let modes: [Mode]

    public init(_ modes: [Mode]) throws(ConfigError) {
        guard !modes.isEmpty else { throw ConfigError.noModes }
        var names: Set<String> = []
        var chords: Set<KeyChord> = []
        for mode in modes {
            guard !mode.name.isEmpty else { throw ConfigError.modeUnnamed }
            guard names.insert(mode.name).inserted else { throw ConfigError.twoModesNamed(mode.name) }
            guard chords.insert(mode.chord).inserted else { throw ConfigError.twoModesOnOneChord(mode.name) }
        }
        self.modes = modes
    }

    public var startIndex: Int { modes.startIndex }
    public var endIndex: Int { modes.endIndex }
    public subscript(position: Int) -> Mode { modes[position] }

    /// Every chord a mode answers to. One chord per mode, and never empty.
    public var chords: Set<KeyChord> {
        Set(map(\.chord))
    }

    /// Each mode as a log line names it, in order.
    public var description: String {
        "[\(map(\.description).joined(separator: ", "))]"
    }
}

/// One way of speaking: the chord that starts it, and what the engine is told to expect
/// before any words arrive.
///
/// [LAW:one-type-per-behavior] Dictation is not a case in code. It is a Mode like
/// every other, the one `Config.default` supplies when no file names any.
public struct Mode: Hashable, Sendable, CustomStringConvertible {
    /// How the mode is spoken of in errors.
    public let name: String
    /// The chord that selects this mode. The press it begins carries the mode, so which
    /// mode is running is settled before a word is heard.
    public let chord: KeyChord
    /// What the engine is told to expect, so a name it could not have guessed is
    /// spelled the way this mode wants it.
    public let vocabulary: Vocabulary

    /// The name arrives trimmed, as a Vocabulary term does, so that two modes cannot
    /// differ by spacing alone.
    public init(name: String, chord: KeyChord, vocabulary: Vocabulary = .empty) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chord = chord
        self.vocabulary = vocabulary
    }

    /// The mode as a log line names it: its name, its chord, and how many terms it expects,
    /// never the terms, which can be the names of people.
    public var description: String {
        "mode \"\(name)\" (\(Hotkey.named(chord)), \(vocabulary.terms.count) vocabulary term\(vocabulary.terms.count == 1 ? "" : "s"))"
    }

    /// Hold the hotkey, speak, and the words are typed wherever the focus is, on the
    /// default chord.
    public static let dictation = Mode(name: "dictation", chord: Hotkey.defaultChord, vocabulary: .empty)
}

/// What is wrong with a config, in the words a person editing the file needs.
///
/// [LAW:no-silent-failure] Every case here is a file that was written but not
/// understood. None of them is answered with the defaults: "there is no config" and
/// "there is a config I could not read" are different facts, and collapsing them
/// would run the app on settings its owner never chose.
public enum ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file is not TOML at all, at the line where reading it stopped.
    case notTOML(String, line: Int)
    /// A key the schema has no place for, named with where it sits so the typo can be
    /// found.
    case unknownKeys([String])
    /// The file is TOML, but something in it was refused: where, and why, in the words
    /// of whichever decoder did the refusing.
    case wrongShape(String)
    case noModes
    case modeUnnamed
    case twoModesNamed(String)
    case twoModesOnOneChord(String)
    /// A mode whose vocabulary the engine cannot be told, named with why.
    case vocabulary(mode: String, VocabularyError)
    /// A `[serve]` table that names no binding a server can listen on.
    case serve(ServeBindingError)
    /// The file exists but could not be read at all, in the words the system used.
    case unreadable(path: String, why: String)
    /// A refusal the parser reported that this file has no better words for. Carried
    /// rather than dropped: a fault nobody named is worse than one named awkwardly.
    case notUnderstood(String)

    public var description: String {
        switch self {
        case .notTOML(let why, let line):
            "line \(line) is not TOML: \(why)"
        case .unknownKeys(let keys):
            "nothing in a config is called \(keys.map { "\"\($0)\"" }.joined(separator: ", "))"
        case .wrongShape(let why):
            why
        case .noModes:
            "the config declares no modes, so no chord would start listening"
        case .modeUnnamed:
            "a mode has no name"
        case .twoModesNamed(let name):
            "two modes are named \"\(name)\""
        case .twoModesOnOneChord(let name):
            "mode \"\(name)\" answers to a chord another mode already answers to"
        case .vocabulary(let name, let error):
            "mode \"\(name)\": \(error)"
        case .serve(let error):
            "\(error)"
        case .unreadable(let path, let why):
            "\(path) could not be read: \(why)"
        case .notUnderstood(let why):
            why
        }
    }
}
