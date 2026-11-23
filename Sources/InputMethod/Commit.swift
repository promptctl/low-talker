import Foundation
import Insertion

/// One commit decided against the field: the words as they go in, the range they go in at, and
/// how they were placed there.
///
/// [LAW:effects-at-boundaries] Pure over one reading of the field and the run of words the input
/// method last put before a caret there. `Client` reads the field, keeps the run, and makes the
/// `insertText` this decides.
public nonisolated struct Commit: Equatable, Sendable {
    public let text: String
    /// NSNotFound for a dictation: at the client's selection, which the client replaces by its own
    /// rule, a client without document access included. For a take-back, the range the words to
    /// take back were proved to fill, which only a client that was read is sent.
    let replacementRange: NSRange
    public let placement: Placement
    /// The input method's words before the caret this commit leaves, its own last among them: what
    /// the client keeps for the next commit, and never part of an event, being the person's words.
    let run: Run?

    /// How the words were placed: fitted to a field that was read, or as the engine wrote them,
    /// because the field could not be read.
    ///
    /// [LAW:types-are-the-program] One fact, so one value: a commit fitted to a field that was not
    /// read, or unfitted in a field that was, cannot be made.
    public enum Placement: Equatable, Sendable, CustomStringConvertible {
        case fitted(Fitted)
        case unfitted(Unreadable)

        /// The characters the words take the place of, where the field was read: the selection,
        /// or the words a take-back names.
        public var replaced: Int? {
            switch self {
            case .fitted(let fitted): fitted.replaced
            case .unfitted: nil
            }
        }

        /// As an event says it. No text, which is the person's words.
        public var description: String {
            switch self {
            case .fitted(let fitted): "\(fitted)"
            case .unfitted(let reason): "unfitted, because \(reason)"
            }
        }
    }

    /// A commit fitted to a field that was read.
    public struct Fitted: Equatable, Sendable, CustomStringConvertible {
        let replaced: Int
        let before: Before
        let rules: Set<Fitting.Rule>

        public var description: String {
            let fitted = rules.isEmpty ? "fitted, unchanged"
                : "fitted: \(Fitting.Rule.allCases.filter(rules.contains).map(\.description).joined(separator: ", "))"
            return "\(fitted); \(before)"
        }
    }

    /// Where the text the words were fitted after came from. Ranges and counts, never text.
    public enum Before: Equatable, Sendable, CustomStringConvertible {
        /// No run of the input method's words ends where these go.
        case field
        /// The run ends where these go, over its range, and the field shows each of its units as
        /// the run wrote it or blank, `blanks` of them blank where the run wrote otherwise: the run
        /// stands there.
        case run(NSRange, blanks: Int)
        /// The run ends where these go, over its range, and the field shows other text in it: the
        /// field's text stands.
        case fieldOverRun(NSRange)

        public var description: String {
            switch self {
            case .field: "the text before it from the field"
            case let .run(range, blanks):
                "the text before it from the input method's run, its \(range.length) units at \(range), \(blanks) of them read blank"
            case .fieldOverRun(let range):
                "the text before it from the field, which reads other text over the input method's run, its \(range.length) units at \(range)"
            }
        }
    }

    /// The words the input method put before a caret, over as many of its commits as followed one
    /// another there, ending at the caret they left: the last `FieldReading.bound` units of them,
    /// as many as a read reaches back. Never empty: commits that left nothing leave no run.
    public struct Run: Equatable, Sendable {
        let words: String
        /// The caret they left, in UTF-16 units.
        let end: Int

        init?(_ words: String, endingAt end: Int) {
            guard !words.isEmpty else { return nil }
            var (start, excess) = (words.startIndex, words.utf16.count - FieldReading.bound)
            while excess > 0 {
                excess -= words[start].utf16.count
                start = words.index(after: start)
            }
            (self.words, self.end) = (String(words[start...]), end)
        }

        var range: NSRange { NSRange(location: end - words.utf16.count, length: words.utf16.count) }
    }

    /// Why a take-back is not committed: the field could not be read, or the words are not there.
    enum Untaken: Error, Equatable, CustomStringConvertible {
        case unreadable(Unreadable)
        case unfound(Replacement.Unfound)

        var description: String {
            switch self {
            case .unreadable(let reason): "the field could not be read, because \(reason)"
            case .unfound(let unfound): "\(unfound)"
            }
        }
    }

    /// What a request asks for: words at the selection, or words in place of the ones it names.
    /// [LAW:parse-dont-validate] `InsertRequest` carries a take-back as a nonempty `replacing`, and
    /// this is the one place that is asked.
    private enum Act {
        case dictation
        case takingBack(String)

        init(_ request: InsertRequest) { self = request.replacing.isEmpty ? .dictation : .takingBack(request.replacing) }
    }

    /// Where a commit's words go in a field that was read: the text either side, where they start
    /// and the range the client is sent, and where the text before came from.
    private struct Place {
        let before: String
        let after: String
        let location: Int
        let range: NSRange
        let replaced: Int
        let source: Before
        /// The run's words these continue, or none.
        let continuing: String
    }

    /// `request` against `reading`, after `run`, the input method's last words in this client. A
    /// dictation goes in at the selection, fitted to the text either side of it. A take-back goes
    /// in at the words it names, which must be immediately before the caret, and what it leaves
    /// there is fitted to the text either side of those words. A field that cannot be read takes a
    /// dictation as the engine wrote it, and refuses a take-back.
    ///
    /// [LAW:dataflow-not-control-flow] Both are the same commit over a different place: the
    /// client's own selection, or the words to take back standing as one.
    static func decide(_ request: InsertRequest, against reading: FieldReading, after run: Run?) -> Result<Commit, Untaken> {
        switch (Act(request), reading) {
        case (.dictation, .unreadable(let reason)):
            .success(Commit(text: request.text, replacementRange: NSRange(location: NSNotFound, length: 0), placement: .unfitted(reason), run: nil))
        case (.takingBack, .unreadable(let reason)):
            .failure(.unreadable(reason))
        case (.dictation, .readable(let context)):
            .success(fitted(request.text, at: dictating(at: context, after: run)))
        case (.takingBack(let words), .readable(let context)):
            takingBack(words, from: context).map { fitted(request.text, at: $0) }
        }
    }

    private static func fitted(_ transcript: String, at place: Place) -> Commit {
        let fitting = Fitting.fit(transcript, between: place.before, and: place.after)
        return Commit(text: fitting.text, replacementRange: place.range,
                      placement: .fitted(Fitted(replaced: place.replaced, before: place.source, rules: fitting.rules)),
                      run: Run(place.continuing + fitting.text, endingAt: place.location + fitting.text.utf16.count))
    }

    /// A dictation's place: the selection, after the field's text, or after `run` where it ends
    /// there and the field shows each of its units as the run wrote it or blank. iTerm2 answers
    /// its screen, which is blank where the words just went until the program in it echoes them
    /// (`screenTextInNSRange:`, `PTYTextView.m`), and the words the input method put there are
    /// the authority on what they are. Text the field shows there that is neither is not theirs -
    /// an edit over them, or another field with its caret at the same place - and the field
    /// decides.
    private static func dictating(at context: DocumentContext, after run: Run?) -> Place {
        let standing = standing(run, at: context)
        return Place(before: standing.before, after: context.after, location: context.selection.location,
                     range: NSRange(location: NSNotFound, length: 0), replaced: context.selected.count, source: standing.source,
                     continuing: standing.continuing)
    }

    /// The text that stands before the selection, where it came from, and the run's words it is
    /// continued from.
    private static func standing(_ run: Run?, at context: DocumentContext) -> (before: String, source: Before, continuing: String) {
        guard let run, run.end == context.selection.location else { return (context.before, .field, "") }
        let (shown, written) = (Array(context.before.utf16.suffix(run.words.utf16.count)), Array(run.words.utf16))
        guard shown.count == written.count, zip(shown, written).allSatisfy({ $0 == $1 || $0 == blank }) else {
            return (context.before, .fieldOverRun(run.range), "")
        }
        let blanks = zip(shown, written).count { $0 != $1 }
        return (context.before.droppingLast(units: written.count) + run.words, .run(run.range, blanks: blanks), run.words)
    }

    private static let blank = UTF16.CodeUnit(UInt8(ascii: " "))

    /// A take-back's place: the words it names, standing as the selection. Proved against the field
    /// alone, never a run: iTerm2 turns a replacement range into one delete per character, so only
    /// words the field says are there may be taken back.
    private static func takingBack(_ words: String, from context: DocumentContext) -> Result<Place, Untaken> {
        Replacement.range(of: words, caret: context.selection, before: context.before).mapError(Untaken.unfound).map { range in
            Place(before: context.before.droppingLast(units: range.length), after: context.after, location: range.location, range: range,
                  replaced: words.count, source: .field, continuing: "")
        }
    }
}

private nonisolated extension String {
    /// The text without the last `units` UTF-16 units: what stands before the words that end it.
    func droppingLast(units: Int) -> String { String(decoding: utf16.dropLast(units), as: UTF16.self) }
}
