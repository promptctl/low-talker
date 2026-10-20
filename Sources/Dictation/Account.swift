import Insertion
import LowTalkerCore

extension NoMicrophone: WordFree {}
extension SerialQueueError: WordFree {}

// An enum whose cases could one day carry the words names each case, so a case added
// to it does not compile until it has said what it carries.

extension InsertFailure: Accounted {
    public var account: Account {
        switch self {
        case .refused, .notYetTaken, .unreachable, .answererUnreadable, .buildMismatch: Account(facts: description)
        }
    }
}

/// The engine was not there for a press: its model failed to load.
///
/// Word-free: the engine is asked for before it is handed any of the press's audio, so
/// nothing it says can be a reading of what was dictated.
public struct EngineUnavailable: WordFree {
    public let cause: any Error

    public init(_ cause: any Error) {
        self.cause = cause
    }

    public var description: String { "\(cause)" }
}

/// A chord pressed with other modifiers already held with it, which begins no press.
///
/// Word-free: it is told at the chord, before anything is said.
public struct ChordBlocked: WordFree {
    public let chord: KeyChord
    public let others: Set<Modifier>

    public init(chord: KeyChord, others: Set<Modifier>) {
        self.chord = chord
        self.others = others
    }

    /// True while the chord is down, on the panel, and once it is up, in the menu.
    public var description: String {
        let pressed = Hotkey.named(chord)
        return "WARNING: \(pressed) pressed with \(Hotkey.named(others)) held begins no dictation. Press \(pressed) alone."
    }
}
