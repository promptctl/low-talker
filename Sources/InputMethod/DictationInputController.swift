import AppKit
import InputMethodKit

/// The controller macOS gives each client to while this input method is the selected source,
/// which declines every key it is offered but a bare Return, and holds that one only against
/// words the app owes.
///
/// An input method sits between the keyboard and whatever the person is typing into, so the
/// keys it does not hand back are keys that never arrive anywhere. Declining the keys is what
/// makes selecting this source cost nothing: the app in front sees exactly the keys it would
/// have seen under the person's own layout, dead keys and shortcuts included, because the text
/// input system delivers them itself once the controller says it did not.
///
/// The one key it looks at is a Return typed bare. Dictation is words on their way to the cursor,
/// and a Return typed meanwhile would reach the app ahead of them and send the message without
/// them; the only grant-free way for it to arrive after is this process declining it once the
/// words are committed, so `ReturnGate` holds it here until the app says they have landed. The
/// verdict is the gate's, and this answers with it, so there is no key whose answer is a decision
/// made here. [LAW:dataflow-not-control-flow] A swallowed key is invisible - the person sees a
/// Return that did nothing - so the gate says every one it keeps in the log. [LAW:no-silent-failure]
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

    /// The events this controller is handed: key-downs (0x400, the value `super` returned on
    /// studious, 2026-09-27), which is every key typed. The app hears the modifier keys itself,
    /// and a Return is the one key anything here answers differently.
    nonisolated override public func recognizedEvents(_: Any!) -> Int { Int(NSEvent.EventTypeMask.keyDown.rawValue) }

    /// Declines every key but a bare Return, which is held for the words the app owes.
    ///
    /// Overridden with an optional event because IMK also calls this with no event at all
    /// (low-input-method-8vv: the call after an activate trapped on the implicitly unwrapped
    /// event the inherited signature has), and with events that are not keys, whose key code is
    /// not to be read.
    nonisolated override public func handle(_ event: NSEvent?, client _: Any!) -> Bool {
        // Debug level: this is made once per key typed anywhere.
        onMainActor("handle", event, level: .debug) { event in
            guard let event, event.type == .keyDown,
                  let key = SteeringKey(keyCode: event.keyCode, flags: event.modifierFlags) else { return false }
            switch key {
            case .return:
                let kept = ReturnGate.shared.verdict(forReturnAt: event.timestamp) == .keep
                // The system's own answer to a key that did nothing, so a kept Return is heard
                // at the moment it was typed and not only found in a log. [LAW:no-silent-failure]
                if kept { NSSound.beep() }
                return kept
            }
        }
    }

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
