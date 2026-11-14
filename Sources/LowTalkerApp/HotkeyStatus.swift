import Foundation
import Identity
import InputSource

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

    /// The line for the input method's process as it stands: how to press, only while an input
    /// method of whatever build is running to type the words, and otherwise why nothing is typed.
    @MainActor public static func showing(_ standing: InputMethodStanding, listening: @autoclosure () -> String) -> HotkeyStatus {
        switch standing {
        case .running: .listening(listening())
        case .ended: .off("the input method ended; \(AppIdentity.displayName) is starting it again")
        case .overMemoryCeiling(_, let overrun):
            .off("the input method is ending itself, \(overrun); \(AppIdentity.displayName) will start it again")
        case .notOpened(let reason):
            .off("the input method could not be started: \(reason); trying again every \(InputMethodSupervisor.throttleInterval.formatted(.units(width: .wide)))")
        }
    }
}

/// Why the loop is not working, in the words the status line says it.
/// Named apart from `Insertion.Refusal`, which is the input method's answer to an insert.
struct LoopRefusal: Error, ExpressibleByStringInterpolation {
    let reason: String
    init(stringLiteral reason: String) { self.reason = reason }
}
