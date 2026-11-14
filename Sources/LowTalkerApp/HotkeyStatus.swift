/// What the menu says after "Hotkey: ".
public enum HotkeyStatus: Equatable, Sendable, CustomStringConvertible {
    case starting(step: String?)
    /// Listening, and how to press it.
    case listening(String)
    /// Not listening, for this reason.
    case off(String)

    public var description: String {
        switch self {
        case .starting(nil): "starting…"
        case .starting(let step?): "starting — \(step)"
        case .listening(let howToPress): howToPress
        case .off(let reason): "off — \(reason)"
        }
    }

    /// Whether the hotkey is listening, which is what lets the word box offer Insert.
    public var isListening: Bool {
        if case .listening = self { true } else { false }
    }
}

/// Why the loop is not working, in the words the status line says it.
/// Named apart from `Insertion.Refusal`, which is the input method's answer to an insert.
struct LoopRefusal: Error, ExpressibleByStringInterpolation {
    let reason: String
    init(stringLiteral reason: String) { self.reason = reason }
}
