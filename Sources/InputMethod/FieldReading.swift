import Foundation

/// What a client says of the text around its selection, or its own reason that it cannot be read.
///
/// [LAW:parse-dont-validate] `read(from:)` is the one place a client's answers about its field's
/// text are checked. Past it, a `DocumentContext` is text the client said is there, at the place
/// its own selection puts it, and nothing downstream asks again.
public nonisolated enum FieldReading: Equatable, Sendable {
    case readable(DocumentContext)
    case unreadable(Unreadable)

    /// The most UTF-16 units read on each side of the selection. One read costs about the same
    /// whatever its range (~120-280 µs, low-voice-edit-1jf.bem), and this covers a paragraph each
    /// way, which is what fitting and spoken edits look at.
    public static let bound = 1_000
}

/// The selection and the text either side of it, in the client's own coordinates. Named as
/// UITextDocumentProxy names the same view of a field: the document context before and after the
/// input, and the selected text.
public nonisolated struct DocumentContext: Equatable, Sendable {
    /// In UTF-16 units, as `NSRange` counts them; a caret is a selection of length 0.
    public let selection: NSRange
    public let selected: String
    /// The text ending where the selection starts: `FieldReading.bound` units, or fewer only at
    /// the field's start.
    public let before: String
    /// The text starting where the selection ends: `FieldReading.bound` units, or fewer only at
    /// the field's end.
    public let after: String
}

/// Why a client cannot be read, in its own answers. Ranges and counts only: no text.
public nonisolated enum Unreadable: Error, Equatable, Sendable, CustomStringConvertible {
    /// It gives no document access.
    case noDocumentAccess
    /// It gives document access, and its `selectedRange` answered NSNotFound.
    case selectionNotFound
    /// Its answers disagree with each other: a range its own selection puts in the field answered
    /// nothing, or text of another length (`answered` units). A selection no field could hold is
    /// itself the range asked.
    case contradicted(asked: NSRange, answered: Int?)

    public var description: String {
        switch self {
        case .noDocumentAccess: "it gives no document access"
        case .selectionNotFound: "its selection is NSNotFound"
        case let .contradicted(asked, answered):
            "it answered \(answered.map { "\($0) units" } ?? "nothing") for \(asked), which its selection puts in the field"
        }
    }
}

public extension FieldReading {
    /// What a read says in the log: the reading without its text, and how many times the client
    /// was asked for text, which past the field's end can take a search. [LAW:nothing-unseen]
    nonisolated enum Event: Equatable, Sendable, CustomStringConvertible {
        case readable(selection: NSRange, before: Int, after: Int, asks: Int)
        case unreadable(Unreadable, asks: Int)

        public var description: String {
            switch self {
            case let .readable(selection, before, after, asks):
                "readable: selection \(selection), \(before) units before it and \(after) after, in \(asks) asks for text"
            case let .unreadable(reason, asks): "unreadable, after \(asks) asks for text: \(reason)"
            }
        }
    }

    /// Reads `client`: whether it gives document access, its selection, then the text of the
    /// selection, before it and after it.
    ///
    /// Never sized off the client's `length()`, which the partial tier answers 0 (bem). Before
    /// and the selection lie where the client's own selection says text is, so each must answer
    /// in full. After runs to `bound`, which can be past the field's end, and what a client answers
    /// there nobody measured: the text that is there is taken as it comes, and nothing at all is
    /// followed by a search for the longest range that answers, which is the text up to the end.
    ///
    /// An empty range is "" and is never asked: its text is empty by definition, and what a
    /// client answers for one nobody measured.
    @MainActor
    static func read(from client: any TextInputClient) -> (reading: FieldReading, event: Event) {
        var asks = 0
        func text(_ range: NSRange) -> String? {
            guard range.length > 0 else { return "" }
            asks += 1
            return client.string(in: range)
        }
        func exactly(_ range: NSRange) -> Result<String, Unreadable> {
            let answer = text(range)
            guard let answer, answer.utf16.count == range.length else {
                return .failure(.contradicted(asked: range, answered: answer?.utf16.count))
            }
            return .success(answer)
        }
        func after(_ end: Int) -> Result<String, Unreadable> {
            let whole = NSRange(location: end, length: bound)
            if let answer = text(whole) {
                return answer.utf16.count <= bound ? .success(answer) : .failure(.contradicted(asked: whole, answered: answer.utf16.count))
            }
            // Binary search: `known` answers in full, and a range `past` units long answers nothing.
            var known = "", past = bound
            while past - known.utf16.count > 1 {
                let probe = NSRange(location: end, length: (known.utf16.count + past) / 2)
                switch text(probe) {
                case nil: past = probe.length
                case let answer? where answer.utf16.count == probe.length: known = answer
                case let answer?: return .failure(.contradicted(asked: probe, answered: answer.utf16.count))
                }
            }
            return .success(known)
        }
        func context() -> Result<DocumentContext, Unreadable> {
            guard client.givesDocumentAccess() else { return .failure(.noDocumentAccess) }
            let selection = client.selectedRange()
            guard selection.location != NSNotFound, selection.length != NSNotFound else { return .failure(.selectionNotFound) }
            let (end, overflowed) = selection.location.addingReportingOverflow(selection.length)
            guard selection.location >= 0, selection.length >= 0, !overflowed else {
                return .failure(.contradicted(asked: selection, answered: nil))
            }
            let start = max(0, selection.location - bound)
            return exactly(selection).flatMap { selected in
                exactly(NSRange(location: start, length: selection.location - start)).flatMap { before in
                    after(end).map { DocumentContext(selection: selection, selected: selected, before: before, after: $0) }
                }
            }
        }
        return switch context() {
        case let .success(context):
            (.readable(context), .readable(selection: context.selection, before: context.before.utf16.count,
                                           after: context.after.utf16.count, asks: asks))
        case let .failure(reason): (.unreadable(reason), .unreadable(reason, asks: asks))
        }
    }
}
