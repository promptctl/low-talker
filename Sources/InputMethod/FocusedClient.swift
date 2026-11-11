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

/// The clients the text input system has given focus to, and the one thing in this process
/// that can commit text into them.
///
/// [LAW:no-shared-mutable-globals] One owner with an explicit API, and shared because it
/// has to be: `IMKServer` builds a controller per client out of the class name in the
/// bundle's `Info.plist`, so there is no constructor of ours to hand anything to. Every
/// controller reports focus and typing here, and the insert port asks here; those are the only
/// doors, and all of them are on the main actor.
///
/// Its whole state is each controller's cursor, from its activation until it is deactivated or
/// ends: a fact macOS owns and this only mirrors. Usually one is live. Two windows of one app can
/// both be activated with neither deactivated: TextEdit launched with restored windows put every
/// word into the one behind the key window, because the cursor activated last was the one taken
/// (low-reliability-z2z.n8z). Nothing the client says names the key window, so activation order is
/// not taken as an answer: several live cursors refuse the words, and a key typed into one settles
/// it, since a key reaches only the controller of the client it is typed into. A cursor stays held
/// while it is not live - an activation in another app, or a key typed into another of its app,
/// ruled it out - because a key typed into it later is still proof that it has the keyboard, and
/// macOS need not activate it again first. [FRAMING:representation] Nothing is remembered about
/// text already inserted - the client is the document, and a second copy of what it holds could
/// only disagree.
public final class FocusedClient {
    public static let shared = FocusedClient(arrived: Notices.shared.cursorArrived(in:))

    /// Each controller's cursor, by the controller. Keyed by the controller rather than by the
    /// client's own identifier, because that identifier is minted anew at activation: in this Mac's
    /// log of 2026-11-10 to 11, 64 of 88 controller lives named more than one. A controller
    /// activated again replaces its own entry, and one deactivated late removes only its own.
    private var held: [ObjectIdentifier: Held] = [:]

    /// A controller's cursor, and whether it is live: one words could go to, which no activation in
    /// another app or key typed elsewhere has since ruled out.
    private struct Held {
        let cursor: Client
        let live: Bool
    }

    /// Told the app of a cursor that has become the one words go to, so words no cursor took are
    /// offered to it.
    private let arrived: (String) -> Void

    public init(arrived: @escaping (String) -> Void) { self.arrived = arrived }

    /// The text input system gave `controller`'s client focus, as `cursor`.
    ///
    /// Unconditional, because there is no half-cursor left for it to sort out: a client that
    /// will not name its app is refused by `Client.init`, so the rule lives at the one place
    /// a cursor comes into being rather than at every place one is handled.
    /// [LAW:parse-dont-validate] [LAW:single-enforcer]
    ///
    /// A cursor in another app is no longer live: focus is in one app at a time, so an activation
    /// there is the end of every live cursor here, whether or not they are ever deactivated. A
    /// cursor of the same app is no such proof, and stays live.
    public func took(_ cursor: Client, by controller: AnyObject) {
        changing {
            held = held.mapValues { Held(cursor: $0.cursor, live: $0.live && $0.cursor.application == cursor.application) }
            held[ObjectIdentifier(controller)] = Held(cursor: cursor, live: true)
        }
    }

    /// `controller` holds no client any more: the text input system took focus away from it, or
    /// it ended.
    ///
    /// By the controller, so a cursor left behind by one that was replaced - activated again, or
    /// orphaned beside another of the same client (IMK rule 5) - is removed by its own and never
    /// takes another's with it: focus can move by activating the new client before deactivating
    /// the old.
    public func left(_ controller: AnyObject) {
        changing { held[ObjectIdentifier(controller)] = nil }
    }

    /// A key reached `controller`, which IMK hands only the keys typed into its client: that
    /// client has the keyboard, and every other cursor is ruled out.
    ///
    /// This is the way out of the refusal that several live cursors are, and out of a cursor no
    /// activation revived after one in another app: the key is evidence of where the person is that
    /// no activation is. A controller holding no cursor - one deactivated, or that never had a
    /// client it could use - changes nothing. [LAW:dataflow-not-control-flow]
    public func typedInto(_ controller: AnyObject) {
        let key = ObjectIdentifier(controller)
        held[key].map { typed in
            // [LAW:nothing-unseen] The one change to which cursors are live that no activation or
            // deactivation line says.
            if live.count != 1 || !typed.live {
                insertLog.notice("a key typed into \(typed.cursor, privacy: .public) makes it the one live cursor, of \(self.live.count, privacy: .public) live")
            }
            changing { held = Dictionary(uniqueKeysWithValues: held.map { ($0.key, Held(cursor: $0.value.cursor, live: $0.key == key)) }) }
        }
    }

    /// How `controller`'s lines say the cursor it holds, from here, where it is held: whether it is
    /// live is part of what it holds. [LAW:one-source-of-truth]
    public func holding(_ controller: AnyObject) -> String {
        held[ObjectIdentifier(controller)].map { "holding \($0.cursor)" + ($0.live ? "" : ", not live") } ?? "holding no client"
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
        changing { held = held.filter { $0.value.cursor.application != application } }
    }

