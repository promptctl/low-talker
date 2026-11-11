import Dictation
import LowTalkerCore
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

/// When the word box is on screen and what it offers, over a real hold kept in memory.
/// [LAW:behavior-not-structure] What the panel is told to draw, and where the held words are.
@MainActor
@Suite struct WordBoxTests {
    private let panel = StubPanel()
    private let box: WordBox
    private let hold: Hold
    private let ready = EngineReadiness.ready(.default, after: .seconds(1))
    private static let earlier = Held.unplaced(part(" earlier words", "WARNING: no text field took them"))

    init() {
        box = WordBox(panel: panel)
        hold = Hold(store: FakeHeldStore(keeping: Self.earlier), failedToKeep: { _ in }, showing: { _ in })
    }

    private func show(_ activity: Dictation.Activity, insertable: Bool = true) {
        box.show(activity, over: ready, held: hold.held, insertable: insertable)
    }

    private static func listening(_ typed: String) -> Dictation.Activity {
        .listening(heard: Transcript(typed: typed))
    }

    @Test func aDismissalPutsTheBoxAwayAndLetsGoOfTheHeldWords() {
        show(.idle)
        #expect(panel.face != nil)

        box.dismiss(cancelling: nil, hold: hold)

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

    @Test func aBringBackShowsTheBoxAgain() {
        show(.idle)
        box.dismiss(cancelling: nil, hold: hold)

        box.offerAgain()
        box.show(.idle, over: ready, held: Self.earlier, insertable: true)

        #expect(panel.face?.words == Self.earlier.allWords)
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
    func thePanelOrdersInTheControlsTheBoxOffers(activity: Dictation.Activity, insertable: Bool, insertAndCopy: [Bool]) {
        show(activity, insertable: insertable)

        let controls = panel.face?.controls
        #expect(controls.map { [$0.insert, $0.copy] } == insertAndCopy)
    }

    @Test func nothingHeldOrdersInNoControls() {
        box.dismiss(cancelling: nil, hold: hold)
        box.offerAgain()

        show(.transcribing)

        #expect(panel.face?.state == "Transcribing")
        #expect(panel.face?.controls == nil)
    }

    @Test func nothingOnItsWayAndNothingHeldIsNoBox() {
        box.dismiss(cancelling: nil, hold: hold)
        box.offerAgain()

        show(.idle)

        #expect(panel.shown.last == .away)
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
