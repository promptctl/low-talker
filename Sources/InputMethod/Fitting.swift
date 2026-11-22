import Foundation

/// A transcript shaped to the text around where it goes: spaced from its neighbours, capitalised
/// where a sentence starts, and without a closing period where the field's text continues the
/// sentence. One fit for the dictation commit and the marked-text preview alike, so that a final
/// does not jump from the partials before it.
///
/// [LAW:effects-at-boundaries] Pure over the text around where it goes, which `Commit` takes from
/// one reading of the field and the cursor's last commit.
public nonisolated struct Fitting: Equatable, Sendable {
    public let text: String
    /// The rules that changed the text.
    public let rules: Set<Rule>

    /// One change fitting can make, in the order fitting applies them: the edges are trimmed first,
    /// the period goes before the capital is judged, and all of them before the spaces go on.
    public enum Rule: CaseIterable, Sendable, CustomStringConvertible {
        /// Its edge whitespace removed, which an engine puts before its words (`Transcript.text`),
        /// so the space rules alone decide the edges.
        case trimmed
        /// Its closing period dropped, since the text after it continues the sentence or brings its
        /// own `, ; : . ? ! …`. A `?` or
        /// `!` says what was said, so it stays, as do an ellipsis and an initialism's own period.
        case periodDropped
        /// Its first letter title-cased, since it starts the field, a line, or a sentence. A first
        /// word that has a capital already, such as `iPhone`, is left as it is.
        case capitalized
        /// A space before it, since neither it nor the text before it joins the other.
        case spacedBefore
        /// A space after it, since neither it nor the text after it joins the other.
        case spacedAfter

        public var description: String {
            switch self {
            case .trimmed: "edge whitespace trimmed"
            case .periodDropped: "closing period dropped"
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
            case .periodDropped:
                let body = text.dropLast()
                let closes = text.last == "." && body.last.map { $0 != "." && !$0.isWhitespace } ?? false
                let continues = after.drop(while: \.isSpaceOrTab).first.map { $0.isLowercase || Self.clauseMarks.contains($0) } ?? false
                return closes && continues && !Self.endsInInitialism(body) ? String(body) : text
            case .capitalized:
                // Spaces, quotes and brackets sit between a sentence's end and its next word:
                // `He said "Stop." ` and `Hi. (` each end one.
                let end = trimmingEnd(before[...]) { $0.isSpaceOrTab || Self.openers.contains($0) || Self.closers.contains($0) }
                let startsSentence = end.last.map { $0.isNewline || Self.terminal.contains($0) && !Self.endsInInitialism(end) } ?? true
                guard startsSentence, let first = text.firstIndex(where: { !Self.openers.contains($0) }), text[first].isLowercase,
                      !text[first...].prefix(while: { !$0.isWhitespace }).contains(where: \.isUppercase) else { return text }
                return text.replacingCharacters(in: first...first, with: String(text[first]).capitalized)
            case .spacedBefore:
                return Self.spaced(before, text) ? " " + text : text
            case .spacedAfter:
                return Self.spaced(text, after) ? text + " " : text
            }
        }

        private static let terminal: Set<Character> = [".", "?", "!", "…"]
        private static let clauseMarks = terminal.union([",", ";", ":"])
        /// Opening brackets and quotes, and Spanish's inverted marks.
        private static let openingMarks: Set<Character> = ["(", "[", "{", "“", "‘", "«", "‹", "„", "‚", "¿", "¡"]
        private static let straightQuotes: Set<Character> = ["\"", "'"]
        /// What may stand before a sentence's first letter: a straight quote opens there.
        private static let openers = openingMarks.union(straightQuotes)
        private static let closers: Set<Character> = [")", "]", "}", "”", "’", "»", "›", "\"", "'"]
        /// What never takes a space before it.
        private static let closingPunctuation = closers.subtracting(straightQuotes).union(clauseMarks).union(["%"])

        /// What joins the words either side of it: `/ \ _`, as in `and/or` and `my_test`.
        private static let joiners: Set<Character> = ["/", "\\", "_"]
        /// What joins the word after it alone, as in `in #general`: `@ #`, and a currency sign.
        private static let prefixes: Set<Character> = ["@", "#"]
        /// A hyphen or dash, which closes up to the word on whichever side it touches.
        private static let dashes: Set<Character> = ["-", "‐", "–", "—"]

        /// Whether `text` ends in an initialism's period, as `a.m.`, `U.S.` and `e.g.` do: a word
        /// of single letters each followed by a period, inside any opening brackets or quotes.
        private static func endsInInitialism(_ text: Substring) -> Bool {
            let word = text[(text.lastIndex(where: \.isWhitespace).map(text.index(after:)) ?? text.startIndex)...]
            let letters = word.drop(while: openers.contains).split(separator: ".")
            return letters.count > 1 && letters.allSatisfy { $0.count == 1 && $0.first!.isLetter }
        }

        /// Whether a space goes between `left` and `right`: neither joins the other.
        private static func spaced(_ left: String, _ right: String) -> Bool {
            !joinsNext(left) && !joinsPrevious(right)
        }

        /// Whether the next word follows the end of `text` with no space: at the field's start, and
        /// after whitespace, an opening bracket or quote, a joiner, or a script written without
        /// spaces. A straight quote opens only where a word could start, after whitespace or an
        /// opener; after a letter it closes, as in `said "hi"`. A dash joins the word it is
        /// attached to, as in `e-mail` and `3–5`; after a space it stands apart, as in `well - maybe`.
        private static func joinsNext(_ text: String) -> Bool {
            guard let last = text.last else { return true }
            let previous = text.dropLast().last
            if straightQuotes.contains(last) {
                return previous.map { $0.isWhitespace || openingMarks.contains($0) } ?? true
            }
            if dashes.contains(last) { return previous.map { !$0.isWhitespace } ?? true }
            return last.isWhitespace || last.isCurrencySymbol || last.isUnspaced || joiners.contains(last)
                || prefixes.contains(last) || openingMarks.contains(last)
        }

        /// Whether the start of `text` follows the word before it with no space: at the field's
        /// end, and at whitespace, closing punctuation, a joiner, or a script written without
        /// spaces. A straight quote closes where no word follows it, as in `"hi" he said`; before
        /// a word it opens. A dash joins the word it is attached to, as in `—so`, but before a
        /// digit it is a minus sign, as in `is -5`.
        private static func joinsPrevious(_ text: String) -> Bool {
            guard let first = text.first else { return true }
            let next = text.dropFirst().first
            if straightQuotes.contains(first) { return next.map { !($0.isLetter || $0.isNumber) } ?? true }
            if dashes.contains(first) { return next.map { !$0.isWhitespace && !$0.isNumber } ?? true }
            return first.isWhitespace || first.isUnspaced || joiners.contains(first) || closingPunctuation.contains(first)
        }
    }

    /// `transcript` fitted to the text either side of where it goes.
    ///
    /// A rule has fired when it changed the text. The selection is what the transcript replaces,
    /// so it is never looked at.
    ///
    /// [LAW:dataflow-not-control-flow] Every rule runs, in `Rule.allCases` order; the text around
    /// it decides whether one changes anything.
    public static func fit(_ transcript: String, to context: DocumentContext) -> Fitting {
        var (text, fired) = (transcript, Set<Rule>())
        for rule in Rule.allCases {
            let changed = rule.apply(to: text, between: context.before, and: context.after)
            if changed != text { fired.insert(rule) }
            text = changed
        }
        return Fitting(text: text, rules: fired)
    }
}

private nonisolated func trimmingEnd(_ text: Substring, _ trimmed: (Character) -> Bool) -> Substring {
    text[..<(text.lastIndex { !trimmed($0) }.map(text.index(after:)) ?? text.startIndex)]
}

private nonisolated extension Character {
    /// Whitespace within a line: a newline ends the line, which the rules read on its own.
    var isSpaceOrTab: Bool { isWhitespace && !isNewline }

    /// Written in a script that puts no spaces between words: Han, kana, Thai, Lao, Myanmar or
    /// Khmer, or CJK punctuation and full-width forms (not halfwidth Hangul: Korean is spaced).
    var isUnspaced: Bool {
        unicodeScalars.first.map { scalar in
            scalar.properties.isIdeographic || Self.unspacedBlocks.contains { $0.contains(scalar.value) }
        } ?? false
    }

    private static let unspacedBlocks: [ClosedRange<UInt32>] = [
        0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3000...0x30FF, 0x31F0...0x31FF, 0xFF00...0xFF9F, 0xFFE0...0xFFEF,
    ]
}
