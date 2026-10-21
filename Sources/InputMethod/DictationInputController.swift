import AppKit
import InputMethodKit

/// The controller macOS gives each client to while this input method is the selected source,
/// which declines every key it could be offered.
///
/// An input method sits between the keyboard and whatever the person is typing into, so the
/// keys it does not hand back are keys that never arrive anywhere. Declining all of them is
/// what makes selecting this source cost nothing: the app in front sees exactly the keys it
/// would have seen under the person's own layout, dead keys and shortcuts included, because
/// the text input system delivers them itself once the controller says it did not.
///
/// [LAW:dataflow-not-control-flow] There is no key this looks at, and the cursor it records
/// for `FocusedClient` is never consulted to answer one, so there is no key for which the
/// answer differs - it is a constant, not a decision. What low-input-method-s71.31s adds is insertion the *app* asks for, which
/// arrives by a different door entirely; a key claimed here would be a broken keyboard, and
/// the swallowed key is invisible - the person sees a letter that did not appear.
/// [LAW:no-silent-failure]
///
/// `@objc` with an explicit name because `InputMethodServerControllerClass` in the bundle's
/// `Info.plist` names this class as a string, and the Objective-C runtime is what resolves
/// it; `InputMethodPlistTests` holds that string to this name.
@objc(DictationInputController)
public final class DictationInputController: IMKInputController {
    /// How `IMKServer` builds the controller. Nonisolated, as the initializers they override
    /// are, which a main-actor class does not inherit.
    nonisolated override public init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    nonisolated override public init() { super.init() }

    /// The events this controller is handed: none. What the text input system offers when
    /// nobody says is key-downs alone (0x400, read off `super` on studious, 2026-09-27), which
    /// is every key typed; the app hears the modifier keys itself, so this asks for nothing,
    /// and no key a person types or holds reaches this process.
    nonisolated override public func recognizedEvents(_: Any!) -> Int { 0 }

    /// Every event declined: returning false is how the signature says "not mine", which is
    /// the whole behaviour this controller has toward keys.
    ///
    /// Overridden, though no event is asked for, because IMK also calls this with no event at
    /// all (low-input-method-8vv: the call after an activate trapped on the implicitly
    /// unwrapped event the inherited signature has).
    nonisolated override public func handle(_: NSEvent?, client _: Any!) -> Bool { false }

    /// The text input system gave this controller's client focus, which is the only way
    /// this process learns where words can go.
    ///
    /// Reported rather than kept, because the client that is in front is not this
    /// controller's to know: `IMKServer` builds one controller per client, and the app's
    /// insert arrives on a port that belongs to none of them. [LAW:one-source-of-truth]
    ///
    /// Focus, not a key: nothing here waits for the person to type, so an insert asked for
    /// before any key has ever arrived is answered like any other. Reported before this returns,
    /// and never queued for later, for the same reason - a later report would come after the
    /// insert that asked about it had already been refused, and the words would be lost while
    /// the cursor sat waiting. [LAW:no-ambient-temporal-coupling]
    nonisolated override public func activateServer(_ sender: Any!) {
        // The client is read here, and every later call on it, the commits included, is made
        // on this same actor (IMK rule 4).
        onMainActor("activateServer", sender) { sender in
            // IMK rule 7. A process past its ceiling takes no client, so an insert asked of it
            // before it ends is refused and the app holds the words for the process after it.
            guard ownFootprint().flatMap(Notices.shared.activated(holding:)) == nil else { return }
            // A sender no cursor can be made of - no client at all, or a client that will
            // not name its app - changes nothing here. Not reported, because a sender THIS
            // controller cannot understand is no reason to take the cursor away from another
            // controller that can; and not forgotten either, because the cursor last
            // reported is the one `deactivateServer` hands back, so dropping it would leave
            // `FocusedClient` holding a client nobody can retract. One rule, and it lives in
            // `Client.init`: a cursor that exists is a cursor `took` accepts.
            // [LAW:single-enforcer]
            let arriving = (sender as? IMKTextInput).flatMap(Client.init)
            self.cursor = arriving ?? self.cursor
            arriving.map(FocusedClient.shared.took)
            // Told after it is taken, so words the app offers in answer find it in front.
            arriving.map { Notices.shared.cursorArrived(in: $0.application) }
        }
    }

    /// Focus left this controller's client.
    ///
    /// The cursor made on the way in is the one handed back, so `FocusedClient` can tell
    /// this client leaving from a different one arriving - a fresh wrapper around the same
    /// client would be a different object and the comparison would always miss.
    nonisolated override public func deactivateServer(_: Any!) {
        onMainActor("deactivateServer", ()) {
            self.cursor.map(FocusedClient.shared.left)
            self.cursor = nil
        }
    }

    /// This controller's client, as the one thing this process asks of it.
    ///
    /// Held here because `IMKServer` builds one controller per client, so this IS the one
    /// place with a client's lifetime to hang it on. [LAW:one-source-of-truth]
    private var cursor: Client?
}
