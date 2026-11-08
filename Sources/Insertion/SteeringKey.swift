import AppKit

/// A key the input method reports to the app, and the keys that steer dictation: the one place that
/// says which keys those are. Every other key is declined as it always was.
///
/// Lives in `Insertion` because both ends name it: the input method reports and holds these keys,
/// and the app says what each one does.
///
/// [LAW:parse-dont-validate] A key either is one of these, with the proof in the type, or is nil
/// here and nothing downstream asks again. [LAW:one-source-of-truth] Adding a case is the one
/// change: the compiler then asks each switch over it what the new key does.
public nonisolated enum SteeringKey: Codable, Equatable, Sendable, CustomStringConvertible {
    /// Return, or the keypad's Enter, with no modifier.
    case `return`
    /// Escape, with whatever is held: a held chord is a modifier on it, and this process cannot
    /// tell the chord from any other modifier, so the app decides whether a dictation is open to
    /// cancel and the Escape goes to the app as typed when none is.
    case escape

    /// The key as the log names it.
    public var description: String {
        switch self {
        case .return: "Return"
        case .escape: "Escape"
        }
    }

    /// The modifiers that make a Return another key. Option+Return is a newline in a terminal
    /// and Shift+Return one in a chat box; Fn is a chord a person can choose, and a Return under
    /// the chord is the chord's, not bare. Caps lock and the numeric pad flag, which keypad
    /// Enter carries, make nothing else of it.
    private static let makeAnotherKey: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]

    /// Whether a Return held with `flags` is another key, which passes as typed, rather than a bare
    /// Return that steers. [LAW:single-enforcer] The one rule for it; the input method asks here.
    public static func makesAnotherKey(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.isDisjoint(with: makeAnotherKey)
    }
}
