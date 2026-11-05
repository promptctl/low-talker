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
/// until the next chord press ends it; another mode's chord ends it and begins that mode's
/// press on the same key-down. Releasing later makes it a hold, which ends
/// as the key comes up. The chord that began a press owns it: modifiers added during a
/// hold change nothing, and the press ends when any key of its chord comes up. A key typed
/// while the chord was down makes it neither: the chord was that key's modifier, and the
/// press ends as the chord comes up, however long it was down. A chord pressed with other
/// modifiers already held begins no press, and is told as blocked; it never latches, since nothing listens.
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
        /// begins. [LAW:no-silent-failure] It is told rather than ignored, so the log records
        /// the chord that began no press, and it is ended like a press so the loop accounts
        /// for the key-up that follows. Nothing in the app displays it: a chord over a held
        /// modifier is that modifier's own use, not dictation.
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
        /// A key typed while the press was open threw it away: Escape. Held or latched, the press
        /// ends at once, and the chord's own release after it ends nothing.
        case cancelled

        /// An ending in a person's words. A case added here has to say what it is before
        /// it compiles, so nothing prints an ending it has no word for.
        public var description: String {
            switch self {
            case .released(let kind, _): kind.rawValue
            case .lapsed: "lapsed"
            case .usedAsModifier: "used as a modifier"
            case .cancelled: "cancelled"
            }
        }
    }

    public enum Phase: Hashable, Sendable {
        case idle
        /// The chord is down and the press is not yet known to be a hold or a tap.
        case held(Mode, since: HostTime)
        /// The chord is down with other modifiers held with it, so nothing is listening.
        case blocked(KeyChord, since: HostTime)
        /// A tap left listening on in this mode; the next press of its chord, or of any chord
        /// listened for, ends it.
        case latched(Mode)
        /// Escape threw a held press away while its chord was still down: nothing is listening
        /// until a key of the chord comes up, and its release ends nothing.
        case cancelled(KeyChord)
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

    /// The transitions `event` makes, in the order they happen: none, one, or a latched tap's
    /// end followed by the press that ended it.
    public mutating func handle(_ event: KeyEvent) -> [Transition] {
        switch event.direction {
        case .down: down(of: event)
        case .up: up(of: event)
        }
    }

    /// A press is begun from rest or from a latched tap: while a chord is held, another chord
    /// completed on top of it (Right Option held, Shift added) changes nothing.
    private mutating func down(of event: KeyEvent) -> [Transition] {
        // At most one mode's chord completes on one event, since two chords with the same
        // modifiers are one chord and no two modes share one.
        let completed = modes.first { $0.chord.isCompleted(by: event.key, holding: event.modifiers) }
        // Of the chords the extra modifiers block, the one with the most keys is the one
        // the person was reaching for.
        let blocked = modes.filter { $0.chord.isBlocked(by: event.key, holding: event.modifiers) }
            .max { $0.chord.modifiers.count < $1.chord.modifiers.count }
        switch (phase, completed, blocked) {
        case (.idle, let mode?, _):
            phase = .held(mode, since: event.time)
            return [.began(mode, at: event.time)]
        case (.idle, nil, let mode?):
            phase = .blocked(mode.chord, since: event.time)
            return [.blocked(mode, by: event.modifiers.subtracting(mode.chord.modifiers))]
        // A chord a mode is listened for under decides what it does to a latched tap, as it
        // decides a press from rest: its own mode's chord, moved by `listen(for:)` or not, ends
        // it, and so do the keys that began it, whichever mode a save gave them to (a renamed
        // mode among them), since the person tapped them to start and taps them to stop.
        // Another mode's chord ends it and begins that mode's press, since the person
        // switched modes and is speaking into the one they pressed.
        case (.latched(let latched), let mode?, _) where mode.name == latched.name || mode.chord == latched.chord:
            phase = .idle
            return [.ended(.released(.tap, at: event.time))]
        case (.latched, let mode?, _):
            phase = .held(mode, since: event.time)
            return [.ended(.released(.tap, at: event.time)), .began(mode, at: event.time)]
        // The chord that began it ends it even when no mode is listened for under it now, and
        // pressed with other modifiers held, since the person was reaching for it to stop.
        case (.latched(let latched), nil, _) where latched.chord.isCompleted(by: event.key, holding: event.modifiers) || latched.chord.isBlocked(by: event.key, holding: event.modifiers):
            phase = .idle
            return [.ended(.released(.tap, at: event.time))]
        case (.held, _, _), (.blocked, _, _), (.cancelled, _, _), (.latched, nil, _), (.idle, nil, nil):
            return []
        }
    }

    private mutating func up(of event: KeyEvent) -> [Transition] {
        // A typed key the session's record hides leaves the press told by its length, as
        // every press was before the record was read.
        func typedUnder(since: HostTime) -> Bool { event.lastTyped.map { since < $0 } ?? false }
        func kind(since: HostTime) -> PressKind { event.time - since < tapThreshold ? .tap : .hold }
        switch phase {
        case .held(let mode, let since) where mode.chord.modifiers.contains(event.key):
            switch (typedUnder(since: since), kind(since: since)) {
            case (true, _):
                phase = .idle
                return [.ended(.usedAsModifier)]
            case (false, .tap):
                phase = .latched(mode)
                return []
            case (false, .hold):
                phase = .idle
                return [.ended(.released(.hold, at: event.time))]
            }
        case .blocked(let chord, let since) where chord.modifiers.contains(event.key):
            phase = .idle
            return [.ended(typedUnder(since: since) ? .usedAsModifier : .released(kind(since: since), at: event.time))]
        case .cancelled(let chord) where chord.modifiers.contains(event.key):
            phase = .idle
            return []
        case .held, .blocked, .cancelled, .latched, .idle:
            return []
        }
    }

    /// What a typed key does to dictation: Return sends what was said, Escape throws it away.
    public enum Steering: Equatable, Sendable {
        /// Return, typed at this moment: a latched press ends there, and one still held is left
        /// to end as the chord comes up.
        case send(at: HostTime)
        /// Escape: a held or latched press is thrown away where it stands.
        case cancel
    }

    /// What a typed key that steers dictation did to the press, as the detector reads it.
    public enum Steered: Equatable, Sendable {
        /// The press ended where the key was typed, which is this transition. The next chord
        /// press begins a fresh one.
        case ended(Transition)
        /// The chord is still down as far as the detector has heard: a key typed in the moment
        /// before the chord's release is heard. The press is open and ends as the chord comes
        /// up, so nothing was ended here.
        case chordDown
        /// No press is open for a key to steer, or the one that was is not dictation.
        case nothingOpen
    }

    /// A key that steers dictation was typed. A latched press ends where Return was typed, as a
    /// tap does when the chord is pressed again, and the audio is cut at the key, not at the
    /// moment the app learned of it; Escape ends a held or latched press as cancelled, and the
    /// chord's release after it ends nothing.
    ///
    /// [LAW:single-enforcer] Only the detector ends a press, so `Dictation.press` still sees every
    /// `began` paired with one `ended`, and a latched press left latched cannot have the next chord
    /// press end one that no longer exists.
    public mutating func steer(_ steering: Steering) -> Steered {
        switch (steering, phase) {
        case (.send(let time), .latched):
            phase = .idle
            return .ended(.ended(.released(.tap, at: time)))
        case (.send, .held):
            return .chordDown
        case (.cancel, .latched):
            phase = .idle
            return .ended(.ended(.cancelled))
        case (.cancel, .held(let mode, _)):
            phase = .cancelled(mode.chord)
            return .ended(.ended(.cancelled))
        case (_, .blocked), (_, .cancelled), (_, .idle):
            return .nothingOpen
        }
    }

    /// Listens for `modes` from the next press on. A press already open is left open: it
    /// belongs to the chord that began it, and ends the way it would have, when a key of that
    /// chord comes up or, latched, when that chord or its mode's chord now goes down; any
    /// other mode's chord begins that mode's press as it ends this one.
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
        case .idle, .cancelled: nil
        case .held, .blocked, .latched: .ended(.lapsed)
        }
        phase = .idle
        return transition
    }
}

/// [LAW:nothing-unseen] A transition as the hotkey's log line says it, with the key event's
/// own stamp, so a latched tap ended by another mode's chord reads as that end and that mode's
/// beginning at one moment.
extension HotkeyDetector.Transition: CustomStringConvertible {
    public var description: String {
        func moment(_ time: HostTime) -> String { "at \(time.uptime / .milliseconds(1)) ms of uptime" }
        return switch self {
        case .began(let mode, let at): "\(mode) began \(moment(at))"
        case .blocked(let mode, let others): "\(mode) blocked by \(Hotkey.named(others)) held with it"
        case .ended(.released(let kind, let at)): "ended as a \(kind.rawValue) \(moment(at))"
        case .ended(let ending): "ended \(ending)"
        }
    }
}
