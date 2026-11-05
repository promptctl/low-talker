import AppKit
import Carbon.HIToolbox

/// A key that steers dictation instead of passing through to the app: the one place that says
/// which keys those are. Every other key is declined as it always was.
///
/// [LAW:parse-dont-validate] A key either is a steering key, with the proof in the type, or is
/// nil here and nothing downstream asks again.
public nonisolated enum SteeringKey: Equatable, Sendable, CustomStringConvertible {
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

    public init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard flags.isDisjoint(with: Self.makeAnotherKey) else { return nil }
            self = .return
        case kVK_Escape: self = .escape
        default: return nil
        }
    }
}
