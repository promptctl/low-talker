/// A modifier key going down or up, with what the keyboard held once it had, and when a key
/// was last typed.
///
/// [LAW:one-source-of-truth] `modifiers` is the whole modifier state as the event
/// reports it, not a running tally kept here: a tally would drift the first time an
/// event was missed, and nothing could tell it had. `lastTyped` is the session's own
/// record, read with `modifiers`, for the same reason.
public struct KeyEvent: Hashable, Sendable {
    public enum Direction: Hashable, Sendable {
        case down, up
    }

    public let key: Modifier
    public let direction: Direction
    /// Every modifier held after this event.
    public let modifiers: Set<Modifier>
    /// When the key moved.
    public let time: HostTime
    /// When a key that is not a modifier last went down before this key moved: what tells a
    /// chord pressed alone from a chord held as the modifier of a typed key, which the input
    /// method is never handed. Nil when the reading cannot place one before the move: the
    /// session keeps only its latest key, so one typed since hides any before, and the app's
    /// own reading answers no move.
    public let lastTyped: HostTime?

    public init(key: Modifier, direction: Direction, modifiers: Set<Modifier>, time: HostTime, lastTyped: HostTime?) {
        self.key = key
        self.direction = direction
        self.modifiers = modifiers
        self.time = time
        self.lastTyped = lastTyped
    }
}

extension KeyChord {
    /// Whether `key` going down, leaving `held` as the modifiers, is this chord being
    /// pressed: a chord completes on whichever of its modifiers comes down last.
    func isCompleted(by key: Modifier, holding held: Set<Modifier>) -> Bool {
        held == modifiers && modifiers.contains(key)
    }

    /// Whether `key` going down would have completed this chord, but for other modifiers
    /// already held with it.
    func isBlocked(by key: Modifier, holding held: Set<Modifier>) -> Bool {
        held.isStrictSuperset(of: modifiers) && modifiers.contains(key)
    }
}

/// Finds presses of the configured modes' chords in the keyboard's events, and tells a
/// hold from a tap.
///
/// A press begins the moment a chord is completed, so listening starts on key-down, in the
/// mode that chord selects. [LAW:one-source-of-truth] Only the event that begins a press
/// names its mode, so a config saved before the press reaches its handler cannot hand it
/// another mode's vocabulary, and its end cannot name a mode it did not begin in.
/// Releasing within `tapThreshold` makes it a tap: listening stays on, latched,
/// until the next chord press ends it. Releasing later makes it a hold, which ends
/// as the key comes up. The chord that began a press owns it: modifiers added during a
/// hold change nothing, and the press ends when any key of its chord comes up. A key typed
/// while the chord was down makes it neither: the chord was that key's modifier, and the
/// press ends as the chord comes up, however long it was down. A chord pressed with other
/// modifiers already held begins no press, and is told as blocked, so the person learns it at
/// the chord rather than after speaking into it; it never latches, since nothing listens.
///
/// [LAW:effects-at-boundaries] A value with no clock and no feed. Time comes in on
/// each event, so a test drives it with timestamps of its choosing.
public struct HotkeyDetector: Sendable {
    public enum Transition: Hashable, Sendable {
        /// The chord went down at this moment; listening begins there rather than
        /// wherever the handler happens to run, which is later by however late the
        /// event was delivered.
        case began(Mode, at: HostTime)
        /// The chord went down with these other modifiers already held, so no listening
        /// begins. [LAW:no-silent-failure] It is told rather than ignored, and ended like a
        /// press, so whatever shows it is shown while the chord is down and no longer.
        case blocked(Mode, by: Set<Modifier>)
        /// Listening ends, and why. Only one press is ever open, so this ends that one.
        case ended(Ending)
    }

    /// What stopped the listening: the speaker let go, the chord turned out to be a typed
    /// key's modifier, or the hotkey stopped hearing and the press was ended without them.
    ///
    /// [LAW:types-are-the-program] Three facts a caller could never pull back apart if
    /// they shared a value - "that was the whole utterance", "there was no utterance" and
    /// "that is as much of it as reached us". Only a release carries a press kind, because
    /// a tap and a hold are told apart by how long the key was down and only a release has
    /// the key-up that measures it. Only a release carries a moment, the stamp of the event
    /// that ended it, for the same reason `began` carries one; the other endings insert
    /// nothing more, so no moment times anything after them.
    public enum Ending: Hashable, Sendable, CustomStringConvertible {
        /// The key came up on a hold, or the chord went down again on a latched tap, at
        /// this moment.
        case released(PressKind, at: HostTime)
        /// The hotkey stopped hearing while the press was open. Nothing was heard past the
        /// last event it was told, and whether the speaker had even finished is unknown.
        case lapsed
        /// The chord came up after a key was typed while it was down: it was that key's
        /// modifier - Option for a special character, Meta in a terminal - and the press was
        /// never dictation.
        case usedAsModifier

