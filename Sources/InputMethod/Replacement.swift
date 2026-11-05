import Foundation

/// Where a commit that takes back words puts its replacement range, and the proof that the words
/// are still there to take.
///
/// A client is asked nothing it cannot answer for itself: the words a cancelled dictation put at
/// the caret are read back from the document before they are replaced, so a caret the person has
/// since moved, a field they have since typed in, or a client that reports no document at all
/// changes nothing. [LAW:parse-dont-validate] The one place the question is asked; a range comes
/// out, or the reason there is none.
///
/// [LAW:effects-at-boundaries] Pure over two readings of the client, which `Client` makes and a
/// test supplies from a string, so IMK rule 6's tests against a model of the field need no
/// `IMKTextInput`.
nonisolated enum Replacement {
    /// Why a request to take words back is refused, in the words the log says.
    enum Unfound: Error, Equatable, CustomStringConvertible {
        /// The client reports no selection, which is how a terminal answers.
        case noSelection
        /// Text is selected, so the caret is not where the words ended.
        case textIsSelected(length: Int)
        /// Fewer characters precede the caret than the words are long.
        case fewerBefore(caret: Int, needed: Int)
        /// The client would not say what precedes the caret.
        case unreadable
        /// What precedes the caret is not the words.
        case differs

        var description: String {
            switch self {
            case .noSelection: "the client reports no selection"
            case .textIsSelected(let length): "\(length) characters are selected, so the caret is not where the words ended"
            case let .fewerBefore(caret, needed): "only \(caret) characters precede the caret, and the words are \(needed) long"
            case .unreadable: "the client would not say what precedes the caret"
            case .differs: "what precedes the caret is not the words"
            }
        }
    }

    /// The range `replacing` occupies immediately before the caret, or `NSNotFound` at the
    /// insertion point when there is nothing to replace, so an ordinary insert asks the client
    /// nothing. Lengths are UTF-16 units, which is what `NSRange` counts; `String.count` is
    /// characters and would be short by every emoji and combining mark.
    ///
    /// `selection` and `text` are called only when there is something to replace.
    static func range(of replacing: String, selection: () -> NSRange, text: (NSRange) -> String?) -> Result<NSRange, Unfound> {
        let needed = replacing.utf16.count
        guard needed > 0 else { return .success(NSRange(location: NSNotFound, length: 0)) }
        let caret = selection()
        guard caret.location != NSNotFound else { return .failure(.noSelection) }
        guard caret.length == 0 else { return .failure(.textIsSelected(length: caret.length)) }
        guard caret.location >= needed else { return .failure(.fewerBefore(caret: caret.location, needed: needed)) }
        let range = NSRange(location: caret.location - needed, length: needed)
        guard let before = text(range) else { return .failure(.unreadable) }
        return before.utf16.elementsEqual(replacing.utf16) ? .success(range) : .failure(.differs)
    }
}
