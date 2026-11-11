import Foundation
import InputMethod
import Testing

/// How the client in front of a field answers the input method: one row of what each app's text
/// client was measured answering over `IMKTextInput` on studious (low-voice-edit-1jf.bem,
/// cmt-8694d7d2), named after the row.
///
/// One type and its rows as values: two rows the port cannot tell apart today are still two rows,
/// because they part ways once the port reads more of the field than it does now.
/// [LAW:one-type-per-behavior]
public nonisolated struct ClientProfile: Sendable, Equatable, CustomStringConvertible {
    /// What the client gives the input method of the field behind it.
    public enum Access: Sendable {
        /// No document access: `selectedRange` answers NSNotFound and the text nil whatever the
        /// field holds, and a replacement range is ignored, the words going in at the cursor.
        case none
        /// Document access and a real selection, and no text over any range.
        case selectionOnly
        /// Document access, and the reads answer what the field holds.
        case toTheField
    }

    /// What the field does with words that do not fit its `maxlength`, where someone said; nil where
    /// nobody did, and the fake fails the case that overflows it rather than guess.
    public enum Overflow: Sendable {
        /// It keeps what fits.
        case keepsWhatFits
        /// It keeps them all, as though it had no `maxlength`.
        case keepsThemAll
        /// It keeps none of them, and the field is left as it was.
        case keepsNone
        /// It keeps what fits, and its reads answer as though it had kept them all.
        case keepsWhatFitsAnsweringAll
    }

    public let description: String
    public let access: Access
    public let overflow: Overflow?

    init(_ description: String, access: Access, overflow: Overflow? = nil) {
        self.description = description
        self.access = access
        self.overflow = overflow
    }

    /// TextEdit and Notes: the full tier.
    public static let appKit = ClientProfile("an AppKit text view", access: .toTheField)
    /// Safari's and Chrome's `<textarea>` and contenteditable: the partial tier. Its `length()` of 0
    /// is not a call the port makes, so it is not modelled.
    public static let webKitTextArea = ClientProfile("a WebKit <textarea>", access: .toTheField)
    /// Safari's and Chrome's `<input>`, measured as `<input maxlength=10>`: the none tier, before and
    /// after an insert. What it keeps of words past its `maxlength` is unmeasured, and the profiles
    /// in `possible` give each answer.
    public static let webKitInput = ClientProfile("a WebKit <input>", access: .none)
    /// A window with no text field focused, which still hands the input method a client: Calculator,
    /// Installer, Activity Monitor with every window closed, a page whose body text was clicked
    /// (low-reliability-z2z.sk9).
    public static let noTextField = ClientProfile("a window with no text field focused", access: .none)

    /// The rows bem and sk9 measured alike.
    public static let measured: [ClientProfile] = [appKit, webKitTextArea, webKitInput, noTextField]

    // Each answer a client nobody measured could give, as a profile of its own.

    /// A WebKit `<input>` handed more than its `maxlength`, if it keeps what fits.
    public static let webKitInputKeepingWhatFits = ClientProfile("a WebKit <input> keeping what fits", access: .none, overflow: .keepsWhatFits)
    /// If it keeps it all.
    public static let webKitInputKeepingAll = ClientProfile("a WebKit <input> keeping all it is handed", access: .none, overflow: .keepsThemAll)
    /// If it keeps none of it.
    public static let webKitInputKeepingNone = ClientProfile("a WebKit <input> keeping none of what overflows it", access: .none, overflow: .keepsNone)
    /// A WebKit `<textarea>` with a `maxlength` (low-reliability-z2z.rgy), if it keeps what fits.
    public static let webKitLimitedTextArea = ClientProfile("a WebKit <textarea maxlength> keeping what fits", access: .toTheField,
                                                                   overflow: .keepsWhatFits)
    /// If it keeps it all.
    public static let webKitLimitedTextAreaKeepingAll = ClientProfile("a WebKit <textarea maxlength> keeping all it is handed", access: .toTheField,
                                                                      overflow: .keepsThemAll)
    /// If it keeps none of it.
    public static let webKitLimitedTextAreaKeepingNone = ClientProfile("a WebKit <textarea maxlength> keeping none of what overflows it",
                                                                       access: .toTheField, overflow: .keepsNone)
    /// If its `maxlength` takes its document access away, as the `<input>`'s is measured without.
    public static let webKitLimitedTextAreaBlind = ClientProfile("a WebKit <textarea maxlength> giving no document access", access: .none,
                                                                       overflow: .keepsWhatFits)
    /// If its reads answer what it was handed rather than what it kept.
    public static let webKitLimitedTextAreaAnsweringAll = ClientProfile("a WebKit <textarea maxlength> answering all it was handed",
                                                                        access: .toTheField, overflow: .keepsWhatFitsAnsweringAll)
    /// iTerm2's terminal, where words land in plain sight, as bem read it: no document access.
    /// Its `length()` of 0 (Committer) is not a call the port makes, so it is not modelled.
    public static let iTerm2Blind = ClientProfile("iTerm2's terminal giving no document access", access: .none)
    /// As sk9 read it, document access and a real selection, if it says no text is in a range.
    public static let iTerm2SelectionOnly = ClientProfile("iTerm2's terminal giving a selection and no text", access: .selectionOnly)
    /// As sk9 read it, if it says what is in a range.
    public static let iTerm2 = ClientProfile("iTerm2's terminal reading as the field", access: .toTheField)

    /// Every answer nobody measured, so a behavior run under all of them holds whichever the
    /// client gives.
    public static let possible: [ClientProfile] = [
        webKitInputKeepingWhatFits, webKitInputKeepingAll, webKitInputKeepingNone,
        webKitLimitedTextArea, webKitLimitedTextAreaKeepingAll, webKitLimitedTextAreaKeepingNone, webKitLimitedTextAreaBlind,
        webKitLimitedTextAreaAnsweringAll,
        iTerm2Blind, iTerm2SelectionOnly, iTerm2,
    ]

    /// Every profile, measured and possible: what a behavior that depends on a client's answers
    /// runs under.
    public static let all = measured + possible
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
    /// What an overflow dropped that the client still answers as there, just after the caret, or nil.
    /// The field and its reads part here and nowhere else; nobody said what such a client does with
    /// a later selection or insert, so the fake fails the case that makes one.
    private var unkept: String?
    /// The most UTF-16 units the field holds, as an HTML `maxlength` counts them. What an insert past
    /// it keeps is the profile's `overflow`.
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
    public func select(_ range: NSRange) {
        guard unkept == nil else { return answeredAfterUnkept("select(\(range))") }
        selection = range
    }

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
        case .selectionOnly, .toTheField: answered.selection
        }
    }

    public func string(in range: NSRange) -> String? {
        switch profile.access {
        case .none, .selectionOnly: nil
        case .toTheField: Self.holds(range, in: answered.field) ? (answered.field as NSString).substring(with: range) : nil
        }
    }

    /// The field and selection the client's reads answer: what it holds, with any unkept words put
    /// back at the caret and the caret after them.
    private var answered: (field: String, selection: NSRange) {
        guard let unkept else { return (text, selection) }
        return ((text as NSString).replacingCharacters(in: selection, with: unkept),
                NSRange(location: selection.location + unkept.utf16.count, length: 0))
    }

    /// Whether `range` lies within `field`, asked without `NSMaxRange`, which overflows on a
    /// location of NSNotFound.
    private static func holds(_ range: NSRange, in field: String) -> Bool {
        range.location >= 0 && range.location <= field.utf16.count && range.length <= field.utf16.count - range.location
    }

    private func answeredAfterUnkept(_ call: String) {
        Issue.record("\(call) on \(profile) after it answered words it did not keep, and nobody said what it does then")
    }

    /// As the measured clients take it: at NSNotFound the words replace the selection, an explicit
    /// range is honoured only with document access, and the field keeps of what its `maxLength` has
    /// no room for what the profile's overflow says, leaving the caret after what it kept.
    public func insertText(_ words: String, replacementRange range: NSRange) {
        duringInsert()
        guard unkept == nil else { return answeredAfterUnkept("insertText(\(words.debugDescription), \(range))") }
        let replaced = range.location == NSNotFound || profile.access == .none ? selection : range
        // No selection-only client was measured taking an explicit range, so the fake answers none.
        guard range.location == NSNotFound || profile.access != .selectionOnly else {
            Issue.record("insertText into \(profile) was given \(range), and nobody measured a selection-only client taking one")
            return
        }
        // No client was measured answering a range past the end of its field, so the fake answers
        // none: it fails the case that handed it one, naming the range, rather than guess.
        guard Self.holds(replaced, in: text) else {
            Issue.record("insertText into \(profile) holding \(text.utf16.count) units was given \(replaced), past the field")
            return
        }
        let room = maxLength.map { $0 - (text.utf16.count - replaced.length) } ?? .max
        let kept: String
        var dropped: String?
        if words.utf16.count <= room {
            kept = words
        } else {
            switch profile.overflow {
            case .keepsWhatFits: kept = Self.prefix(of: words, fitting: room)
            case .keepsThemAll: kept = words
            case .keepsNone: return
            case .keepsWhatFitsAnsweringAll:
                kept = Self.prefix(of: words, fitting: room)
                dropped = String(words.dropFirst(kept.count))
            case nil:
                Issue.record("insertText into \(profile) overflowed its maxlength, and nobody said what it keeps")
                return
            }
        }
        text = (text as NSString).replacingCharacters(in: replaced, with: kept)
        selection = NSRange(location: replaced.location + kept.utf16.count, length: 0)
        unkept = dropped
    }

    /// The most whole characters of `words` that fit in `room` UTF-16 units.
    private static func prefix(of words: String, fitting room: Int) -> String {
        var left = room
        return String(words.prefix { character in
            left -= character.utf16.count
            return left >= 0
        })
    }
}
