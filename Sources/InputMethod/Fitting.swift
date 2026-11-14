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

    /// One change fitting can make, in the order fitting applies them: the edges are trimmed first,
    /// the closing mark goes before the capital is judged, and all of them before the spaces go on.
    public enum Rule: CaseIterable, Sendable, CustomStringConvertible {
        /// Its edge whitespace removed, which an engine puts before its words (`Transcript.text`),
        /// so the space rules alone decide the edges.
        case trimmed
        /// Its closing `.`, `?`, `!` or `…` dropped, since the text after it continues the sentence.
        /// A last word with a period inside, such as `a.m.`, keeps its own.
        case closingDropped
        /// Its first letter title-cased, since it starts the field, a line, or a sentence.
        case capitalized
        /// A space before it, since the text before it ends a word the next one does not join.
        case spacedBefore
        /// A space after it, since a word follows it.
        case spacedAfter

        public var description: String {
            switch self {
            case .trimmed: "edge whitespace trimmed"
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
            case .trimmed:
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .closingDropped:
                let body = trimmingEnd(text[...], Self.terminal.contains)
                let abbreviated = body.split(whereSeparator: \.isWhitespace).last?.contains(".") ?? false
                let continues = after.drop(while: \.isSpaceOrTab).first?.isLowercase ?? false
                return continues && !body.isEmpty && !abbreviated ? String(body) : text
            case .capitalized:
                // Spaces, quotes and brackets sit between a sentence's end and its next word:
                // `He said "Stop." ` and `Hi. (` each end one.
                let end = trimmingEnd(before[...]) { $0.isSpaceOrTab || Self.openers.contains($0) || Self.closers.contains($0) }
                let startsSentence = end.last.map { $0.isNewline || Self.terminal.contains($0) } ?? true
                guard startsSentence, let first = text.firstIndex(where: { !Self.openers.contains($0) }),
                      text[first].isLowercase else { return text }
                return text.replacingCharacters(in: first...first, with: String(text[first]).capitalized)
            case .spacedBefore:
                guard let first = text.first, !Self.joinsNext(before), !first.isUnspaced,
                      !Self.closingPunctuation.contains(first) else { return text }
                return " " + text
            case .spacedAfter:
                guard let last = text.last, let next = after.first, next.isLetter || next.isNumber,
                      !last.isUnspaced, !next.isUnspaced else { return text }
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

        /// What a word joins with no space before it: a currency sign, as in `$5`, and `/ \ @ # _`.
        private static let joiners: Set<Character> = ["/", "\\", "@", "#", "_"]
        private static let hyphens: Set<Character> = ["-", "‐"]

        /// Whether the next word follows the end of `text` with no space: at the field's start, and
        /// after whitespace, an opening bracket or quote, a joiner, or a script written without
        /// spaces. A straight quote opens only where a word could start, after whitespace or an
        /// opener; after a letter it closes, as in `said "hi"`. A hyphen joins the word it is
        /// attached to, as in `e-mail`; after a space it is a dash, as in `well - maybe`.
        private static func joinsNext(_ text: String) -> Bool {
            guard let last = text.last else { return true }
            let previous = text.dropLast().last
            if straightQuotes.contains(last) {
                return previous.map { $0.isWhitespace || openingBrackets.contains($0) || openingQuotes.contains($0) } ?? true
            }
            if hyphens.contains(last) { return previous.map { !$0.isWhitespace } ?? true }
            return last.isWhitespace || last.isCurrencySymbol || last.isUnspaced || joiners.contains(last)
                || openingBrackets.contains(last) || openingQuotes.contains(last)
        }
    }

    /// `transcript` fitted to the text either side of where it goes. A field that cannot be read
    /// gets it back verbatim, saying why.
    ///
    /// A rule has fired when it changed the text. The selection is what the transcript replaces,
    /// so it is never looked at.
    ///
    /// [LAW:dataflow-not-control-flow] Every rule runs, in `Rule.allCases` order; the text around
    /// it decides whether one changes anything.
    public static func fit(_ transcript: String, to reading: FieldReading) -> Fitting {
        switch reading {
        case let .unreadable(reason):
            return Fitting(text: transcript, outcome: .unfitted(reason))
        case let .readable(context):
            var (text, fired) = (transcript, Set<Rule>())
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

    /// Written in a script that puts no spaces between words: Han, kana, Thai, Lao, Myanmar or
    /// Khmer, or CJK punctuation and full-width forms.
    var isUnspaced: Bool {
        unicodeScalars.first.map { scalar in
            scalar.properties.isIdeographic || Self.unspacedBlocks.contains { $0.contains(scalar.value) }
        } ?? false
    }

    private static let unspacedBlocks: [ClosedRange<UInt32>] = [
        0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3000...0x30FF, 0x31F0...0x31FF, 0xFF00...0xFFEF,
    ]
}
