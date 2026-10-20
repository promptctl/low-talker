import AppKit
import Carbon.HIToolbox
import Identity
import os

/// The hotkey heard from the window server's own events: every change of the modifier keys,
/// in any app, through a global and a local `NSEvent` monitor of `.flagsChanged`, turned into
/// the key events that make it, for the detector above to find presses in.
///
/// Nothing is granted to the app for it, and nothing in it goes through the input method, so
/// the chord is heard whichever input source is selected. Measured 2026-10-20 with real HID
/// presses on studious (macOS 15.0.1) and u2 (macOS 26.5.2): an ad hoc signed app with no
/// grant was handed every change, with LowTalker's source selected, with ABC or U.S.
/// selected, under iTerm2's Secure Keyboard Entry and with a password field in front. The
/// input method had been handed none of them while another source was selected. Only
/// `.flagsChanged` is asked for: a monitor of typed keys would need Input Monitoring.
///
/// A release no event tells - let go during a session switch, or a lock - would leave the
/// microphone open until the next change happened to arrive; so while anything is held, the
/// app reads the session's modifier keys itself and lets go of what is no longer down.
/// [LAW:no-silent-failure]
public struct ModifierMonitor: ModifierFeed {
    public init() {}

    /// How often a held key is looked for in the session. A release no event told is heard
    /// within two of these, since one younger than `ToldModifiers.telling` is left for the next.
    static let confirming: DispatchTimeInterval = .milliseconds(200)

    /// What the monitors' events reach on the main actor: while the feed is open, the handler;
    /// and the modifiers the detector has been told are held.
    ///
    /// [LAW:no-ambient-temporal-coupling] Every reading is taken and applied here, on the main
    /// actor: the monitors call on the main thread and the session is read on the main queue.
    /// Each carries the stamp of what it read, so the one reordering left - the timer firing
    /// ahead of an event already queued - is `ToldModifiers`'s to settle, by stamp.
    @MainActor
    final class Installed {
        var open: (@MainActor (KeyEvent) -> Void)? {
            didSet { settleConfirming() }
        }
        private var told: ToldModifiers
        private var confirming: DispatchSourceTimer?
        /// [LAW:effects-at-boundaries] The reading of the session.
        private let session: @MainActor () -> SessionModifiers
        /// Where each change heard is said.
        private let noted: @MainActor (String) -> Void

        init(told: ToldModifiers, session: @escaping @MainActor () -> SessionModifiers,
             noted: @escaping @MainActor (String) -> Void) {
            self.told = told
            self.session = session
            self.noted = noted
        }

        func heard(_ change: FlagsChanged) {
            let moves = told.take(change.held(after: told.held), at: change.time, lastTyped: change.lastTyped)
            // [LAW:nothing-unseen] One record per change heard, with what it moved: the only
            // window onto what the hotkey was handed.
            let moved = moves.isEmpty ? "no key moved" : moves.map { "\($0.key) \($0.direction)" }.joined(separator: ", ")
            noted("\(change): \(moved)")
            tell(moves)
        }

        func confirmed(_ session: SessionModifiers, at time: HostTime) {
            tell(told.confirm(session: Modifier.held(in: session.flags), changed: HostTime(seconds: session.changedAt), at: time))
        }

        private func tell(_ moves: [KeyEvent]) {
            open.map { handle in moves.forEach(handle) }
            settleConfirming()
        }

