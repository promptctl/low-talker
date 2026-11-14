import AVFoundation
import Grants
import GrantsFakes
import Testing
@testable import Onboarding

/// The list itself, as the app gets it. The menu and the guided setup are two views of
/// one assembly, and what is checked here is the part neither of them may quietly disagree
/// about: which requirements are in the list, and in what order.
/// [LAW:behavior-not-structure]
@Suite struct ReadinessTests {
    /// Every row is read, in the one order.
    @Test func theAppReadsEveryRowInOrder() {
        let readiness = OnboardingProbe.readiness(microphone: .withheld(.notDetermined), inputMethodSwitchedOn: false)
        #expect(readiness.requirements.map(\.row) == Requirement.Row.allCases)
    }

    /// The microphone row reads the authorization the app handed over.
    @Test func theAppsMicrophoneRowReadsWhatItWasGiven() {
        func microphoneRow(_ reason: MicrophoneAuthorization.Withheld) -> Requirement? {
            OnboardingProbe.readiness(microphone: .withheld(reason), inputMethodSwitchedOn: true)
                .requirements.first { $0.row == .microphone }
        }
        #expect(microphoneRow(.notDetermined)?.reads == "not asked yet")
        #expect(microphoneRow(.denied)?.reads == "turned off")
        #expect(microphoneRow(.restricted)?.met == false)
        let granted = OnboardingProbe.readiness(microphone: MicrophonePermission(authority: FakeMicrophoneAuthority()).current, inputMethodSwitchedOn: true)
        #expect(granted.requirements.first { $0.row == .microphone }?.met == true)
    }

    /// The input method row reads the switch the app handed over.
    @Test func theInputMethodRowReadsWhatItWasGiven() {
        func met(switchedOn: Bool) -> Bool? {
            OnboardingProbe.readiness(microphone: .withheld(.denied), inputMethodSwitchedOn: switchedOn)
                .requirements.first { $0.row == .inputMethod }?.met
        }
        #expect(met(switchedOn: true) == true)
        #expect(met(switchedOn: false) == false)
    }
}

