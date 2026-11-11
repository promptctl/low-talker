import Foundation
import Identity
import InputMethodKit
import Insertion
import os

/// The text input system's client, as this process calls it: the seven of the three dozen
/// members `IMKTextInput` offers that `Client` uses, and nothing else.
///
/// [LAW:composability] The seam where this process meets macOS, named here rather than passing
/// the text input system's own protocol around, because a type that demanded all of
/// `IMKTextInput` could only ever be handed the real one - by macOS, in a process macOS
/// launched, with a person's cursor at the far end. Everything above it, `Client`'s decisions
/// included, runs in a test over the fake that answers as the measured clients do
/// (`FakeTextInputClient`, in InputMethodFakes); the real one, `IMKClient`, passes each call
/// through and decides nothing.
///
/// On the main actor, every member: each is a call into the client, and IMK rules 3 and 4 put
/// every client call on the main actor.
public protocol TextInputClient {
    func bundleIdentifier() -> String?
    func uniqueClientIdentifierString() -> String?
    /// Whether the client gives document access, its answer to
    /// `kTSMDocumentSupportDocumentAccessPropertyTag`.
    func givesDocumentAccess() -> Bool
    /// The line rectangle at `index`, in screen coordinates, or `.zero` from a client that
    /// reports none.
    func lineHeightRectangle(forCharacterIndex index: Int) -> NSRect
    func selectedRange() -> NSRange
    /// The text the client says is in `range`, or nil where it will not say.
    func string(in range: NSRange) -> String?
    func insertText(_ text: String, replacementRange: NSRange)
}

/// The `IMKTextInput` macOS hands `activateServer`, as the port: each call passed through as it is.
struct IMKClient: TextInputClient {
    let client: IMKTextInput

    func bundleIdentifier() -> String? { client.bundleIdentifier() }
    func uniqueClientIdentifierString() -> String? { client.uniqueClientIdentifierString() }
    func givesDocumentAccess() -> Bool { client.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag)) }

    func lineHeightRectangle(forCharacterIndex index: Int) -> NSRect {
        var line = NSRect.zero
        _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &line)
        return line
    }

    func selectedRange() -> NSRange { client.selectedRange() }
    func string(in range: NSRange) -> String? { client.attributedSubstring(from: range)?.string }
    func insertText(_ text: String, replacementRange: NSRange) { client.insertText(text, replacementRange: replacementRange) }
}

/// What a client answers about the text field words committed into it would go to.
public enum FieldAnswer: Sendable, Equatable {
    /// It gives no document access: by its own word, no text field has focus in it.
    case noDocumentAccess
    /// It gives document access, and its caret's line rectangle is here, in screen
    /// coordinates, or nowhere it reported.
    case documentAccess(caretLine: CGRect?)

    /// Whether words committed into this client go into a field on one of `screens`.
    ///
    /// A caret line on no screen belongs to a field in no window a person can see: the
    /// Finder's desktop and file lists, and the Open panel's file list, give document
    /// access to a type-select buffer whose line is its own local coordinates, centered
    /// below the bottom edge of the main display (measured on studious,
    /// low-reliability-z2z.anp). Judged by the line's center, because that buffer's line
    /// reaches 1 point up onto the display. A display arranged directly below the main one's
    /// left edge contains that center, and there the buffer still takes words. A real field
    /// whose caret is scrolled past every screen's edge is refused the same way, and its
    /// words are held as for any refusal.
    ///
    /// A client that reports no line is taken: nothing it said places the caret anywhere,
    /// and the clients seen reporting none were real fields between activating and their
    /// first answer.
    func isAField(on screens: [CGRect]) -> Bool {
        switch self {
        case .noDocumentAccess: false
        case .documentAccess(caretLine: nil): true
        case .documentAccess(caretLine: let line?): screens.contains { $0.contains(CGPoint(x: line.midX, y: line.midY)) }
        }
    }
}

/// The client the text input system has given focus to, and the one thing in this process
/// that can commit text into it.
///
/// [LAW:no-shared-mutable-globals] One owner with an explicit API, and shared because it
/// has to be: `IMKServer` builds a controller per client out of the class name in the
/// bundle's `Info.plist`, so there is no constructor of ours to hand anything to. Every
/// controller reports focus here, and the insert port asks here; those are the only two
/// doors, and both are on the main actor.
///
/// Its whole state is which cursor is in front, which is a fact macOS owns and this only
/// mirrors. [FRAMING:representation] Nothing is remembered about text already inserted -
/// the client is the document, and a second copy of what it holds could only disagree.
public final class FocusedClient {
    public static let shared = FocusedClient()

