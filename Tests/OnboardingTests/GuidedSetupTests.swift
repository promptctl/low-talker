import Foundation
import Grants
import Testing
@testable import Onboarding

/// The guided setup as a person meets it: one requirement at a time, each explained before
/// macOS is asked, and a walk that survives a "no". [LAW:behavior-not-structure]
@Suite struct GuidedSetupTests {
    // MARK: - the words before the dialog

    /// Every step says what it is for and what happens if you skip it, before anything is
    /// asked of macOS. A step missing either is the unexplained prompt this setup exists to
    /// replace.
    @Test(arguments: Requirement.Row.allCases)
    func everyStepExplainsWhyAndWhatSkippingCosts(row: Requirement.Row) {
        let explanation = row.explanation
        for (part, text) in [("why", explanation.why), ("if skipped", explanation.ifSkipped)] {
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(row.rawValue) has no \(part)")
        }
    }

    /// Every step's button says a dialog follows.
    @Test(arguments: Requirement.Row.allCases)
    func everyAskButtonSaysADialogFollows(row: Requirement.Row) {
        #expect(row.askTitle.hasSuffix("…"), "\(row.rawValue)'s button does not say a dialog follows")
    }

    /// Every grant a person can switch by hand has the pane it is switched in, which is
    /// where a person goes after declining a dialog macOS will not show twice.
    @Test func everyGrantOpensTheExactPaneItIsSwitchedIn() {
        #expect(Requirement.Row.microphone.settingsPane.absoluteString.hasSuffix("Privacy_Microphone"))
        #expect(Requirement.Row.inputMethod.settingsPane.absoluteString.hasSuffix("com.apple.Keyboard-Settings.extension"))
    }

    // MARK: - the input method's dialog, which returns

    /// Only the input method is re-askable. macOS shows the microphone's dialog once per app,
    /// so its button is spent after one press and the page sends the person to System
    /// Settings; the input method's dialog comes back on the next press (measured on
    /// studious 2026-09-27), so its button must stay and it must never get the "asks only
    /// once" line. A row landing on the wrong side of this is the exact defect ssn fixes.
    @Test func onlyTheInputMethodIsReAskable() {
        for row in Requirement.Row.allCases {
            #expect(row.reAskable == (row == .inputMethod), "\(row.rawValue)")
        }
    }

    /// Only the input method carries a switch-on note. The microphone's asking is fully
    /// covered by the generic once-asked line, so a note on them would be a second, competing voice.
    @Test func onlyTheInputMethodCarriesASwitchOnNote() {
        for row in Requirement.Row.allCases {
            #expect((row.switchOnNote != nil) == (row == .inputMethod), "\(row.rawValue)")
        }
    }

    /// The note names what a person cannot see coming: that declining is not the end because
    /// the dialog returns, and, when no dialog comes, the button on this page that leads on.
    /// [LAW:no-silent-failure]
    @Test func theInputMethodNoteNamesTheReturningDialogAndTheWayOnWithoutIt() throws {
        let note = try #require(Requirement.Row.inputMethod.switchOnNote)
        #expect(note.contains("Allow"), "the note never names the dialog to allow it")
        #expect(note.contains("again"), "the note never says the dialog returns after a No")
        #expect(note.contains(GuidedSetup.openSettingsTitle), "the note never names the button that leads on when no dialog comes")
    }

    /// No words Onboarding writes for a step ask the person to log out or restart: an install
    /// that needed one would have broken a macOS rule, and the fix is the install, not words
    /// sending the person away.
    @Test func noStepAsksForALogoutOrARestart() {
        let shown: [String?] = Requirement.all.flatMap { [$0.name, $0.reads, $0.step] as [String?] }
            + Requirement.Row.allCases.flatMap { [$0.explanation.why, $0.explanation.ifSkipped, $0.askTitle, $0.switchOnNote] as [String?] }
        for text in shown.compactMap({ $0?.lowercased() }) {
            for asking in ["log out", "logout", "log back in", "next login", "restart", "reboot"] {
                #expect(!text.contains(asking), "\"\(text)\" asks for a \(asking)")
            }
        }
    }

    /// A note that tells the person to press the button again is claiming the same fact
    /// `reAskable` carries, so the two may not drift: were `reAskable` ever flipped off
    /// while the note kept saying "again", the page would hide the button the note still
    /// tells them to press. Ties the prose to the boolean, which nothing else does.
    @Test func aNotePromisingAnotherPressIsOnlyOnAReAskableRow() {
        for row in Requirement.Row.allCases where row.switchOnNote?.contains("again") == true {
            #expect(row.reAskable, "\(row.rawValue)'s note says to press again but the row is not re-askable")
        }
    }

    // MARK: - the walk

    static let unmetMicrophone = Requirement.microphone(.notDetermined)
    static let unmetInputMethod = Requirement.inputMethod(switchedOn: false)
    static let readiness = Readiness([unmetMicrophone, unmetInputMethod])

    /// One step at a time, in the list's order, and never a step that is already met.
    @Test func theWalkShowsTheFirstUnmetRequirement() {
        #expect(GuidedSetup().current(in: Self.readiness)?.row == .microphone)
    }

    /// Declining moves the walk on without ending it, and the declined step is the one
    /// the summary brings back.
    @Test func skippingMovesOnAndRevisitingComesBack() {
        var walk = GuidedSetup()
        walk.skip(.microphone)
        #expect(walk.current(in: Self.readiness)?.row == .inputMethod)
        walk.skip(.inputMethod)
        #expect(walk.current(in: Self.readiness) == nil)
        walk.revisit(.microphone)
        #expect(walk.current(in: Self.readiness)?.row == .microphone)
    }

    /// A grant given in System Settings clears its step at the next reading: the walk keeps
    /// no answer of its own, so a fresh list with the grant met moves it on.
    @Test func aGrantMadeElsewhereClearsItsStepAtTheNextReading() {
        let granted = Readiness([.microphone(nil), Self.unmetInputMethod])
        #expect(GuidedSetup().current(in: granted)?.row == .inputMethod)
    }

    // MARK: - the row only the app reads

    /// Each way macOS can withhold the microphone reads as its own word and asks for its
    /// own step; allowed asks for nothing.
    @Test func everyMicrophoneAnswerReadsAsItsOwnWord() {
        let answers: [MicrophoneAuthorization.Withheld?] = [nil] + MicrophoneAuthorization.Withheld.allCases
        let rows = answers.map { Requirement.microphone($0) }
        #expect(Set(rows.map(\.reads)).count == answers.count)
        #expect(rows.map(\.met) == [true, false, false, false])
        #expect(Requirement.microphone(.denied).step?.contains("Privacy & Security > Microphone") == true)
    }
}