        /// [LAW:dataflow-not-control-flow] The session is read for as long as the feed is
        /// open and something is held, derived from those two facts wherever either changes,
        /// so there is no starting or stopping of it to get out of step with them.
        private func settleConfirming() {
            switch (open != nil && !told.held.isEmpty, confirming) {
            case (true, nil):
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + ModifierMonitor.confirming, repeating: ModifierMonitor.confirming,
                               leeway: .milliseconds(50))
                // Held by the timer until it is cancelled. Stamped once read, so the reading
                // is never dated before what it saw.
                timer.setEventHandler { [self] in
                    MainActor.assumeIsolated {
                        let reading = session()
                        confirmed(reading, at: .now)
                    }
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

    /// Throws when macOS installs no monitor, which leaves the chord unheard.
    public func install(handling handle: @escaping @MainActor (KeyEvent) -> Void) throws -> Disposal {
        let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "hotkey")
        // What is held as listening begins is read, not assumed to be nothing, so a key
        // already down when this comes up is not heard going down when it next moves.
        let installed = Installed(told: ToldModifiers(held: Modifier.heldInSession()), session: SessionModifiers.read,
                                  noted: { log.info("\($0, privacy: .public)") })
        // The global monitor is handed what goes to every other app, and the local one what
        // comes to this app's own windows. Both call on the main thread.
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { installed.heard(.reading(event)) }
        }) else { throw MonitorNotInstalled.global }
        guard let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { installed.heard(.reading(event)) }
            return event
        }) else {
            NSEvent.removeMonitor(global)
            throw MonitorNotInstalled.local
        }
        installed.open = handle
        return {
            installed.open = nil
            NSEvent.removeMonitor(global)
            NSEvent.removeMonitor(local)
        }
    }
}

/// A monitor macOS did not install. [LAW:no-silent-failure]
public enum MonitorNotInstalled: Error, CustomStringConvertible {
    case global, local

    public var description: String {
        switch self {
        case .global: "macOS installed no monitor of the modifier keys in other apps"
        case .local: "macOS installed no monitor of the modifier keys in this app's own windows"
        }
    }
}

/// One change of the modifier keys, as its event says: the flags it carries, which key
/// moved, when, and when a key was last typed before it.
///
/// Read off the event and not off the session at the moment it is handled, so a change
/// queued behind a busy main thread is still the change it was, and a tap whose down and up
/// are both handled late is still a tap. [LAW:no-ambient-temporal-coupling]
public struct FlagsChanged: Equatable, Sendable, CustomStringConvertible {
    /// The event's modifier flags, device-side bits included, which tell Right Option from
    /// Left: 0x80140 for Right Option alone, measured.
    public let flags: UInt64
    /// The key that moved.
    public let keyCode: UInt16
    /// When, in seconds since the machine came up: `NSEvent.timestamp`.
    public let timestamp: TimeInterval
    /// When a key that is not a modifier last went down before the change, on the same clock:
    /// what tells a chord pressed alone from one held as the modifier of a typed key, which
    /// no monitor here is handed. Nil when the session's last key-down came after the change.
    public let typedAt: TimeInterval?

    /// `lastKeyDown` is the session's last key-down, read when the event is handled.
    public init(flags: UInt64, keyCode: UInt16, timestamp: TimeInterval, lastKeyDown: TimeInterval) {
        self.flags = flags
        self.keyCode = keyCode
        self.timestamp = timestamp
        typedAt = Self.typed(lastKeyDown: lastKeyDown, before: timestamp)
    }

    /// [LAW:effects-at-boundaries] The event, and the session's last key-down, read now.
    /// Reading that needs no grant: measured on studious, 2026-10-19, an app with neither
    /// Input Monitoring nor Accessibility read the moment of an A typed under a held Right
    /// Option. On u2 (macOS 26.5.2), 2026-10-20, it is stale while an app holds Secure Event
    /// Input, so a key typed there under the chord goes unseen.
    @MainActor
    static func reading(_ event: NSEvent) -> FlagsChanged {
        let sinceTyped = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return FlagsChanged(flags: UInt64(event.modifierFlags.rawValue), keyCode: event.keyCode, timestamp: event.timestamp,
                            lastKeyDown: ProcessInfo.processInfo.systemUptime - sinceTyped)
    }