    /// The cursor in front, which carries the app it belongs to.
    private var focus: Client?

    /// The text input system gave this cursor focus.
    ///
    /// Unconditional, because there is no half-cursor left for it to sort out: a client that
    /// will not name its app is refused by `Client.init`, so the rule lives at the one place
    /// a cursor comes into being rather than at every place one is handled.
    /// [LAW:parse-dont-validate] [LAW:single-enforcer]
    public func took(_ cursor: Client) { focus = cursor }

    /// The text input system took focus away from this cursor.
    public func left(_ leaving: Client) {
        // Not unconditional: focus can move by activating the new client before
        // deactivating the old, and clearing on the old one's word would then drop the
        // client that just arrived and refuse the next insert for no reason.
        focus = focus === leaving ? nil : focus
    }

    /// An app quit. Any cursor of its is gone with it, whatever the text input system did
    /// or did not say about it.
    ///
    /// The case this closes, which no comparison against the app in front can: the person
    /// dictates into TextEdit, quits it, and launches it again. TextEdit is in front, its
    /// new client has not reported focus yet, and the cursor still held is a proxy for a
    /// process that no longer exists - so the app names match, the commit goes nowhere, and
    /// the answer claims it landed. Killing the cursor when the app dies is the only moment
    /// at which that is knowable. [LAW:no-silent-failure]
    ///
    /// By name and not by process, because a process is not something the text input system
    /// hands over: it gives this one a client. So the other ordering is possible - a
    /// termination notice delayed past a relaunched app taking focus clears a cursor that is
    /// live - and it is the direction chosen, because a refusal is seen and answered while a
    /// commit into a proxy for a dead process is answered `inserted` and vanishes.
    public func applicationQuit(_ application: String) {
        focus = focus?.application == application ? nil : focus
    }

    /// What an insert sees on the main actor: the cursor words go to, provided it is in the
    /// app that is actually in front and its client is a text field, or the refusal that says
    /// why there is none, with the facts that decided it.
    ///
    /// Only the decision: the commit is `Committer`'s, made in the same main-actor turn, and
    /// what the answer claims once it is made is said there.
    ///
    /// Absence is not a mistake to guard against but the answer itself: nowhere to put
    /// words is a refusal the app reports by name, and the words go nowhere else.
    ///
    /// The app in front is compared rather than assumed, which is the part that IS
    /// establishable: focus can move to an app that never becomes a client at all, and then
    /// nothing deactivates the cursor left standing. That case was not reproduced on this
    /// Mac - every app tried presented a client - so this is held by the suite and not by a
    /// reading, and it is here because committing into a window the person has left is the
    /// one outcome worse than refusing.
    ///
    /// Which app is in front, which app holds secure input, whether this source is selected
    /// and where the screens are arrive
    /// as values rather than being read here, so the whole of this decision is testable
    /// without a window server and the one reading of the workspace happens where the other
    /// effects are. [LAW:effects-at-boundaries]
    ///
    /// First, the app in front has to be one `destination` admits: words that follow a
    /// dictation's first go only to the app those went to, so a person who moved on mid-press
    /// is refused rather than typed into, and told that they moved - whatever the app they
    /// moved to holds, which is not where the words were going anyway.
    ///
    /// Then secure input: while any app holds Secure Event Input macOS hands no input method
    /// a client, and a cursor still held from before it came on is one the text input system
    /// has stopped routing to - so no commit is attempted and the refusal names the thing to
    /// fix. [LAW:no-silent-failure]
    ///
    /// Then the input source: with another one selected the text input system hands this
    /// input method no client, so the cursor last held is one it has stopped routing to. The
    /// refusal names the Input menu, which is the fix, and not a field, which is not.
    ///
    /// Last, the cursor's client has to answer that a text field is behind it. Every app
    /// hands the input method a client, a window with no field focused included, and what is
    /// committed into such a client goes nowhere while the commit returns as if it landed.
    /// So the client's own answer is asked, once and only of the one cursor the words would
    /// go to, and the log line names that answer rather than asking again.
    /// [LAW:no-silent-failure] [LAW:one-source-of-truth]
    public func inFront(for destination: Destination, whileInFrontIs frontmost: String?, secureInputHeldBy holder: String?,
                        selected: Bool, screens: [CGRect]) -> InFront {
        func seen(_ field: FieldAnswer?, _ cursor: Result<Client, Refusal>) -> InFront {
            InFront(frontmost: frontmost, secureInputHolder: holder, selected: selected, cursorApplication: self.focus?.application,
                    field: field, screens: screens, cursor: cursor)
        }
        guard destination.admits(frontmost) else { return seen(nil, .failure(.dictationIsInAnotherApp)) }
        guard holder == nil else { return seen(nil, .failure(.secureInputIsOn)) }
        guard selected else { return seen(nil, .failure(.inputSourceIsNotSelected)) }
        guard let focus else { return seen(nil, .failure(.noTextFieldHasFocus)) }
        guard focus.application == frontmost else { return seen(nil, .failure(.cursorIsInAnotherApp)) }
        let field = focus.field
        return seen(field, field.isAField(on: screens) ? .success(focus) : .failure(.noTextFieldHasFocus))
    }
}

