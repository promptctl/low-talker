import AppKit
import Insertion
import InputMethodKit

/// The controller macOS gives each client to while this input method is the selected source,
/// which declines every key it is offered but a bare Return and an Escape, and holds those only
/// against words the app owes.
///
/// An input method sits between the keyboard and whatever the person is typing into, so the
/// keys it does not hand back are keys that never arrive anywhere. Declining the keys is what
/// makes selecting this source cost nothing: the app in front sees exactly the keys it would
/// have seen under the person's own layout, dead keys and shortcuts included, because the text
/// input system delivers them itself once the controller says it did not.
///
/// The keys it looks at are a Return typed bare and an Escape. Dictation is words on their way to
/// the cursor, and a Return typed meanwhile would reach the app ahead of them and send the message
/// without them; the only grant-free way for it to arrive after is this process declining it once
/// the words are committed, so `SteeringGate` holds it here until the app says they have landed. An
/// Escape is kept while the word box is shown, and the app cancels the open press when told; the
/// words already at the cursor are taken back by the app afterwards. The verdict is the gate's for
/// a Return, and this answers with it, so there is no key whose answer is a decision made here.
/// [LAW:dataflow-not-control-flow] A swallowed key is invisible - the person sees a Return that did
/// nothing - so every one the gate keeps is on the command's record, with the gate's reason.
/// [LAW:no-silent-failure]
///
/// `@objc` with an explicit name because `InputMethodServerControllerClass` in the bundle's
/// `Info.plist` names this class as a string, and the Objective-C runtime is what resolves
/// it; `InputMethodPlistTests` holds that string to this name.
@objc(DictationInputController)
public final class DictationInputController: IMKInputController, InputController {
    /// What this controller did, one record per unit of work, in order: its making, each callback,
    /// its ending, after which the stream finishes. A test reads it as values; the unified log
    /// receives each record's rendering as it is made. [LAW:nothing-unseen]
    ///
    /// Nothing reads it in the shipped process, and a controller lives as long as its client while
    /// every key typed leaves a record, so it keeps the oldest 32 and drops the rest: `made` is
    /// never pushed out, and the log still receives every record.
    nonisolated public let records: AsyncStream<ControllerRecord>
    nonisolated private let recording: AsyncStream<ControllerRecord>.Continuation

