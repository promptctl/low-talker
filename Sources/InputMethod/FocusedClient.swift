import Foundation
import InputMethodKit
import Insertion

/// Somewhere words can be put: what this process actually needs of the thing in front of
/// it, which is one thing out of the three dozen `IMKTextInput` offers.
///
/// [LAW:composability] Named here rather than passing the text input system's own protocol
/// around, because a type that demanded all of `IMKTextInput` could only ever be handed the
/// real one - by macOS, in a process macOS launched, with a person's cursor at the far end.
/// Everything below this line is then reachable without any of that.
///
/// Sendable, because the commit is made off the main thread, where a hung app cannot hold
/// the keys this source passes through. `Committer` owns where it runs and says why.
public protocol TextCursor: AnyObject, Sendable {
    /// The app this cursor belongs to, which is how a cursor left over from an app the
    /// person has since switched away from is told from the one in front of them.
    ///
    /// A cursor has one, always. It is read when the cursor is made, while the client is
    /// certainly alive, and never again: [FRAMING:representation] asking a client for its
    /// bundle identifier later means asking a proxy whose process may since have quit, and
    /// on the one path that must stay answerable - deciding whether to refuse - that is the
    /// last thing to reach for. A client that will not name one is no cursor at all, which
    /// its constructor establishes rather than leaving every reader of this to ask again.
    /// [LAW:parse-dont-validate]
    var application: String { get }
    /// Whether the client answers that it gives document access, which is the client's own
    /// statement that a text field has focus in it.
    ///
    /// Read from the client each time it is asked and never kept, because focus moves
    /// between fields and page bodies in ways the text input system does not always report.
    /// On the main actor, since it is a call on the client (IMK rule 4).
    @MainActor var givesDocumentAccess: Bool { get }
    /// Commits `text` at the insertion point, taking nothing away.
    func commit(_ text: String)
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
@MainActor
public final class FocusedClient {
    public static let shared = FocusedClient()

    /// The cursor in front, which carries the app it belongs to.
    private var focus: (any TextCursor)?

    /// The text input system gave this cursor focus.
    ///
    /// Unconditional, because there is no half-cursor left for it to sort out: a client that
    /// will not name its app is refused by `Client.init`, so the rule lives at the one place
    /// a cursor comes into being rather than at every place one is handled.
    /// [LAW:parse-dont-validate] [LAW:single-enforcer]
    public func took(_ cursor: any TextCursor) { focus = cursor }

    /// The text input system took focus away from this cursor.
    public func left(_ leaving: any TextCursor) {
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

    /// The cursor words go to, provided it is in the app that is actually in front, or the
    /// refusal that says why there is none.
    ///
    /// Only the decision: the commit is `Committer`'s, off this actor, and what the answer
    /// claims once it is made is said there.
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
    /// Which app is in front arrives as a value rather than being read here, so the whole
    /// of this decision is testable without a window server and the one reading of the
    /// workspace happens where the other effects are. [LAW:effects-at-boundaries]
    ///
    /// `secureInputIsOn` is read at the same boundary and asked first: while any app holds
    /// Secure Event Input macOS hands no input method a client, and a cursor still held from
    /// before it came on is one the text input system has stopped routing to - so no commit
    /// is attempted and the refusal names the thing to fix. [LAW:no-silent-failure]
    ///
    /// First, the app in front has to be one `destination` admits: words that follow a
    /// dictation's first go only to the app those went to, so a person who moved on mid-press
    /// is refused rather than typed into, and told that they moved - whatever the app they
    /// moved to holds, which is not where the words were going anyway.
    ///
    /// Last, the cursor has to answer that it gives document access. Every app hands the
    /// input method a client, a window with no field focused included, and what is committed
    /// into such a client goes nowhere while the commit returns as if it landed. So the
    /// client's own answer is asked, and only of the one cursor the words would go to.
    /// [LAW:no-silent-failure]
    func cursor(for destination: Destination, whileInFrontIs frontmost: String?, secureInputIsOn: Bool) -> Result<any TextCursor, Refusal> {
        guard destination.admits(frontmost) else { return .failure(.dictationIsInAnotherApp) }
        guard !secureInputIsOn else { return .failure(.secureInputIsOn) }
        guard let focus else { return .failure(.noTextFieldHasFocus) }
        guard focus.application == frontmost else { return .failure(.cursorIsInAnotherApp) }
        guard focus.givesDocumentAccess else { return .failure(.noTextFieldHasFocus) }
        return .success(focus)
    }

    /// The decision for an insert, with the facts it was made from, in one turn on this
    /// actor, so the insert's log line names what the decision saw rather than reading it
    /// again. [LAW:one-source-of-truth]
    public func inFront(for destination: Destination, whileInFrontIs frontmost: String?, secureInputHeldBy holder: String?) -> InFront {
        InFront(frontmost: frontmost, secureInputHolder: holder, cursorApplication: focus?.application,
                cursor: cursor(for: destination, whileInFrontIs: frontmost, secureInputIsOn: holder != nil))
    }
}

/// What an insert saw on the main actor: the app in front, the app holding secure input,
/// the cursor held, and the decision made from them.
///
/// The app in front is named because the refusal that matters most is the one where it is
/// not the app holding the cursor, and a line saying only the outcome leaves a reader with
/// the question it was written to answer. The cursor held is named because it is what tells
/// a no-text-field refusal with no client from one whose client in front gave no document
/// access. [LAW:no-silent-failure]
public struct InFront: Sendable, CustomStringConvertible {
    let frontmost: String?
    let secureInputHolder: String?
    let cursorApplication: String?
    public let cursor: Result<any TextCursor, Refusal>

