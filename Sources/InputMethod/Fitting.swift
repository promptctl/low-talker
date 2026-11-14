import Foundation

/// A transcript shaped to the text around where it goes: spaced from its neighbours, capitalised
/// where a sentence starts, and without a closing mark where the field's text continues the
/// sentence. The dictation commit and the marked-text preview fit the same way, so a final does
/// not jump from the partials before it.
///
/// [LAW:effects-at-boundaries] Pure: the field was read once, by `FieldReading.read`, and this
/// decides from that reading alone.
public nonisolated struct Fitting: Equatable, Sendable {
    public let text: String
    public let outcome: Outcome

    /// What fitting did, as an event says it: the rules that changed the text, or why the field
    /// could not be read. No text, which is the person's words.
    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        case fitted(Set<Rule>)
        case unfitted(Unreadable)

        public var description: String {
            switch self {
            case let .fitted(rules) where rules.isEmpty: "fitted, unchanged"
            case let .fitted(rules): "fitted: \(Rule.allCases.filter(rules.contains).map(\.description).joined(separator: ", "))"
            case let .unfitted(reason): "unfitted, because \(reason)"
            }
        }
    }

    /// One change fitting can make, in the order fitting applies them: the closing mark goes
    /// before the capital is judged, and both before the spaces go on.
    public enum Rule: CaseIterable, Sendable, CustomStringConvertible {
        /// Its closing `.`, `?`, `!` or `…` dropped, since the text after it continues the sentence.
        case closingDropped
        /// Its first letter raised, since it starts the field, a line, or a sentence.
        case capitalized
        /// A space before it, since the character before it is neither whitespace nor an opener.
        case spacedBefore
        /// A space after it, since a word follows it.
        case spacedAfter

        public var description: String {
            switch self {
            case .closingDropped: "closing mark dropped"
            case .capitalized: "capitalized"
            case .spacedBefore: "space before"
            case .spacedAfter: "space after"
            }
        }

        /// `text`, changed by this rule if the text around it calls for it. Every rule leaves an
        /// empty text empty.
        func apply(to text: String, between before: String, and after: String) -> String {
            switch self {
            case .closingDropped:
                let body = trimmingEnd(text[...], Self.terminal.contains)
                let continues = after.drop(while: \.isSpaceOrTab).first?.isLowercase ?? false
                return continues && !body.isEmpty ? String(body) : text
            case .capitalized:
                // Spaces, then closing quotes and brackets, sit between a sentence's end and its
                // next word: `He said "Stop." ` ends one.
                let end = trimmingEnd(trimmingEnd(before[...], \.isSpaceOrTab), Self.closers.contains)
                let startsSentence = end.last.map { $0.isNewline || Self.terminal.contains($0) } ?? true
                guard startsSentence, let first = text.firstIndex(where: { !Self.openers.contains($0) }),
                      text[first].isLowercase else { return text }
                return text.replacingCharacters(in: first...first, with: text[first].uppercased())
            case .spacedBefore:
                guard let previous = before.last, let first = text.first, !previous.isWhitespace,
                      !Self.opens(before), !Self.closingPunctuation.contains(first) else { return text }
                return " " + text
            case .spacedAfter:
                guard !text.isEmpty, let next = after.first, next.isLetter || next.isNumber else { return text }
                return text + " "
            }
        }

        private static let terminal: Set<Character> = [".", "?", "!", "…"]
        private static let openingBrackets: Set<Character> = ["(", "[", "{"]
        private static let openingQuotes: Set<Character> = ["“", "‘", "«", "‹", "„", "‚"]
        private static let straightQuotes: Set<Character> = ["\"", "'"]
        /// What may stand before a sentence's first letter: a straight quote opens there.
        private static let openers = openingBrackets.union(openingQuotes).union(straightQuotes)
        private static let closers: Set<Character> = [")", "]", "}", "”", "’", "»", "›", "\"", "'"]
        /// What never takes a space before it.
        private static let closingPunctuation = closers.subtracting(straightQuotes).union(terminal).union([",", ";", ":", "%"])

        /// Whether `text` ends in an opening bracket or quote. A straight quote opens only where a
        /// word could start: at the start, after whitespace, or after another opener; after a
        /// letter it closes, as in `said "hi"`.
        private static func opens(_ text: String) -> Bool {
            guard let last = text.last else { return false }
            guard straightQuotes.contains(last) else { return openingBrackets.contains(last) || openingQuotes.contains(last) }
            let previous = text.dropLast().last
            return previous.map { $0.isWhitespace || openingBrackets.contains($0) || openingQuotes.contains($0) } ?? true
        }
    }

    /// `transcript` fitted to the text either side of where it goes. A field that cannot be read
    /// gets it back verbatim, saying why.
    ///
    /// A readable field gets it without its edge whitespace, which an engine puts before its words
    /// (`Transcript.text`), so the space rules alone decide the edges. A rule has fired when it
    /// changed the text. The selection is what the transcript replaces, so it is never looked at.
    ///
    /// [LAW:dataflow-not-control-flow] Every rule runs, in `Rule.allCases` order; the text around
    /// it decides whether one changes anything.
    public static func fit(_ transcript: String, to reading: FieldReading) -> Fitting {
        switch reading {
        case let .unreadable(reason):
            return Fitting(text: transcript, outcome: .unfitted(reason))
        case let .readable(context):
            var (text, fired) = (transcript.trimmingCharacters(in: .whitespacesAndNewlines), Set<Rule>())
            for rule in Rule.allCases {
                let changed = rule.apply(to: text, between: context.before, and: context.after)
                if changed != text { fired.insert(rule) }
                text = changed
            }
            return Fitting(text: text, outcome: .fitted(fired))
        }
    }
}

private nonisolated func trimmingEnd(_ text: Substring, _ trimmed: (Character) -> Bool) -> Substring {
    text[..<(text.lastIndex { !trimmed($0) }.map(text.index(after:)) ?? text.startIndex)]
}

private nonisolated extension Character {
    /// Whitespace within a line: a newline ends the line, which the rules read on its own.
    var isSpaceOrTab: Bool { isWhitespace && !isNewline }
}
