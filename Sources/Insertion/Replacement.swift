import Foundation
import GrammaticalNumber

/// Where a commit that takes back words puts its replacement range, and the proof that the words
/// are still there to take.
///
/// A client is asked nothing it cannot answer for itself: the words a cancelled dictation put at
/// the caret are read back from the document before they are replaced, so a caret the person has
/// since moved, or a field they have since typed in, changes nothing. [LAW:parse-dont-validate]
/// The one place the question is asked; a range comes out, or the reason there is none.
///
/// [LAW:effects-at-boundaries] Pure over one reading of the client, which the input method makes
/// and anything standing in for a client supplies from a string. [LAW:one-source-of-truth]
public enum Replacement {
    /// Why a request to take words back is refused, in the words the log says.
    public enum Unfound: Error, Equatable, CustomStringConvertible {
        /// Text is selected, so the caret is not where the words ended.
        case textIsSelected(length: Int)
        /// Fewer characters precede the caret than the words are long.
        case fewerBefore(caret: Int, needed: Int)
        /// What precedes the caret is not the words.
        case differs

        public var description: String {
            switch self {
            case .textIsSelected(let length): "\(counted(length, "character is", "characters are")) selected, so the caret is not where the words ended"
            case let .fewerBefore(caret, needed): "only \(counted(caret, "character precedes", "characters precede")) the caret, and the words are \(needed) long"
            case .differs: "what precedes the caret is not the words"
            }
        }
    }

    /// The range `replacing` occupies immediately before `caret`, read off `before`, the text the
    /// client said ends there: at least as long as `replacing`, or all of it from the field's
    /// start. Lengths are UTF-16 units, which is what `NSRange` counts; `String.count` is
    /// characters and would be short by every emoji and combining mark.
    public static func range(of replacing: String, caret: NSRange, before: String) -> Result<NSRange, Unfound> {
        let needed = replacing.utf16.count
        guard caret.length == 0 else { return .failure(.textIsSelected(length: caret.length)) }
        guard before.utf16.count >= needed else { return .failure(.fewerBefore(caret: caret.location, needed: needed)) }
        return before.utf16.suffix(needed).elementsEqual(replacing.utf16)
            ? .success(NSRange(location: caret.location - needed, length: needed)) : .failure(.differs)
    }
}
