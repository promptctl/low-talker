import AppKit
import Carbon.HIToolbox

/// The keys that steer dictation: the one place that says which keys those are. Every other key is
/// declined as it always was.
///
/// [LAW:parse-dont-validate] A key either is one of these, with the proof in the type, or is nil
/// here and nothing downstream asks again. [LAW:one-source-of-truth] Adding a case is the one
/// change: the compiler then asks each switch over it what the new key does.
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

    /// The steering key typed, from the key and the modifiers held with it, or nil for every other
    /// key, which is declined as typed. [LAW:single-enforcer] The one place a key becomes a steering
    /// key; the input method asks here and nowhere else.
    ///
    /// Known by the key, not the command a key binding names it: AppKit binds Option+Escape to
    /// `complete:` and a person's own key bindings can bind Escape to anything, and an Escape under
    /// the chord is still the Escape that cancels the press.
    public init?(keyCode: UInt16, holding modifiers: NSEvent.ModifierFlags) {
        let bare = modifiers.isDisjoint(with: Self.makeAnotherKey)
        switch Int(keyCode) {
        // Each pattern carries its own condition: a `where` binds only to the pattern it follows.
        case kVK_Return where bare, kVK_ANSI_KeypadEnter where bare: self = .return
        case kVK_Escape: self = .escape
        default: return nil
        }
    }

    /// The modifiers that make a Return another key. Option+Return is a newline in a terminal
    /// and Shift+Return one in a chat box; Fn is a chord a person can choose, and a Return under
    /// the chord is the chord's, not bare. Caps lock and the numeric pad flag, which keypad
    /// Enter carries, make nothing else of it.
    private static let makeAnotherKey: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]
}