    public var description: String {
        "with \(frontmost ?? "nothing") in front and "
            + (cursorApplication.map { "the cursor in \($0)" } ?? "no cursor")
            + (secureInputHolder.map { ", secure input held by \($0)" } ?? "")
    }
}

/// The text input system's client, as the one thing this process asks of it.
///
/// `NSNotFound` as the replacement range is how the text input system is told "at the
/// insertion point, and do not take anything away" - the same commit a Japanese or Chinese
/// input method performs when the user accepts a candidate, which is why this reaches
/// terminals, browsers and Electron apps that no synthesised keystroke would.
///
/// [LAW:no-ambient-temporal-coupling] exception: `@unchecked`, because `IMKTextInput` is a
/// proxy the language cannot see into. This type calls it three ways: the name once, on the
/// main thread, as the cursor is made; document access on the main actor, at each insert;
/// and every commit on its app's serial queue in `Committer`.
/// Measured on low-input-method-s71.c7d: committed from there, the words reach the app, in
/// order, and the main thread stays free. Measured on low-input-method-s71.03j: the main
/// thread making a new cursor over the same client, by a reactivation, at the instant a
/// commit is in flight does not crash or hang IMK. Against 15,991 reactivations landing
/// inside an accepted commit's round trip, one of 3,471 accepted words never reached the
/// app - a loss neither this process nor IMK can see, since an off-main commit returns
/// before the app has taken the words. No word arrived doubled or out of order. The
/// document-access read can land inside the previous insert's round trip the same way, and
/// whether a read loses words as a reactivation did is not measured; the overlap ends when
/// commits move onto the main actor (low-imk-rules-w3g.3ky).
///
/// That one loss in 3,471 is left unmitigated, for the reason `Committer` already gives
/// for the hung-app case: there is no moment at which this process can ask whether the
/// words landed. A read of the client after the reactivation would be exactly the "did it
/// take" check `Committer` rejected as unanswerable across apps - Finder's desktop grows a
/// buffer nobody can see while iTerm2 answers `length()` of 0 whether or not the words
/// landed - so it would tell this one loss from nothing at a rate no person dictating can
/// reach in the first place. [LAW:no-silent-failure]'s bar is a refusal by name where one
/// is knowable, not an invented signal where it is not.
final class Client: TextCursor, @unchecked Sendable {
    private let client: IMKTextInput
    let application: String

    /// Nothing at all when the client will not name its app. [LAW:parse-dont-validate] The
    /// one place the question is asked, and past it there is a cursor whose app is known
    /// rather than one every later reader has to keep asking about - which is also what
    /// makes `activateServer` able to keep the cursor it last reported: a cursor that exists
    /// is one `FocusedClient` will take.
    init?(_ client: IMKTextInput) {
        // Empty counts as unnamed: an app the answer names as "" would be printed by the
        // caller as a line ending in nothing at all, which is worse than a line naming no
        // app - and a cursor whose app cannot be compared against the one in front could
        // never be refused for being somewhere else. [LAW:parse-dont-validate]
        guard let application = client.bundleIdentifier(), !application.isEmpty else { return nil }
        self.client = client
        self.application = application
    }

    @MainActor var givesDocumentAccess: Bool {
        client.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag))
    }

    func commit(_ text: String) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}
