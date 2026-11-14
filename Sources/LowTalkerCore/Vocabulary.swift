import Foundation

/// What the speaker is expected to say that an engine could not guess the
/// spelling of: names and jargon. Each mode supplies one, and the engine is told
/// it before the utterance begins.
///
/// [LAW:types-are-the-program] A vocabulary is a list of terms and nothing else:
/// no flag for whether to use it, since the empty one is the one to use when
/// nothing beyond ordinary speech is expected.
public struct Vocabulary: Hashable, Sendable {
    public let terms: [Term]

    public init(_ terms: [Term]) {
        self.terms = terms
    }

    /// Nothing expected beyond ordinary speech.
    public static let empty = Vocabulary([])

    /// One thing the speaker may say, spelled as it should be written. The
    /// spelling and case are kept as given; they are the point.
    ///
    /// [LAW:parse-dont-validate] A term in hand can be said: it has a word in it
    /// by the same rule that scores hearing, so an engine is never handed a blank
    /// entry to prompt with, and the surrounding whitespace is gone.
    public struct Term: Hashable, Sendable, CustomStringConvertible {
        public let text: String

        public init(_ text: String) throws(VocabularyError) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !SpokenWords(trimmed).words.isEmpty else { throw VocabularyError.termSaysNothing(text) }
            self.text = trimmed
        }

        public var description: String { text }
    }
}

/// [LAW:single-enforcer] A term read from a file is a term made the one way terms are
/// made; this only carries the refusal onto the channel a decoder's caller is
/// listening on, so the position of the offending entry comes with it.
extension Vocabulary.Term: Decodable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(text)
        } catch {
            throw decoder.fault(error.description)
        }
    }
}

public enum VocabularyError: Error, Equatable, CustomStringConvertible {
    /// A term with no word in it: blank, or punctuation alone.
    case termSaysNothing(String)
    /// More prompt tokens than the engine keeps, refused by the engine that would
    /// otherwise drop the first terms without a word said.
    case tooLong(tokens: Int, limit: Int)
    /// A term for an engine that takes no vocabulary, refused rather than dropped, so a
    /// mode's terms are never quietly unheard.
    case engineTakesNone(Model)

    public var description: String {
        switch self {
        case .termSaysNothing(let text):
            "vocabulary term \"\(text)\" has no word in it"
        case .tooLong(let tokens, let limit):
            "the vocabulary is \(tokens) prompt tokens and the engine keeps at most \(limit)"
        case .engineTakesNone(let model):
            "\(model) hears no vocabulary, so a mode that names it can list no terms"
        }
    }
}
