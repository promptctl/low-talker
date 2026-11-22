import Foundation
import Insertion

/// One commit decided against the field: the words as they go in, the range they go in at, and
/// what reading the field gave them.
///
/// [LAW:effects-at-boundaries] Pure over one reading of the field and the cursor's last commit.
/// `Client` reads the field, keeps its last commit, and makes the `insertText` this decides.
public nonisolated struct Commit: Equatable, Sendable {
    public let text: String
    /// NSNotFound for a dictation: at the client's selection, which the client replaces by its own
    /// rule, a client without document access included. For a take-back, the range the words to
    /// take back were proved to fill, which only a client that was read is sent.
    let replacementRange: NSRange
    public let field: Field

    /// What reading the field gave a commit: where its words went and how they were fitted, or why
    /// the field could not be read, when they go in as the engine wrote them.
    ///
    /// [LAW:types-are-the-program] One fact, so one value: a commit fitted to a field that was not
    /// read, or with no place in a field that was, cannot be made.
    public enum Field: Equatable, Sendable, CustomStringConvertible {
        case read(Read)
        case unreadable(Unreadable)

        /// The characters the words take the place of, where the field was read: the selection,
        /// or the words a take-back names.
        public var replaced: Int? {
            switch self {
            case .read(let read): read.replaced
            case .unreadable: nil
            }
        }

        /// As an event says it. No text, which is the person's words.
        public var description: String {
            switch self {
            case .read(let read): "\(read)"
            case .unreadable(let reason): "unfitted, because \(reason)"
            }
        }
    }

    /// A commit into a field that was read.
    public struct Read: Equatable, Sendable, CustomStringConvertible {
        /// Where the words go: at the selection the read found, or the words a take-back proved,
        /// as many UTF-16 units as the commit's text.
        let filled: NSRange
        let replaced: Int
        let before: Before
        let rules: Set<Fitting.Rule>

        public var description: String {
            let fitted = rules.isEmpty ? "fitted, unchanged"
                : "fitted: \(Fitting.Rule.allCases.filter(rules.contains).map(\.description).joined(separator: ", "))"
            return "\(fitted); \(before)"
        }
    }

    /// Where the text before the words was taken from: the field, or the cursor's last commit,
    /// standing over the range it filled. Ranges and lengths, never text.
    public enum Before: Equatable, Sendable, CustomStringConvertible {
        case field
        case lastCommit(NSRange)

        public var description: String {
            switch self {
            case .field: "the text before it from the field"
            case .lastCommit(let filled): "the text before it from the last commit, its \(filled.length) units at \(filled)"
            }
        }
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

    /// The caret this commit leaves, where the field kept every word: right after them.
    var caret: NSRange? {
        switch field {
        case .read(let read): NSRange(location: NSMaxRange(read.filled), length: 0)
        case .unreadable: nil
        }
    }

    /// `request` against `reading`, after `last`, the cursor's last commit. A dictation goes in at
    /// the selection, fitted to the text either side of it. A take-back goes in at the words it
    /// names, which must be immediately before the caret, and what it leaves there is fitted to the
    /// text either side of those words. A field that cannot be read takes a dictation as the
    /// engine wrote it, and refuses a take-back.
    ///
    /// [LAW:dataflow-not-control-flow] Both are the same commit over a different place: the
    /// client's own selection, or the words to take back standing as one.
    static func decide(_ request: InsertRequest, against reading: FieldReading, after last: Commit?) -> Result<Commit, Untaken> {
        switch reading {
        case .unreadable(let reason) where request.replacing.isEmpty:
            return .success(Commit(text: request.text, replacementRange: NSRange(location: NSNotFound, length: 0), field: .unreadable(reason)))
        case .unreadable(let reason):
            return .failure(.unreadable(reason))
        case .readable(let context):
            let place: Result<(around: DocumentContext, range: NSRange, before: Before), Untaken> = if request.replacing.isEmpty {
                .success(continuing(last, at: context))
            } else {
                takingBack(request.replacing, from: context)
            }
            return place.map { around, range, before in
                let fitting = Fitting.fit(request.text, to: around)
                let filled = NSRange(location: around.selection.location, length: fitting.text.utf16.count)
                return Commit(text: fitting.text, replacementRange: range,
                              field: .read(Read(filled: filled, replaced: around.selected.count, before: before, rules: fitting.rules)))
            }
        }
    }

    /// The field read for a dictation, with `last`'s text standing as the end of the text before
    /// the caret while the caret is the one `last` left: iTerm2 answers its screen, which shows
    /// blanks where the words just went (`screenTextInNSRange:`, `PTYTextView.m`), and the words
    /// the input method put there are the authority on what they are. Anywhere else the field
    /// decides: a caret moved, by the person or by the client, is the field's to say.
    private static func continuing(_ last: Commit?, at context: DocumentContext) -> (around: DocumentContext, range: NSRange, before: Before) {
        let atTheField = NSRange(location: NSNotFound, length: 0)
        guard let last, case .read(let read) = last.field, context.selection == last.caret else { return (context, atTheField, .field) }
        let before = String(decoding: context.before.utf16.dropLast(read.filled.length), as: UTF16.self) + last.text
        return (DocumentContext(selection: context.selection, selected: context.selected, before: before, after: context.after), atTheField,
                .lastCommit(read.filled))
    }

    /// The field read as though `replacing` were its selection, and that selection's range. Proved
    /// against the field alone, never a last commit: iTerm2 turns a replacement range into one
    /// delete per character, so only words the field says are there may be taken back.
    private static func takingBack(_ replacing: String, from context: DocumentContext)
        -> Result<(around: DocumentContext, range: NSRange, before: Before), Untaken> {
        Replacement.range(of: replacing, caret: context.selection, before: context.before).mapError(Untaken.unfound).map { range in
            let before = String(decoding: context.before.utf16.dropLast(range.length), as: UTF16.self)
            return (DocumentContext(selection: range, selected: replacing, before: before, after: context.after), range, .field)
        }
    }
}
