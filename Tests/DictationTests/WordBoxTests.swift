@testable import Dictation
import Insertion
import LowTalkerCore
import Synchronization
import Testing

/// A panel that keeps what it was told to show, in order.
@MainActor
final class StubPanel: WordBoxPanel {
    enum Shown: Equatable {
        case face(WordBox.Face)
        case away
    }

    private(set) var shown: [Shown] = []

    /// The face on screen, nil once the box is put away or before it is shown.
    var face: WordBox.Face? {
        if case .face(let face)? = shown.last { face } else { nil }
    }

    func draw(_ face: WordBox.Face) { shown.append(.face(face)) }
    func hide() { shown.append(.away) }
}

/// A press as the hold tells its words apart, which a test throws away as an Escape does.
final class Speaker: Held.Owner {
    private let thrown = Mutex(false)
    var cancelled: Bool { thrown.withLock { $0 } }
    func throwAway() { thrown.withLock { $0 = true } }
}

/// When the word box is on screen and what it offers, over a real hold kept in memory, which
/// shows the box with the loop's activity as it changes, as the app's does.
/// [LAW:behavior-not-structure] What the panel is told to draw, and where the held words are.
@MainActor
@Suite final class WordBoxTests {
    private let panel = StubPanel()
    private lazy var box = WordBox(panel: panel)
    private var activity = Dictation.Activity.idle
    private let ready = EngineReadiness.ready(.default, after: .seconds(1))
    private lazy var hold = Hold(store: FakeHeldStore(keeping: Self.earlier), failedToKeep: { _ in }, showing: { [unowned self] in
        box.show(activity, over: ready, held: $0.held, insertable: true)
    })
    private static let earlier = Held.unplaced(part(" earlier words", "WARNING: no text field took them"))

    /// The loop doing `activity`, shown with what the hold holds.
    private func show(_ activity: Dictation.Activity, insertable: Bool = true) {
        self.activity = activity
        box.show(activity, over: ready, held: hold.held, insertable: insertable)
    }

    private static func listening(_ typed: String) -> Dictation.Activity {
        .listening(heard: Transcript(typed: typed))
    }

    /// Not drawn even as the hold lets go, when it shows the box what it holds after.
    @Test func aDismissalPutsTheBoxAwayAndLetsGoOfTheHeldWords() {
        show(Self.listening(" hi"))
        #expect(panel.face != nil)
        let before = panel.shown.count

        box.dismiss(cancelling: nil, hold: hold)

        #expect(panel.shown.dropFirst(before).allSatisfy { $0 == .away })
        #expect(panel.shown.last == .away)
        #expect(hold.held == nil)
        #expect(hold.dismissed == Self.earlier)
    }

    /// A cancelled press goes on being heard until its cancellation reaches the loop, then is on
    /// its way out: none of it is a press starting, so the box stays away.
    @Test func aDismissedBoxStaysAwayThroughThePressOpenAtIt() {
        show(Self.listening(" hello"))
        box.dismiss(cancelling: nil, hold: hold)

        for activity in [Self.listening(" hello there"), .transcribing, .idle] {
            show(activity)
            #expect(panel.face == nil, "shown \(activity) after the dismissal")
        }
    }

    /// Escape cannot cancel a refused press, which stays open until its chord comes up.
    @Test func aDismissedRefusedPressStaysAway() {
        show(.refused(why: "no model"))
        box.dismiss(cancelling: nil, hold: hold)

        show(.refused(why: "no model"))

        #expect(panel.face == nil)
    }

    @Test(arguments: [Dictation.Activity.idle, .transcribing])
    func aPressOpeningAfterADismissalShowsTheBoxAgain(before: Dictation.Activity) {
        show(before)
        box.dismiss(cancelling: nil, hold: hold)
        show(before)

        show(Self.listening(" new"))

        #expect(panel.face?.state == "Listening")
        #expect(panel.face?.words == Transcript(typed: " new"))
    }

    private static let refused = "WARNING: no text field took them"

    /// Dismissals that come to hold nothing, each the words of a press then thrown away, dismissed
    /// nothing the person keeps: however many there were, the one before them is still theirs to
    /// bring back.
    @Test func dismissalsOfOnlyThrownWordsLeaveTheOneBefore() {
        let (first, second) = (Speaker(), Speaker())
        box.dismiss(cancelling: nil, hold: hold)
        hold.heldBack(Transcript(typed: " one"), by: first, warning: Self.refused)
        box.dismiss(cancelling: nil, hold: hold)
        hold.heldBack(Transcript(typed: " two"), by: second, warning: Self.refused)
        box.dismiss(cancelling: nil, hold: hold)

        for press in [first, second] {
            press.throwAway()
            #expect(hold.forget(press) == 1)
        }

        #expect(hold.dismissed == Self.earlier)
    }

    /// The words the person asks back come back in the loop's turn, behind every press before:
    /// the box stays away until they are held again, then shows them.
    @Test func aBringBackShowsTheBoxWhenTheWordsAreHeldAgain() {
        show(.idle)
        box.dismiss(cancelling: nil, hold: hold)
        show(.transcribing)
        #expect(panel.face == nil)

        hold.bringBack()

        #expect(panel.face?.words == Self.earlier.allWords)
        #expect(panel.face?.state == "Transcribing")
    }

