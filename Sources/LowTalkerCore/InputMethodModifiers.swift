import Dispatch
import Identity
import Insertion
import os

/// The hotkey heard through this installation's input method: the input method tells the
/// app every change of the modifier keys it is handed, and this turns each change into the
/// key events that make it, for the detector above to find presses in. Nothing is granted to
/// the app for it.
///
/// The input method is handed keys only by an app in front that takes typing, and by none
/// under Secure Event Input, so a press anywhere else never arrives. It never keeps a key
/// back, since the input method hands every key back. It is handed no typed key at all, so
/// every reading of the session, the input method's and the app's, carries when it last saw
/// one, which is how a chord held as a modifier is told from one pressed alone.
///
/// A release is the one change it cannot wait to be told. One made where the input method
/// is handed nothing, or told while the app's port was full, would leave the microphone open
/// until the next change happened to arrive; so while anything is held, the app reads the
/// session's modifier keys itself - a reading that needs no grant - and lets go of what is no
/// longer down. [LAW:no-silent-failure]
///
/// The input method tells a cursor arriving on the same port, since it is the one name its
/// sandbox lets it reach the app on; that notice is no key, and goes to `cursorArrived`.
///
/// An input method whose process has ended tells nothing, and nothing but the app starts it
/// again, so while the feed is open its process is supervised by `superviseInputMethod`,
/// which answers how to stop. [LAW:no-silent-failure] [LAW:effects-at-boundaries] The
/// supervision is the app's to bring: launching a process is no part of hearing keys.
public struct InputMethodModifiers: ModifierFeed {
    private let cursorArrived: @MainActor () -> Void
    private let superviseInputMethod: @MainActor () -> Disposal

    public init(cursorArrived: @escaping @MainActor () -> Void,
                superviseInputMethod: @escaping @MainActor () -> Disposal) {
        self.cursorArrived = cursorArrived
        self.superviseInputMethod = superviseInputMethod
    }

    /// How often a held key is looked for in the session: how late, at most, a release the
    /// input method never told is heard.
    static let confirming: DispatchTimeInterval = .milliseconds(200)

    /// What the port's messages reach on the main actor: while the feed is open, the port
    /// and the handler; and the modifiers the detector has been told are held.
    ///
    /// The port and the handler go together, because a message can still be on its way to
    /// the main queue when the feed is disposed of, and a hotkey that has stopped must hear
    /// nothing after it. Disposing of the feed is what closes the port, then and there, and
    /// what a late message finds. [LAW:no-ambient-temporal-coupling]
    ///
    /// Generic in the port because it only holds it open and never calls it.
    @MainActor
    final class Installed<Port> {
        var open: (port: Port, handle: @MainActor (KeyEvent) -> Void)? {
            didSet { settleConfirming() }
        }
        private var told: ToldModifiers
        private var confirming: DispatchSourceTimer?
        /// The port's queue, where the session is read too.
        private let hearing: DispatchQueue
        /// [LAW:effects-at-boundaries] The reading of the session, the one the input method
        /// sends.
        private let session: @Sendable () -> HeldModifiers

        init(told: ToldModifiers, hearing: DispatchQueue, session: @escaping @Sendable () -> HeldModifiers) {
            self.told = told
            self.hearing = hearing
            self.session = session
        }

        func heard(_ moves: [KeyEvent]) {
            open.map { open in moves.forEach(open.handle) }
            settleConfirming()
        }

        /// A cursor arrived, which only a feed still open passes on.
        func heard(cursorArrivedTo arrived: @MainActor () -> Void) {
            open.map { _ in arrived() }
        }

        func heard(_ state: HeldModifiers) {
            heard(told.take(state.held, at: state.changed, lastTyped: state.lastTyped))
        }

        func confirmed(_ session: HeldModifiers, at time: HostTime) {
            heard(told.confirm(session: session.held, at: time, lastTyped: session.lastTyped))
        }

        /// [LAW:dataflow-not-control-flow] The session is read for as long as the feed is
        /// open and something is held, derived from those two facts wherever either changes,
        /// so there is no starting or stopping of it to get out of step with them.
        ///
        /// Read on the port's queue and handed on as its messages are, so a reading follows
        /// every message that reached the port before it, and its stamp is when it was read,
        /// not when the main queue got to it. [LAW:no-ambient-temporal-coupling]
        private func settleConfirming() {
            switch (open != nil && !told.held.isEmpty, confirming) {
            case (true, nil):
                let timer = DispatchSource.makeTimerSource(queue: hearing)
                timer.schedule(deadline: .now() + InputMethodModifiers.confirming, repeating: InputMethodModifiers.confirming,
                               leeway: .milliseconds(50))
                // Held by the timer until it is cancelled, so a reading on its way to the
                // main queue still has somewhere to land. Sendable, so it is isolated to no
                // actor: written in this main-actor class it would otherwise be the main
                // actor's, and trap when the timer runs it on `hearing`.
                timer.setEventHandler { @Sendable [self, session] in
                    let (session, time) = (session(), HostTime.now)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.confirmed(session, at: time) } }
                }
                timer.resume()
                confirming = timer
            case (false, let timer?):
                timer.cancel()
                confirming = nil
            case (true, _?), (false, nil):
                break
            }
        }
    }

    /// Throws when the hotkey port cannot be hosted - most often because another process
    /// already hears on it, such as a second copy of the app.
    public func install(handling handle: @escaping @MainActor (KeyEvent) -> Void) throws -> Disposal {
        // What is held as listening begins is read, not assumed to be nothing, so a key
        // already down when this comes up is not heard going down when it next moves.
        let hearing = DispatchQueue(label: AppIdentity.hotkeyPortName)
        let installed = Installed<NoticePort>(told: ToldModifiers(held: Modifier.heldInSession()), hearing: hearing,
                                                session: { HeldModifiers(SessionModifiers.read()) })
        let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "hotkey")
        // Checked and read off the main thread, where the keys and the menu are, and handed
        // to it in the order the input method sent them: the main queue is first in, first
        // out, which keeps a key's down ahead of its up. [LAW:no-ambient-temporal-coupling]
        let port = try NoticePort(
            queue: hearing,
            told: { event in log.error("\(event.description, privacy: .public)") },
            heard: { [cursorArrived] notice in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch notice {
                        case .modifiersMoved(let state): installed.heard(state)
                        case .cursorArrived: installed.heard(cursorArrivedTo: cursorArrived)
                        }
                    }
                }
            })
        installed.open = (port, handle)
        // Supervised only once the port is hosted, so its first notice has somewhere to go.
        let unsupervise = superviseInputMethod()
        // Closed here and now, so a hotkey rebuilt straight after hosts the name again.
        return {
            installed.open = nil
            unsupervise()
        }
    }
}