        /// An ending in a person's words. A case added here has to say what it is before
        /// it compiles, so nothing prints an ending it has no word for.
        public var description: String {
            switch self {
            case .released(let kind, _): kind.rawValue
            case .lapsed: "lapsed"
            case .usedAsModifier: "used as a modifier"
            }
        }
    }

    public enum Phase: Hashable, Sendable {
        case idle
        /// The chord is down and the press is not yet known to be a hold or a tap.
        case held(KeyChord, since: HostTime)
        /// The chord is down with other modifiers held with it, so nothing is listening.
        case blocked(KeyChord, since: HostTime)
        /// A tap left listening on; the next press of its chord, or of any chord listened
        /// for, ends it.
        case latched(KeyChord)
    }

    public private(set) var modes: Modes
    /// A press released before this long is a tap.
    public let tapThreshold: Duration
    public private(set) var phase: Phase = .idle

    public init(modes: Modes, tapThreshold: Duration) {
        precondition(tapThreshold > .zero, "a tap is a press shorter than something; zero makes every press a hold")
        self.modes = modes
        self.tapThreshold = tapThreshold
    }

    /// The transition `event` makes, if it makes one.
    public mutating func handle(_ event: KeyEvent) -> Transition? {
        switch event.direction {
        case .down: down(of: event)
        case .up: up(of: event)
        }
    }

    /// A press is only ever begun from rest: while a chord is held, another chord
    /// completed on top of it (Right Option held, Shift added) changes nothing.
    private mutating func down(of event: KeyEvent) -> Transition? {
        // At most one mode's chord completes on one event, since two chords with the same
        // modifiers are one chord and no two modes share one.
        let completed = modes.first { $0.chord.isCompleted(by: event.key, holding: event.modifiers) }
        // Of the chords the extra modifiers block, the one with the most keys is the one
        // the person was reaching for.
        let blocked = modes.filter { $0.chord.isBlocked(by: event.key, holding: event.modifiers) }
            .max { $0.chord.modifiers.count < $1.chord.modifiers.count }
        switch (phase, completed, blocked) {
        case (.idle, let mode?, _):
            phase = .held(mode.chord, since: event.time)
            return .began(mode, at: event.time)
        case (.idle, nil, let mode?):
            phase = .blocked(mode.chord, since: event.time)
            return .blocked(mode, by: event.modifiers.subtracting(mode.chord.modifiers))
        // Its own chord ends it too, listened for or not: the press belongs to the chord that
        // began it, so a chord moved by `listen(for:)` mid-latch still ends what it started.
        // Pressed with other modifiers held, it still ends it, since the person was reaching
        // for it to stop listening.
        case (.latched(let chord), _, _) where completed != nil || chord.isCompleted(by: event.key, holding: event.modifiers) || chord.isBlocked(by: event.key, holding: event.modifiers):
            phase = .idle
            return .ended(.released(.tap, at: event.time))
        case (.held, _, _), (.blocked, _, _), (.latched, _, _), (.idle, nil, nil):
            return nil
        }
    }

    private mutating func up(of event: KeyEvent) -> Transition? {
        // A typed key the session's record hides leaves the press told by its length, as
        // every press was before the record was read.
        func typedUnder(since: HostTime) -> Bool { event.lastTyped.map { since < $0 } ?? false }
        func kind(since: HostTime) -> PressKind { event.time - since < tapThreshold ? .tap : .hold }
        switch phase {
        case .held(let chord, let since) where chord.modifiers.contains(event.key):
            switch (typedUnder(since: since), kind(since: since)) {
            case (true, _):
                phase = .idle
                return .ended(.usedAsModifier)
            case (false, .tap):
                phase = .latched(chord)
                return nil
            case (false, .hold):
                phase = .idle
                return .ended(.released(.hold, at: event.time))
            }
        case .blocked(let chord, let since) where chord.modifiers.contains(event.key):
            phase = .idle
            return .ended(typedUnder(since: since) ? .usedAsModifier : .released(kind(since: since), at: event.time))
        case .held, .blocked, .latched, .idle:
            return nil
        }
    }

    /// Listens for `modes` from the next press on. A press already open is left open: it
    /// belongs to the chord that began it, and ends the way it would have, when a key of that
    /// chord comes up or, latched, when that chord or one now listened for goes down.
    public mutating func listen(for modes: Modes) {
        self.modes = modes
    }

    /// The hotkey stopped hearing: the open press ends, since its release can no longer
    /// arrive.
    ///
    /// A hold and a latched tap end the same way here, because what ends them is the
    /// same thing and it is not the speaker. Naming one `.hold` and the other `.tap`
    /// was the invention this ending exists to stop.
    public mutating func lapse() -> Transition? {
        let transition: Transition? = switch phase {
        case .idle: nil
        case .held, .blocked, .latched: .ended(.lapsed)
        }
        phase = .idle
        return transition
    }
}
