import Foundation
import InputMethod

/// How the client in front of a field answers the input method: one row of what each app's text
/// client was measured answering over `IMKTextInput` on studious (low-voice-edit-1jf.bem,
/// cmt-8694d7d2), named after the row.
///
/// One type and its rows as values: two rows the port cannot tell apart today are still two rows,
/// because they part ways once the port reads more of the field than it does now.
/// [LAW:one-type-per-behavior]
public nonisolated struct ClientProfile: Sendable, CustomStringConvertible {
    /// What the client gives the input method of the field behind it.
    public enum Access: Sendable {
        /// No document access: `selectedRange` answers NSNotFound and the text nil whatever the
        /// field holds, and a replacement range is ignored, the words going in at the cursor.
        case none
        /// Document access, and the reads answer what the field holds.
        case toTheField
        /// Document access, and the reads answer an empty document - a caret at 0 and no text -
        /// before and after a commit that landed.
        case toAnEmptyDocument
    }

    public let description: String
    public let access: Access

    /// TextEdit and Notes: the full tier.
    public static let appKit = ClientProfile(description: "an AppKit text view", access: .toTheField)
    /// Safari's and Chrome's `<textarea>` and contenteditable: the partial tier. Its `length()` of 0
    /// is not a call the port makes, so it is not modelled.
    public static let webKitTextArea = ClientProfile(description: "a WebKit <textarea>", access: .toTheField)
    /// Safari's and Chrome's `<input>`, measured as `<input maxlength=10>`: the none tier, before and
    /// after an insert.
    public static let webKitInput = ClientProfile(description: "a WebKit <input>", access: .none)
    /// iTerm2's terminal, where words land in plain sight. Document access as low-reliability-z2z.sk9
    /// measured it, its words seen landing once a client without document access was refused; bem's
    /// row reads none. Its reads are unmeasured under document access, and answer an empty document
    /// here from Committer's note that it answers `length()` 0 before and after a commit. Both are
    /// contract cases for the studious run to settle (low-test-layers-sqm.8m3, cmt-b4e012ab).
    public static let iTerm2 = ClientProfile(description: "iTerm2's terminal", access: .toAnEmptyDocument)
    /// A window with no text field focused, which still hands the input method a client: Calculator,
    /// Installer, Activity Monitor with every window closed, a page whose body text was clicked
    /// (low-reliability-z2z.sk9).
    public static let noTextField = ClientProfile(description: "a window with no text field focused", access: .none)
}

/// A text field and the client in front of it, held in memory: the one fake of `TextInputClient`.
///
/// [LAW:one-source-of-truth] What the field holds is `text` and `selection`, and `insertText`
/// really changes them. What each call answers is the profile's reading of that state, never a
/// canned answer, so a field that keeps less than it was handed, or a client whose reads say
/// nothing of what is there, is seen by every suite built on this as it is.
public final class FakeTextInputClient: TextInputClient {
    public let application: String?
    /// How the client answers. Changed where the person moves focus within the client: a page whose
    /// body was clicked after its field had focus gives no document access from then on.
    public var profile: ClientProfile
    /// What the field holds, which is what a person would see in it.
    public private(set) var text: String
    /// The selection, in UTF-16 units as `NSRange` counts; a caret is a selection of length 0.
    public private(set) var selection: NSRange
    /// The most UTF-16 units the field holds, as an HTML `maxlength` counts them. An insert past it
    /// keeps what fits, and the client answers the same either way.
    public let maxLength: Int?
    /// Where the client says the caret's line is, in screen coordinates, or nil for a client that
    /// reports none.
    public var caretLine: CGRect?
    /// How many times the client was asked whether it gives document access: each ask is a call
    /// into an app that may be hung.
    public private(set) var documentAccessAsked = 0
    /// Runs inside each `insertText`, before the words go in, while the app is taking them.
    public var duringInsert: () -> Void = {}

    /// TextEdit's caret line, measured on studious: a field with its caret on the display.
    public nonisolated static let textEditLine = CGRect(x: 402, y: 565, width: 1, height: 13)

    /// A field of `application` holding `text`, with the caret at its end.
    public nonisolated init(in application: String? = "com.example.editor", _ profile: ClientProfile = .appKit, holding text: String = "",
                            maxLength: Int? = nil, caretLine: CGRect? = textEditLine) {
        self.application = application
        self.profile = profile
        self.text = text
        selection = NSRange(location: text.utf16.count, length: 0)
        self.maxLength = maxLength
        self.caretLine = caretLine
    }

    /// The person selects `range` of the field.
    public func select(_ range: NSRange) { selection = range }

    public func bundleIdentifier() -> String? { application }
    public func uniqueClientIdentifierString() -> String? { nil }

    public func givesDocumentAccess() -> Bool {
        documentAccessAsked += 1
        return profile.access != .none
    }

    public func lineHeightRectangle(forCharacterIndex _: Int) -> NSRect { caretLine ?? .zero }

    public func selectedRange() -> NSRange {
        switch profile.access {
        case .none: NSRange(location: NSNotFound, length: NSNotFound)
        case .toTheField: selection
        case .toAnEmptyDocument: NSRange(location: 0, length: 0)
        }
    }

    public func string(in range: NSRange) -> String? {
        switch profile.access {
        case .none, .toAnEmptyDocument: nil
        case .toTheField: range.location >= 0 && NSMaxRange(range) <= text.utf16.count ? (text as NSString).substring(with: range) : nil
        }
    }

    /// As the measured clients take it: at NSNotFound the words replace the selection, an explicit
    /// range is honoured only with document access, and the field keeps what its `maxLength` has
    /// room for, leaving the caret after it.
    public func insertText(_ words: String, replacementRange range: NSRange) {
        duringInsert()
        let replaced = range.location == NSNotFound || profile.access == .none ? selection : range
        var room = maxLength.map { $0 - (text.utf16.count - replaced.length) } ?? .max
        let kept = String(words.prefix { character in
            room -= character.utf16.count
            return room >= 0
        })
        text = (text as NSString).replacingCharacters(in: replaced, with: kept)
        selection = NSRange(location: replaced.location + kept.utf16.count, length: 0)
    }
}