/// The modifier keys the detector has been told are held: what each state heard next is the
/// difference from.
///
/// Two readings reach it. The input method's, which can press and let go, stamped no later
/// than it read the session and arriving in that order; and the app's own of the session, which only
/// confirms what is still down and so can only let go. What the session let go of is kept
/// per key with when it was read, because a message from the input method stamped before
/// then can still be on its way holding that key, and must not press it again - while
/// every other key in that message is news the session read could not have given, and is
/// taken. [LAW:no-ambient-temporal-coupling]
public struct ToldModifiers: Sendable {
    public private(set) var held: Set<Modifier>
    private var letGo: [Modifier: HostTime] = [:]

    public init(held: Set<Modifier>) {
        self.held = held
    }

    /// The key events that take the detector to holding `now`, as the input method read it
    /// at `time`, with a key last typed at `lastTyped`.
    public mutating func take(_ now: Set<Modifier>, at time: HostTime, lastTyped: HostTime?) -> [KeyEvent] {
        // A later message has nothing older left to be overtaken by. [LAW:dataflow-not-control-flow]
        letGo = letGo.filter { $0.value > time }
        return move(to: now.subtracting(letGo.keys), at: time, lastTyped: lastTyped)
    }

    /// The key events that let go of what `session`, read at `time`, no longer holds.
    public mutating func confirm(session: Set<Modifier>, at time: HostTime, lastTyped: HostTime?) -> [KeyEvent] {
        held.subtracting(session).forEach { letGo[$0] = time }
        return move(to: held.intersection(session), at: time, lastTyped: lastTyped)
    }

    private mutating func move(to now: Set<Modifier>, at time: HostTime, lastTyped: HostTime?) -> [KeyEvent] {
        defer { held = now }
        return KeyEvent.moves(from: held, to: now, at: time, lastTyped: lastTyped)
    }
}

extension KeyEvent {
    /// The key events that take the keyboard from holding `before` to holding `after`, each
    /// carrying what is held once it has happened: what a stream of states becomes for the
    /// detector, which reads keys moving.
    ///
    /// A state that did not change is no events at all, which is what makes a state told
    /// twice - VS Code hands the input method each change twice, measured on studious,
    /// 2026-09-27 - the same as one. A state that moved by several keys at once, because
    /// the input method was not handed the changes in between or read the state after the
    /// next had already come, is every key that came up and then one key down carrying the
    /// whole state: keys that went down together were never seen held apart, so no chord
    /// that some of them make is completed on the way to the one they make together.
    public static func moves(from before: Set<Modifier>, to after: Set<Modifier>, at time: HostTime, lastTyped: HostTime?) -> [KeyEvent] {
        let released = Modifier.allCases.filter { before.contains($0) && !after.contains($0) }
        let pressed = Modifier.allCases.filter { after.contains($0) && !before.contains($0) }
        var held = before
        let ups = released.map { modifier in
            held.remove(modifier)
            return KeyEvent(key: modifier, direction: .up, modifiers: held, time: time, lastTyped: lastTyped)
        }
        let downs = pressed.suffix(1).map { KeyEvent(key: $0, direction: .down, modifiers: after, time: time, lastTyped: lastTyped) }
        return ups + downs
    }
}

extension HeldModifiers {
    /// The modifiers the reading shows held.
    var held: Set<Modifier> { Modifier.held(in: flags) }

    /// When they changed to what the reading shows.
    var changed: HostTime { HostTime(uptime: .nanoseconds(uptimeNanoseconds)) }

    /// When a key was last typed, if that was before the change: the session keeps only its
    /// latest key, so one typed after the change hides any typed before. A reading the app
    /// takes itself is dated by the session's last change, so a release only the app saw is
    /// judged at the release and not at the reading, up to `confirming` later.
    var lastTyped: HostTime? {
        typedUptimeNanoseconds <= uptimeNanoseconds ? HostTime(uptime: .nanoseconds(typedUptimeNanoseconds)) : nil
    }
}
