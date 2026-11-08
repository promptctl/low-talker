import AppKit
import Identity
import Insertion
import InputMethodKit
import os

/// A line about one controller: which it is, what happened to it, and what it says of its
/// client, when there is something to say. Nothing is decided from any of it.
///
/// The controller is its address, which the allocator hands to a later controller once this one
/// has ended: read the lines in order, and "made" minus "ended" at one address is still how many
/// are live.
nonisolated func controllerLine(controller: UInt, _ event: String, client: String? = nil) -> String {
    "controller 0x\(String(controller, radix: 16)) \(event)" + (client.map { ", \($0)" } ?? "")
}

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
/// Escape is for the dictation when one is open: the gate asks the app to throw it away and keeps
/// the Escape when it did, and the app takes the words already at the cursor back afterwards. The
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
        // [LAW:nothing-unseen] A controller's whole life, so an orphaned one (IMK rule 5) is
        // seen to have been made and never to have ended.
        logLife("was made")
    }

    nonisolated override public init() {
        super.init()
        logLife("was made")
    }

    deinit {
        logLife("ended")
    }

    nonisolated private var address: UInt { UInt(bitPattern: ObjectIdentifier(self)) }

    /// A line about the controller alone, said on whichever thread IMK builds and frees it.
    nonisolated private func logLife(_ event: String) {
        imkLog.log("\(controllerLine(controller: self.address, event), privacy: .public)")
    }

    /// One of this controller's lines about the client it holds, which says which controller it
    /// is, and that it holds none when it does not. A client that did not arrive with an
    /// activation is the one it already held, so the line says "holding" either way.
    private func said(_ event: String, about client: Client?) -> String {
        controllerLine(controller: address, event, client: client.map { "holding \($0)" } ?? "holding no client")
    }

    /// The events this controller is handed: key-downs (0x400, the value `super` returned on
    /// studious, 2026-09-27), which the text input system binds to actions for `didCommand`. The app
    /// hears the modifier keys itself. [LAW:dataflow-not-control-flow]
    nonisolated override public func recognizedEvents(_: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    /// The key-binding style: the text input system binds each key-down to an action and asks here
    /// for that action. Return is bound to `insertNewline:`, which is held for the words the app owes
    /// and kept when the gate keeps it. Escape is bound to `cancelOperation:`: it is reported to the
    /// app, and kept only while the app's word box is open. Every other action is declined.
    ///
    /// Overridden with an optional selector, as IMK may call with none.
    nonisolated override public func didCommand(by selector: Selector!, client _: Any!) -> Bool {
        // Debug level: this is made once per key typed anywhere.
        return onMainActor("didCommand", selector, level: .debug) { selector in
            imkLog.debug("\(self.said("was handed a command", about: self.cursor), privacy: .public)")
            if selector == NSSelectorFromString("insertNewline:") { return self.holdReturn() }
            if selector == NSSelectorFromString("cancelOperation:") {
                Notices.shared.keyTyped(.escape)
                return AppState.shared.panelShown
            }
            return false
        }
    }

    /// Text is never handed to this input method as keys, so it is declined.
    nonisolated override public func inputText(_: String!, client _: Any!) -> Bool { false }

    /// The held Return: kept, and the system's beep said, when the gate keeps it.
    @MainActor private func holdReturn() -> Bool {
        guard AppState.shared.holdsReturn else { return false }
        let kept = SteeringGate.shared.verdict(for: .return, at: ProcessInfo.processInfo.systemUptime) == .keep
        // The system's own answer to a Return that did nothing, so a kept one is heard at the moment it
        // was typed and not only found in a log. [LAW:no-silent-failure]
        if kept { NSSound.beep() }
        return kept
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
            // The app in front is read here, where the workspace is, and handed to the cursor
            // as a value. [LAW:effects-at-boundaries]
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let arriving = (sender as? IMKTextInput).flatMap { Client($0, inFront: frontmost) }
            self.cursor = arriving ?? self.cursor
            arriving.map(FocusedClient.shared.took)
            // [LAW:nothing-unseen] Which controller and which client, so two windows of one app
            // that activate in the same millisecond are two lines that say so, and a sender that
            // made no cursor is the controller's own held one, named.
            imkLog.log("\(self.said(arriving == nil ? "activated without a usable client" : "activated", about: self.cursor), privacy: .public)")
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
            imkLog.log("\(self.said("deactivated", about: self.cursor), privacy: .public)")
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
