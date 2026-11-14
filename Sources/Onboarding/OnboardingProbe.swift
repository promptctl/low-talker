import Grants

/// What the readings of this Mac make of the list.
///
/// [LAW:effects-at-boundaries] Each reading is an effect the caller makes, handed in here as a
/// value, so the steps can be asserted as values on a Mac that is in none of the states worth
/// checking.
public enum OnboardingProbe {
    /// Everything that must hold before low-talker can hear and type, read off this Mac now.
    ///
    /// The list is assembled here and nowhere else. The menu-bar app and its guided setup
    /// are views of one list rather than lists that happen to agree, and a surface that built
    /// its own would drift the first time a requirement was added to only one of them.
    /// [LAW:one-source-of-truth]
    ///
    /// Reading never asks: nothing here can put a system dialog on screen, which is what
    /// lets the app read the list at launch and every time its menu opens.
    ///
    /// - Parameters:
    ///   - microphone: the app's microphone, as its own process reads it. macOS keys the grant
    ///     to the app that holds it, so only the app's own reading is the app's.
    ///   - inputMethodSwitchedOn: whether a person has switched the input method on.
    public static func readiness(microphone: MicrophoneAuthorization, inputMethodSwitchedOn: Bool) -> Readiness {
        let withheld: MicrophoneAuthorization.Withheld? = switch microphone {
        case .granted: nil
        case .withheld(let reason): reason
        }
        return Readiness(Requirement.Row.allCases.map { row in
            switch row {
            case .microphone: .microphone(withheld)
            case .inputMethod: .inputMethod(switchedOn: inputMethodSwitchedOn)
            }
        })
    }
}