/// What an insert saw on the main actor: the app in front, the app holding secure input,
/// whether this source was selected, the cursor held, what its client answered about its field, and the decision made from
/// them.
///
/// The app in front is named because the refusal that matters most is the one where it is
/// not the app holding the cursor, and a line saying only the outcome leaves a reader with
/// the question it was written to answer. The cursor held and its client's answer are named
/// because they tell the three ways into a no-text-field refusal apart: no client, a client
/// giving no document access, and a caret on no screen. A taken insert names where its
/// caret was too. [LAW:no-silent-failure] [LAW:nothing-unseen]
public struct InFront: CustomStringConvertible {
    let frontmost: String?
    let secureInputHolder: String?
    let selected: Bool
    let cursorApplication: String?
    /// Asked only of the cursor the words would go to, so absent for every refusal decided
    /// before it.
    let field: FieldAnswer?
    let screens: [CGRect]
    public let cursor: Result<Client, Refusal>

    public var description: String {
        "with \(frontmost ?? "nothing") in front and "
            + (cursorApplication.map { "the cursor in \($0)" } ?? "no cursor")
            + (field.map(said) ?? "")
            + (secureInputHolder.map { ", secure input held by \($0)" } ?? "")
            + (selected ? "" : ", another input source selected")
    }

    /// A caret on no screen names the screens it was judged against, so an empty list reads
    /// as none rather than as a caret somewhere strange.
    private func said(_ field: FieldAnswer) -> String {
        switch field {
        case .noDocumentAccess: ", which gives no document access"
        case .documentAccess(caretLine: nil): ", which reports no caret"
        case .documentAccess(caretLine: let line?):
            ", its caret line at \(line)" + (field.isAField(on: screens) ? "" : ", on none of the screens \(screens)")
        }
    }
}

/// How a client is said in the log: the identifier the text input system calls it by, and its
/// app, so two windows of one app are two names.
///
/// Only said, never compared or kept as a key: whether the identifier is stable per client or
/// minted anew per read is a fact about macOS that has to be measured before anything can rely
/// on it (low-reliability-z2z.vh4). [LAW:nothing-unseen]
nonisolated struct ClientName: CustomStringConvertible {
    let identifier: String?
    let application: String

    var description: String { "client \(identifier ?? "with no identifier") of \(application)" }
}

/// A cursor: the text input system's client as somewhere words can be put, the one thing this
/// process asks of it, decided over the calls `TextInputClient` names.
///
/// `NSNotFound` as the replacement range is how the text input system is told "at the
/// insertion point, and do not take anything away" - the same commit a Japanese or Chinese
/// input method performs when the user accepts a candidate, which is why this reaches
/// terminals, browsers and Electron apps that no synthesised keystroke would.
///
/// Measured on low-input-method-s71.03j, while commits ran off the main thread: against 15,991
/// reactivations landing inside an accepted commit's round trip, one of 3,471 accepted words
/// never reached the app, a loss neither this process nor IMK could see. Every call on the
/// client now runs on the main actor, so a reactivation and a commit never overlap: the same
/// stress rerun on studious (low-imk-rules-w3g.3ky), with 11,162 reactivations landing inside
/// an accepted insert's round trip, lost, doubled and reordered no word.
///
/// On the main actor, every member, as `TextInputClient`'s are. `Committer` owns how an insert
/// reaches it.
public final class Client: CustomStringConvertible {
    private let client: any TextInputClient
    /// The app this cursor belongs to, which is how a cursor left over from an app the person
    /// has since switched away from is told from the one in front of them. The app the person
    /// is using, which for the client of an Open or Save panel is the app that put it up and not
    /// the service that draws it (`CursorApplication`).
    ///
    /// A cursor has one, always. It is read when the cursor is made, while the client is
    /// certainly alive, and never again: [FRAMING:representation] asking a client for its
    /// bundle identifier later means asking a proxy whose process may since have quit, and on
    /// the one path that must stay answerable - deciding whether to refuse - that is the last
    /// thing to reach for.
    let application: String
    /// The identifier the log says this client by, read once here and only ever said: nothing
    /// is decided from it (`ClientName`).
    private let identifier: String?