    /// When a key was last typed, given the session's last key down, if that was before the
    /// change; nil otherwise. The session keeps only its latest key, so one typed since the
    /// change hides any typed before it. A session with no key typed reports one near when
    /// the machine came up, which is taken as typed then and never before it.
    /// [LAW:parse-dont-validate]
    static func typed(lastKeyDown: TimeInterval, before change: TimeInterval) -> TimeInterval? {
        let typed = max(lastKeyDown, 0)
        return typed < change ? typed : nil
    }

    /// The modifiers held once this happened, given those held before it.
    ///
    /// Fn by which key moved: the session sets the secondary-Fn bit for the arrow and
    /// navigation keys too, so another key's event can carry it with Fn up. Those keys arrive
    /// as key-downs and never as `.flagsChanged`, so only the Fn key's own event says what
    /// Fn did, and every other event leaves it as it was. That event can carry the bit as Fn
    /// goes up, too, while an arrow is still down (not measured: vhid has no Fn key), so it
    /// presses Fn only when Fn was up; with Fn held it is the release.
    func held(after before: Set<Modifier>) -> Set<Modifier> {
        let others = Modifier.held(in: flags).subtracting([.function])
        let fn = keyCode == UInt16(kVK_Function)
            ? flags & Modifier.function.mask != 0 && !before.contains(.function)
            : before.contains(.function)
        return fn ? others.union([.function]) : others
    }

    var time: HostTime { HostTime(seconds: timestamp) }

    var lastTyped: HostTime? { typedAt.map(HostTime.init(seconds:)) }

    public var description: String {
        "key \(keyCode) moved at \(timestamp): flags 0x\(String(flags, radix: 16))"
            + (typedAt.map { ", a key typed at \($0)" } ?? ", a key typed since")
    }
}

/// The modifier keys the detector has been told are held: what each state heard next is the
/// difference from.
///
/// Two readings reach it. Each change's own event, which can press and let go, stamped when
/// the change happened; and the app's own reading of the session, which only confirms what
/// is still down and so can only let go. What the session let go of is kept per key with
/// when it was read, because an event stamped before then can still be queued holding that
/// key - a timer can fire ahead of an event already waiting - and must not press it again,
/// while every other key in that event is news the session read could not have given, and
/// is taken. [LAW:no-ambient-temporal-coupling]
public struct ToldModifiers: Sendable {
    public private(set) var held: Set<Modifier>
    private var letGo: [Modifier: HostTime] = [:]

    public init(held: Set<Modifier>) {
        self.held = held
    }

    /// The key events that take the detector to holding `now`, as a change's event said it
    /// at `time`, with a key last typed at `lastTyped`.
    public mutating func take(_ now: Set<Modifier>, at time: HostTime, lastTyped: HostTime?) -> [KeyEvent] {
        // A later event has nothing older left to be overtaken by. [LAW:dataflow-not-control-flow]
        letGo = letGo.filter { $0.value > time }
        return move(to: now.subtracting(letGo.keys), at: time, lastTyped: lastTyped)
    }

    /// How long after a change the app's own reading leaves it for the change's event to tell.
    /// The event's release carries the key typed under the chord, and the app's reading
    /// answers no change, so it can place none: a release it let go of first would be told by
    /// its length, and the event's word would come too late.
    public static let telling: Duration = .milliseconds(100)

    /// The key events that let go of what `session`, read at `time`, no longer holds, once the
    /// session's last change, at `changed`, is `telling` old. They place no typed key, since a
    /// reading of the app's own answers no change. [LAW:single-enforcer]
    public mutating func confirm(session: Set<Modifier>, changed: HostTime, at time: HostTime) -> [KeyEvent] {
        let released = time - changed < Self.telling ? [] : held.subtracting(session)
        released.forEach { letGo[$0] = time }
        return move(to: held.subtracting(released), at: time, lastTyped: nil)
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
    /// A state that did not change is no events at all, so a state told twice is told once.
    /// A state that moved by several keys at once, because the changes in between were never
    /// heard, is every key that came up and then one key down carrying the whole state: keys
    /// that went down together were never seen held apart, so no chord that some of them make
    /// is completed on the way to the one they make together.
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