    /// Makes `change`, and tells the app when it leaves one cursor that was not the one before:
    /// an activation in a new place, or the deactivation or typed key that leaves one of several.
    /// [LAW:single-enforcer] Decided here, whichever door changed it, so words refused while
    /// several cursors were live are offered again the moment one is left, and never while several
    /// are.
    private func changing(_ change: () -> Void) {
        let before = sole
        change()
        if let after = sole, after !== before { arrived(after.application) }
    }

    /// The cursors words could go to.
    private var live: [Client] { held.values.filter(\.live).map(\.cursor) }

    /// The live cursor, when there is exactly one.
    private var sole: Client? { live.count == 1 ? live.first : nil }

    /// What an insert sees on the main actor: the cursor words go to, provided it is in the
    /// app that is actually in front, it is the only one live and its client is a text field, or
    /// the refusal that says why there is none, with the facts that decided it.
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
    /// Which app is in front, whether this source is selected and where the screens are arrive
    /// as values rather than being read here, so the whole of this decision is testable
    /// without a window server and the one reading of the workspace happens where the other
    /// effects are. [LAW:effects-at-boundaries]
    ///
    /// First, the app in front has to be one `destination` admits: words that follow a
    /// dictation's first go only to the app those went to, so a person who moved on mid-press
    /// is refused rather than typed into, and told that they moved - whatever the app they
    /// moved to holds, which is not where the words were going anyway.
    ///
    /// Then the input source: with another one selected the text input system hands this
    /// input method no client, so the cursor last held is one it has stopped routing to. The
    /// refusal names the Input menu, which is the fix, and not a field, which is not.
    ///
    /// Then the cursor has to be the only one live: of two, either could be the window the
    /// person is in, and committing into the other is answered `inserted` while the words go
    /// somewhere they are not looking.
    ///
    /// Last, the cursor's client has to answer that a text field is behind it. Every app
    /// hands the input method a client, a window with no field focused included, and what is
    /// committed into such a client goes nowhere while the commit returns as if it landed.
    /// So the client's own answer is asked, once and only of the one cursor the words would
    /// go to, and the log line names that answer rather than asking again.
    /// [LAW:no-silent-failure] [LAW:one-source-of-truth]
    public func inFront(for destination: Destination, whileInFrontIs frontmost: String?, selected: Bool,
                        screens: [CGRect]) -> InFront {
        let cursors = live
        func seen(_ field: FieldAnswer?, _ cursor: Result<Client, Refusal>) -> InFront {
            InFront(frontmost: frontmost, selected: selected, cursorApplication: cursors.first?.application,
                    cursors: cursors.count, field: field, screens: screens, cursor: cursor)
        }
        guard destination.admits(frontmost) else { return seen(nil, .failure(.dictationIsInAnotherApp)) }
        guard selected else { return seen(nil, .failure(.inputSourceIsNotSelected)) }
        guard let application = cursors.first?.application else { return seen(nil, .failure(.noTextFieldHasFocus)) }
        guard application == frontmost else { return seen(nil, .failure(.cursorIsInAnotherApp)) }
        guard let focus = sole else { return seen(nil, .failure(.cursorIsInSeveralPlaces)) }
        let field = focus.field
        return seen(field, field.isAField(on: screens) ? .success(focus) : .failure(.noTextFieldHasFocus))
    }
}

/// What an insert saw on the main actor: the app in front, whether this source was selected, the
/// cursors held, what the client of the one words would go to answered about its field, and the
/// decision made from them.
///
/// The app in front is named because the refusal that matters most is the one where it is
/// not the app holding the cursor, and a line saying only the outcome leaves a reader with
/// the question it was written to answer. The cursor held and its client's answer are named
/// because they tell the three ways into a no-text-field refusal apart: no client, a client
/// giving no document access, and a caret on no screen. A taken insert names where its
/// caret was too. [LAW:no-silent-failure] [LAW:nothing-unseen]
public struct InFront: CustomStringConvertible {
    let frontmost: String?
    let selected: Bool
    let cursorApplication: String?
    /// How many cursors are live, all of them in `cursorApplication`.
    let cursors: Int
    /// Asked only of the cursor the words would go to, so absent for every refusal decided
    /// before it.
    let field: FieldAnswer?
    let screens: [CGRect]
    public let cursor: Result<Client, Refusal>

    public var description: String {
        "with \(frontmost ?? "nothing") in front and "
            + (cursorApplication.map { cursors == 1 ? "the cursor in \($0)" : "\(cursors) cursors in \($0)" } ?? "no cursor")
            + (field.map(said) ?? "")
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
/// Only said, never compared or kept as a key: it is minted anew at activation, so one client
/// is several names over its life (`FocusedClient` keys by controller). [LAW:nothing-unseen]
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
            insertLog.notice("\(named ?? "", privacy: .public) is the panel of \(application, privacy: .public), taken as its cursor")
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
    /// said in the log beside the refusal the app is told.
    func commit(_ text: String, replacing: String) -> Refusal? {
        let range: NSRange
        do throws(Replacement.Unfound) {
            range = try Replacement.range(of: replacing, selection: { client.selectedRange() }, text: client.string(in:)).get()
        } catch {
            insertLog.notice("words could not be taken back from \(self.application, privacy: .public): \(error.description, privacy: .public)")
            return .wordsCannotBeTakenBack
        }
        client.insertText(text, replacementRange: range)
        return nil
    }
}

/// The insert category, which every line about where words go is said in.
private nonisolated let insertLog = Logger(subsystem: AppIdentity.inputMethodBundleIdentifier, category: "insert")