    /// Nothing at all when the client will not name its app. [LAW:parse-dont-validate] The
    /// one place the question is asked, and past it there is a cursor whose app is known
    /// rather than one every later reader has to keep asking about - which is also what
    /// makes `activateServer` able to keep the cursor it last reported: a cursor that exists
    /// is one `FocusedClient` will take.
    ///
    /// `frontmost` is the app in front now, read by the caller where the workspace is read:
    /// `CursorApplication` says when it is the app this cursor belongs to rather than the
    /// client's own name. An empty name counts as unnamed, as it would be printed by the
    /// caller as a line ending in nothing at all, and a cursor whose app cannot be compared
    /// against the one in front could never be refused for being somewhere else.
    init?(_ client: any TextInputClient, inFront frontmost: String?) {
        let named = client.bundleIdentifier()
        guard let application = CursorApplication.named(by: named, inFront: frontmost) else { return nil }
        // [LAW:nothing-unseen] Every later line names the app, and only this one says it is
        // the client of a panel that was taken for it.
        if application != named {
            Self.log.notice("\(named ?? "", privacy: .public) is the panel of \(application, privacy: .public), taken as its cursor")
        }
        self.client = client
        self.application = application
        identifier = client.uniqueClientIdentifierString()
    }

    public var description: String { ClientName(identifier: identifier, application: application).description }

    /// What the client answers about the text field behind it.
    ///
    /// Read from the client each time it is asked and never kept, because focus moves between
    /// fields and page bodies in ways the text input system does not always report.
    ///
    /// The line is asked for only once document access is given, so a client with no field
    /// costs the one call. Index 0 with no marked text asks for the current selection's line
    /// (IMKInputSession.h), so it is the insertion point's: Finder's buffer holding 19
    /// characters answered x 108. A client that reports no line leaves the rectangle
    /// untouched. [LAW:parse-dont-validate]
    var field: FieldAnswer {
        guard client.givesDocumentAccess() else { return .noDocumentAccess }
        let line = client.lineHeightRectangle(forCharacterIndex: 0)
        return .documentAccess(caretLine: line == .zero ? nil : line)
    }

    /// Commits `text` at the insertion point in place of `replacing`, the text immediately before
    /// it, which is nothing for every ordinary commit. Refuses, changing nothing, when the words
    /// to take back are not there.
    ///
    /// [LAW:no-silent-failure] A take-back that cannot be proved is refused with what was found,
    /// said in the log beside the refusal the app is told. A field that reports its caret and
    /// left it anywhere but after the words did not keep them as handed: a `maxlength`, or a
    /// field that drops what it is given.
    func commit(_ text: String, replacing: String) -> Commit {
        let range: NSRange
        do throws(Replacement.Unfound) {
            range = try Replacement.range(of: replacing, selection: { client.selectedRange() }, text: client.string(in:)).get()
        } catch {
            Self.log.notice("words could not be taken back from \(self.application, privacy: .public): \(error.description, privacy: .public)")
            return .refused(.wordsCannotBeTakenBack)
        }
        let start = range.location == NSNotFound ? client.selectedRange().location : range.location
        client.insertText(text, replacementRange: range)
        let caret = client.selectedRange().location
        guard start != NSNotFound, caret != NSNotFound else { return .handed }
        let expected = start + text.utf16.count
        return caret == expected ? .handed : .notKept(caret: caret, expected: expected)
    }

    /// What a commit did with the words.
    enum Commit: Equatable {
        /// Changed nothing, and why.
        case refused(Refusal)
        /// Handed to the client, whose caret ended after them or was not reported.
        case handed
        /// Handed to the client, whose caret ended at `caret` rather than after the words at
        /// `expected`, so the field holds something other than what it was handed.
        case notKept(caret: Int, expected: Int)
    }

    private static let log = Logger(subsystem: AppIdentity.inputMethodBundleIdentifier, category: "insert")
}