    /// Words a press the Escape did not throw away holds after the dismissal are new to the person.
    @Test func wordsAnotherPressHoldsAfterADismissalShowTheBox() {
        show(.idle)
        box.dismiss(cancelling: nil, hold: hold)

        hold.heldBack(Transcript(typed: " later"), by: Speaker(), warning: Self.refused)

        #expect(panel.face?.state == nil)
        #expect(panel.face?.words == Transcript(typed: " later"))
        #expect(panel.face?.controls == WordBox.Controls(insert: true, copy: true))
    }

    /// Words read from kept speech after a dismissal show the box, over the press it left on its
    /// way, which offers no Copy while its insert may carry them.
    @Test func wordsRecoveryHoldsAfterADismissalShowTheBox() {
        show(.transcribing)
        box.dismiss(cancelling: nil, hold: hold)
        #expect(panel.face == nil)

        hold.heldBack(Transcript(typed: " recovered"), by: nil, warning: Self.refused)

        #expect(panel.face?.state == "Transcribing")
        #expect(panel.face?.words == Transcript(typed: " recovered"))
        #expect(panel.face?.controls?.copy == false)
    }

    /// An insert the press began before an Escape threw it away hands its words back after: the
    /// hold takes none of them, so the box stays away, whatever is still on its way.
    @Test(arguments: [Dictation.Activity.idle, .transcribing])
    func wordsTheCancelledPressHandsBackKeepTheBoxAway(after delivered: Dictation.Activity) {
        let press = Speaker()
        show(Self.listening(" hello"))
        box.dismiss(cancelling: nil, hold: hold)
        press.throwAway()
        show(delivered)

        hold.heldBack(Transcript(typed: " hello"), by: press, warning: Self.refused)

        #expect(panel.face == nil)
        #expect(hold.held == nil)
    }

    /// Words of a thrown-away press that may have landed may be in the field, so the person is told.
    @Test func wordsTheCancelledPressMayHaveLandedShowTheBox() {
        let press = Speaker()
        show(Self.listening(" hello"))
        box.dismiss(cancelling: nil, hold: hold)
        press.throwAway()
        show(.idle)

        hold.failed(Transcript(typed: " hello"), by: press, with: .unreachable(Unreachable(.noAnswer(port: "port", after: .seconds(1)), at: .words)))

        #expect(panel.face?.words == Transcript(typed: " hello"))
    }

    /// An Escape reaches the press it ends one turn of the main queue later: words held in that
    /// turn wait for the loop to show the press ended, then show the box.
    @Test func wordsHeldWhileTheCancelIsInDeliveryWaitForIt() {
        show(Self.listening(" hello"))
        box.dismiss(cancelling: nil, hold: hold)

        hold.heldBack(Transcript(typed: " first"), by: Speaker(), warning: Self.refused)
        #expect(panel.face == nil)

        show(.idle)
        #expect(panel.face?.words == Transcript(typed: " first"))
    }

    /// A refusal cannot be cancelled, so words held while the dismissed refusal is open wait for
    /// its chord to come up.
    @Test func wordsHeldUnderADismissedRefusalWaitForItToClose() {
        show(.refused(why: "no model"))
        box.dismiss(cancelling: nil, hold: hold)

        hold.heldBack(Transcript(typed: " recovered"), by: nil, warning: Self.refused)
        #expect(panel.face == nil)

        show(.idle)
        #expect(panel.face?.words == Transcript(typed: " recovered"))
    }

    /// The circle, Insert and Copy are there only while words are held, Insert where it is offered
    /// and a loop is listening to insert through, Copy where a click into a field is.
    @Test(arguments: [
        (Dictation.Activity.idle, true, [true, true]),
        (.idle, false, [false, true]),
        (.transcribing, true, [true, false]),
        (.listening(heard: Transcript(typed: " hi")), true, [false, false]),
        (.refused(why: "no model"), true, [false, false]),
    ])
    func theBoxOffersTheCircleInsertAndCopy(activity: Dictation.Activity, insertable: Bool, insertAndCopy: [Bool]) {
        show(activity, insertable: insertable)

        let controls = panel.face?.controls
        #expect(controls.map { [$0.insert, $0.copy] } == insertAndCopy)
    }

    @Test func nothingHeldOffersNoControls() {
        box.show(.transcribing, over: ready, held: nil, insertable: true)

        #expect(panel.face?.state == "Transcribing")
        #expect(panel.face?.controls == nil)
    }

    @Test func nothingOnItsWayAndNothingHeldIsNoBox() {
        box.show(.idle, over: ready, held: nil, insertable: true)

        #expect(panel.shown == [.away])
    }

    /// Each warning is said once, after the symbol that says it is a warning, and the last ends
    /// with what a click into a field places.
    @Test func theWarningsEndWithWhatAClickPlaces() {
        show(.idle)

        #expect(panel.face?.warnings == ["no text field took them Click into a text field to insert these words."])
    }

    /// A refused press is warned of first, and offers no click while it is open.
    @Test func aRefusedPressIsWarnedOfAboveTheHeldWords() {
        show(.refused(why: "no model"))

        #expect(panel.face?.warnings == ["no model", "no text field took them"])
    }
}
