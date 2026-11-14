import Foundation
import Insertion

/// One commit decided against the field: the words as they go in, the range they go in at, what
/// fitting did to them, and how many characters they take the place of: the selection, or the
/// words a take-back names.
///
/// [LAW:effects-at-boundaries] Pure over one reading of the field. `Client` reads the field and
/// makes the `insertText` this decides.
public nonisolated struct Commit: Equatable, Sendable {
    public let text: String
    /// NSNotFound for a dictation: at the client's selection, which the client replaces by its own
    /// rule, a client without document access included. For a take-back, the range the words to
    /// take back were proved to fill, which only a client that was read is sent.
    let replacementRange: NSRange
    public let fitting: Fitting.Outcome
    /// Nil where the field could not be read, and nothing says what was selected.
    public let replaced: Int?

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

    /// `request` against `reading`. A dictation goes in at the selection, fitted to the text either
    /// side of it. A take-back goes in at the words it names, which must be immediately before the
    /// caret, and what it leaves there is fitted to the text either side of those words.
    ///
    /// [LAW:dataflow-not-control-flow] Both are the same commit over a different selection: the
    /// client's own, or the words to take back standing as one.
    static func decide(_ request: InsertRequest, against reading: FieldReading) -> Result<Commit, Untaken> {
        let place: Result<(around: FieldReading, range: NSRange), Untaken> = if request.replacing.isEmpty {
            .success((reading, NSRange(location: NSNotFound, length: 0)))
        } else {
            takingBack(request.replacing, from: reading)
        }
        return place.map { around, range in
            let fitting = Fitting.fit(request.text, to: around)
            return Commit(text: fitting.text, replacementRange: range, fitting: fitting.outcome, replaced: around.selected?.count)
        }
    }

    /// The field read as though `replacing` were its selection, and that selection's range.
    private static func takingBack(_ replacing: String, from reading: FieldReading) -> Result<(around: FieldReading, range: NSRange), Untaken> {
        switch reading {
        case .unreadable(let reason): .failure(.unreadable(reason))
        case .readable(let context):
            Replacement.range(of: replacing, caret: context.selection, before: context.before).mapError(Untaken.unfound).map { range in
                let before = String(decoding: context.before.utf16.dropLast(range.length), as: UTF16.self)
                return (.readable(DocumentContext(selection: range, selected: replacing, before: before, after: context.after)), range)
            }
        }
    }
}

public extension FieldReading {
    /// The selected text, where the field was read.
    nonisolated var selected: String? {
        switch self {
        case .readable(let context): context.selected
        case .unreadable: nil
        }
    }
}
