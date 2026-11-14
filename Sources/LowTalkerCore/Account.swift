import GrammaticalNumber
import WhisperKit

/// What a failure tells the log: its facts, in the clear, and the words the person dictated,
/// when it carries any, which the log keeps private. The split the session line makes:
/// numbers public, words private, decided by the type that owns them.
public struct Account: Equatable, Sendable {
    public let facts: String
    public let dictated: String?

    public init(facts: String, dictated: String? = nil) {
        self.facts = facts
        self.dictated = dictated
    }
}

/// A failure that says by its type which part of its account is what the person dictated.
/// The dictation loop's seams throw closed types and it reports only these, so a failure that
/// has not said cannot reach the log, and the log never guesses; the server logs the facts alone.
/// [LAW:types-are-the-program]
public protocol Accounted: Error, CustomStringConvertible {
    var account: Account { get }
}

/// A failure whose description is facts about the press - counts, names, durations - and
/// never the words said, so its whole account is in the clear.
public protocol WordFree: Accounted {}

extension WordFree {
    public var account: Account { Account(facts: description) }
}

// An enum whose cases could one day carry the words names each case, so a case added
// to it does not compile until it has said what it carries.

extension TranscriptionFailure: Accounted {
    public var account: Account {
        switch self {
        case .cancelled, .nothingSpoken, .vocabulary, .engine: Account(facts: description)
        case .unreadable(let reading): reading.account
        }
    }
}

extension Unreadable: Accounted {
    public var account: Account {
        switch self {
        case .whisperKit(let reading): reading.account
        case .parakeet(let reading): reading.account
        }
    }
}

extension ParakeetReadingError: Accounted {
    public var account: Account {
        switch self {
        case .durationOutOfRange, .tokenOutsideVocabulary: Account(facts: description)
        // A control piece is the model's, not the person's: `<unk>` says nothing that was said.
        case .controlToken: Account(facts: description)
        case .probabilityOutsideUnitInterval(let probability, let piece):
            Account(facts: "Parakeet gave a token a probability \(probability), outside \(Confidence.range)", dictated: piece)
        }
    }
}

extension WhisperKitTranscriberError: Accounted {
    public var account: Account {
        switch self {
        case .tokenizerNotLoaded: Account(facts: description)
        case .speechWithoutWords(let text):
            Account(facts: "WhisperKit returned a segment of \(counted(text.count, "character", "characters")) without word timings", dictated: text)
        case .probabilityOutsideUnitInterval(let word):
            Account(facts: "WhisperKit gave a word probability \(word.probability), outside \(Confidence.range)", dictated: word.word)
        case .wordEndsBeforeStart(let word):
            Account(facts: "WhisperKit gave a word an end \(word.end) before its start \(word.start)", dictated: word.word)
        }
    }
}