    /// How `IMKServer` builds the controller. Nonisolated, as the initializers they override
    /// are, which a main-actor class does not inherit.
    nonisolated override public init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        (records, recording) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(32))
        super.init(server: server, delegate: delegate, client: inputClient)
        // [LAW:nothing-unseen] A controller's whole life, so an orphaned one (IMK rule 5) is
        // seen to have been made and never to have ended.
        record(.made)
    }

    nonisolated override public init() {
        (records, recording) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(32))
        super.init()
        record(.made)
    }

    /// A controller that ends without being deactivated - closed with its window, or orphaned (IMK
    /// rule 5) - takes its cursor with it, so no cursor outlives its controller to be refused
    /// beside a live one or committed into. Isolated rather than through `onMainActor`'s
    /// `main.sync`: an end has no answer to wait for, and waiting would hold the thread IMK
    /// releases it on behind a commit into a stalled app (3.0 s, low-imk-rules-w3g.3ky). The
    /// object is not freed until this has run, so no later controller at its address inherits
    /// the cursor.
    isolated deinit {
        record(.ended)
        recording.finish()
        FocusedClient.shared.left(self)
    }

    nonisolated private var address: UInt { UInt(bitPattern: ObjectIdentifier(self)) }

    /// Leaves one record, on whichever thread the unit of work ran.
    nonisolated private func record(_ event: ControllerRecord.Event) {
        let record = ControllerRecord(controller: address, event: event)
        record.log()
        recording.yield(record)
    }

    /// The one way a callback reaches the main actor, and the one place its record is left: `body`
    /// answers IMK and says what it decided, and the record carries that with the hop.
    /// [LAW:single-enforcer] A callback cannot leave no record, or two.
    nonisolated private func entered<Argument, Answer: Sendable>(_ argument: Argument,
                                                                 _ body: @MainActor (Argument) -> (Answer, ControllerRecord.Decision)) -> Answer {
        onMainActor(argument) { argument, hop in
            let (answer, decided) = body(argument)
            self.record(.callback(hop, decided))
            return answer
        }
    }

    /// What `FocusedClient` holds of this controller's client, as its records say it.
    private var holding: String { FocusedClient.shared.holding(self) }

    /// The events this controller is handed: key-downs (0x400, the value `super` returned on
    /// studious, 2026-09-27), which the text input system binds to actions for `didCommand`. The app
    /// hears the modifier keys itself. [LAW:dataflow-not-control-flow]
    nonisolated override public func recognizedEvents(_: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    /// The key-binding style: the text input system binds each key-down to an action and asks here
    /// for that action. Return is bound to `insertNewline:`, which is held for the words the app owes
    /// and kept when the gate keeps it. Escape is bound to `cancelOperation:`: it is reported to the
    /// app, which cancels the open press and closes the panel, and it is kept while the panel is
    /// shown. Every other action is declined.
    ///
    /// Overridden with an optional selector, as IMK may call with none.
    nonisolated override public func didCommand(by selector: Selector!, client _: Any!) -> Bool {
        // IMK hands the command while the key is still down, so the modifiers held as it arrives are
        // the key's own. Read before the hop, which can wait out a Return the main thread is holding,
        // and handed on as a value: a read of the window server's modifier state, not a call on the
        // client, so off the main actor is where it belongs. [LAW:effects-at-boundaries]
        didCommand(by: selector, holding: NSEvent.modifierFlags)
    }

    /// The answer to the command `selector`, bound to a key typed with `modifiers` held.
    nonisolated public func didCommand(by selector: Selector?, holding modifiers: NSEvent.ModifierFlags) -> Bool {
        entered((selector: selector, modifiers: modifiers)) { command in
            FocusedClient.shared.typedInto(self)
            let named = command.selector.map(NSStringFromSelector) ?? "no command"
            let steered = SteeringKey(command: command.selector, holding: command.modifiers).map { key in
                ControllerRecord.Steered(key: key, decision: self.decide(key))
            }
            return (steered?.decision.verdict == .keep, .command(named, steered: steered, holding: self.holding))
        }
    }

    /// The gate's decision of `key`, and what follows from it here: a kept Return is heard, and a
    /// kept Escape is told to the app.
    private func decide(_ key: SteeringKey) -> SteeringDecision {
        switch key {
        case .return:
            let decided = SteeringGate.shared.verdict(at: ProcessInfo.processInfo.systemUptime)
            // The system's own answer to a Return that did nothing, so a kept one is heard at the
            // moment it was typed and not only found in a log. [LAW:no-silent-failure]
            if decided.verdict == .keep { NSSound.beep() }
            return decided
        case .escape:
            let decided = SteeringGate.shared.escapeVerdict(at: ProcessInfo.processInfo.systemUptime)
            // The app cancels the open press when told, and is told only of an Escape it is kept.
            // [LAW:single-enforcer]
            if decided.verdict == .keep { Notices.shared.keyTyped(.escape) }
            return decided
        }
    }

    /// A key typed as text, which is declined, so it reaches the app as the person typed it.
    /// Entered on the main actor like every callback, to say which client the key went to.
    nonisolated override public func inputText(_: String!, client _: Any!) -> Bool {
        entered(()) {
            FocusedClient.shared.typedInto(self)
            return (false, .declinedText(holding: self.holding))
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
        activate(sender, makingCursor: Self.cursor(of:))
    }

    /// The cursor IMK's `sender` makes, read where the workspace is: none for a sender that is no
    /// client, or a client that will not name its app. [LAW:effects-at-boundaries]
    @MainActor
    private static func cursor(of sender: Any?) -> Client? {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return (sender as? IMKTextInput).flatMap { Client(IMKClient(client: $0), inFront: frontmost) }
    }

    /// `activateServer` with the cursor `makingCursor` makes of `sender`: the IMK cast is the
    /// override's, so the rest is driven by a test with a fake client.
    nonisolated func activate(_ sender: Any?, makingCursor: @MainActor (Any?) -> Client?) {
        // The client is read here, and every later call on it, the commits included, is made
        // on this same actor (IMK rule 4).
        entered(sender) { sender in
            // IMK rule 7. A process past its ceiling takes no client, so an insert asked of it
            // before it ends is refused and the app holds the words for the process after it.
            if let overrun = ownFootprint().flatMap(Notices.shared.activated(holding:)) {
                return ((), .overMemoryCeiling(overrun))
            }
            // A sender no cursor can be made of changes nothing here. Not reported, because a
            // sender THIS controller cannot understand is no reason to take the cursor away from
            // another controller that can; and the cursor this one already held stays as it was,
            // held by `FocusedClient` for this controller until it deactivates or ends. One rule,
            // and it lives in `Client.init`: a cursor that exists is a cursor `took` accepts.
            // [LAW:single-enforcer]
            guard let arriving = makingCursor(sender) else { return ((), .activatedWithoutUsableClient(holding: self.holding)) }
            // Told to the app by `FocusedClient` once this is the cursor words go to, so words the
            // app offers in answer find it in front.
            FocusedClient.shared.took(arriving, by: self)
            return ((), .activated(holding: self.holding))
        }
    }

    /// Focus left this controller's client.
    ///
    /// Said as this controller, so `FocusedClient` removes this client's cursor and never another
    /// controller's that arrived first.
    nonisolated override public func deactivateServer(_: Any!) {
        entered(()) {
            let held = self.holding
            FocusedClient.shared.left(self)
            return ((), .deactivated(holding: held))
        }
    }
}
