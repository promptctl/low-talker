import Foundation

/// What the engine heard, word by word. Never a bare string: timings and confidence
/// are what let a reader trust, trim, or reject what was said.
///
/// [LAW:one-source-of-truth] The words are the transcript; `text` is derived from them
/// so the two can never disagree.
public struct Transcript: Hashable, Codable, Sendable {
    public let words: [Word]
    /// Seconds of quiet no pass was handed, before the speech and between it: heard as
    /// nothing, while the words are still timed in the audio as it was sent.
    public let quiet: TimeInterval
    /// The peak of the quietest tenth of a second heard, digital silence aside: the least
    /// room the quiet was judged against. None when no room was heard.
    public let room: Float?
    /// Seconds within range of the loudest that stood too near the room to be speech.
    public let refusedAsRoom: TimeInterval

    public init(words: [Word], quiet: TimeInterval = 0, room: Float? = nil, refusedAsRoom: TimeInterval = 0) {
        self.words = words
        self.quiet = quiet
        self.room = room
        self.refusedAsRoom = refusedAsRoom
    }

    /// A transcript nobody spoke: text typed in for a dry run or a test. Whitespace
    /// rides with the word after it (trailing whitespace with the last), so `text`
    /// reads back verbatim; whitespace alone is nothing said. Every word is
    /// instantaneous and certain, since no time passed and nothing was recognized.
    public init(typed text: String) {
        self.words = text.matches(of: /\s*\S+(?:\s+$)?/).map { match in
            Word(text: String(match.output), time: 0...0, confidence: 1.0)
        }
        self.quiet = 0
        self.room = nil
        self.refusedAsRoom = 0
    }

    /// The words concatenated as the engine emitted them. Each word carries its own
    /// leading whitespace and trailing punctuation, so concatenation reproduces the
    /// utterance exactly.
    public var text: String {
        words.map(\.text).joined()
    }

    /// Whether nothing was said: no words, or only whitespace. The `typed:` initializer
    /// drops whitespace-only input to no words, but the engine can hand back a lone
    /// whitespace word, so an empty utterance is this predicate — not `text.isEmpty`,
    /// which a whitespace-only word slips past.
    /// [LAW:one-source-of-truth] one test for "nothing said", so the executor inserts
    /// nothing for exactly what is nothing.
    public var isBlank: Bool {
        !text.contains { !$0.isWhitespace }
    }

    /// The text with the fewest of the oldest words dropped behind an ellipsis that leave the
    /// rest fitting, as a line truncated at its head shows it but at whole words. The newest
    /// word stays even when it fits alone nowhere, since it is the one being watched.
    public func truncatingHead(toFit fits: (String) -> Bool) -> String {
        // The first word shown carries the space the engine put before it, which a line has no use for.
        let from = { (first: Int) in String(Transcript(words: Array(words[first...])).text.drop(while: \.isWhitespace)) }
        guard words.count > 1, !fits(from(0)) else { return from(0) }
        // Binary search, since dropping more words never makes the rest harder to fit.
        var (fewest, most) = (1, words.count - 1)
        while fewest < most {
            let dropped = (fewest + most) / 2
            if fits("…" + from(dropped)) { most = dropped } else { fewest = dropped + 1 }
        }
        return "…" + from(fewest)
    }

    public struct Word: Hashable, Codable, Sendable {
        public let text: String
        /// Seconds from the start of the clip. A ClosedRange makes an end before a
        /// start unrepresentable.
        public let time: ClosedRange<TimeInterval>
        public let confidence: Confidence

        public init(text: String, time: ClosedRange<TimeInterval>, confidence: Confidence) {
            self.text = text
            self.time = time
            self.confidence = confidence
        }
    }
}

/// An engine's probability for a word, 0 through 1. Values outside that range do not
/// exist: a literal outside it is a programmer error, a runtime value outside it is
/// nil, and decoded input outside it is refused.
public struct Confidence: Hashable, Codable, Sendable, Comparable, ExpressibleByFloatLiteral {
    public static let range: ClosedRange<Double> = 0...1

    public let value: Double

    public init?(exactly value: Double) {
        guard Self.range.contains(value) else { return nil }
        self.value = value
    }

    public init(floatLiteral value: Double) {
        precondition(Self.range.contains(value), "confidence \(value) is outside \(Self.range)")
        self.value = value
    }

    /// [LAW:parse-dont-validate] Decoded as a bare number; refused here, once, so no
    /// consumer re-checks the range.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Double.self)
        guard let confidence = Self(exactly: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "confidence \(value) is outside \(Self.range)")
        }
        self = confidence
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /// The probability's natural log, the quantity Whisper's avg_logprob averages. Engines
    /// hand probabilities over as Float, so a zero is one below the least a Float holds and
    /// is read as that least, which keeps every log finite (about -103.3).
    public var logProbability: Double {
        log(max(value, Double(Float.leastNonzeroMagnitude)))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}
