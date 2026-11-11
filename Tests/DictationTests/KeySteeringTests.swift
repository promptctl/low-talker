import Dictation
import Dispatch
import Foundation
import Insertion
import LowTalkerCore
import TestProbes
import Testing

/// How the app answers the input method about a Return it is holding, over the real loop, the
/// real hotkey and a keyboard the test types on, with the answers read off a stand-in for the
/// port. [LAW:behavior-not-structure] What is held is what the input method would be told, and
/// that the words are at the cursor by the time it is told they landed.
@MainActor
@Suite struct KeySteeringTests {
    private enum Said: Equatable {
        case owing(Owing)
        case settlement(Settlement)
        case panel(PanelState)
    }

    /// The answers the input method would hear, in order.
    private final class Answers: Answering {
        private let stream: AsyncStream<Said>
        private let continuation: AsyncStream<Said>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream() }

        func send(_ owing: Owing) -> Reply.Delivery {
            continuation.yield(.owing(owing))
            return .delivered
        }

        func send(_ settlement: Settlement) -> Reply.Delivery {
            continuation.yield(.settlement(settlement))
            return .delivered
        }

        func send(_ panel: PanelState) -> Reply.Delivery {
            continuation.yield(.panel(panel))
            return .delivered
        }

        func next() async -> Said {
            for await said in stream { return said }
            preconditionFailure("the answers ended while a test was still reading them")
        }
    }

    /// A feed the test types the chord on.
    private final class Feed: ModifierFeed {
        var handle: (@MainActor (KeyEvent) -> Void)?

        func install(handling handle: @escaping @MainActor (KeyEvent) -> Void) throws -> Disposal {
            self.handle = handle
            return {}
        }
    }

    /// The loop and the hotkey that feeds it, with a keyboard.
    @MainActor private struct Loop {
        let rig: Rig
        let hotkey: Hotkey
        let feed: Feed
        let steering: KeySteering

        init(hearing engine: FakeTranscriber = FakeTranscriber { _ in Transcript(typed: "a") }, refusing refusal: InsertFailure? = nil, holdsReturn: Bool = true, panelOpen: Bool = false, keeping store: FakeHeldStore = FakeHeldStore()) async throws {
            rig = try await Rig(hearing: engine, keeping: store)
            rig.inputMethod.refusing(refusal)
            feed = Feed()
            hotkey = Hotkey(modes: Config.default.modes, feed: feed)
            let dictation = rig.dictation
            try hotkey.start(feeding: dictation)
            steering = KeySteering(dictation: dictation, hotkey: hotkey, holdsReturn: { holdsReturn }, panelShown: { panelOpen })
        }

        /// Right Option going down or up, `held` milliseconds into the press, stamped on the
        /// clock the loop's marks are on.
        func chord(_ direction: KeyEvent.Direction, atMilliseconds ms: Int64) {
            feed.handle?(KeyEvent(
                key: .rightOption, direction: direction, modifiers: direction == .down ? [.rightOption] : [],
                time: HostTime(uptime: rig.now.uptime + .milliseconds(ms)), lastTyped: HostTime(uptime: .seconds(-60))))
        }

        func delivered() async {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }

        /// A tap, which latches the press open, with words spoken into it.
        func latchedPress() async {
            chord(.down, atMilliseconds: 0)
            await delivered()
            rig.speak([1, 2, 3])
            chord(.up, atMilliseconds: 100)
            await delivered()
        }

        /// Now, as a Return's stamp: on the host clock the press is ended against.
        var typedNow: TimeInterval { HostTime.now.uptime / .seconds(1) }
    }

    /// The case this exists for: a Return typed into a latched press ends it, and the app says
    /// the words landed only once they are at the cursor.
    @Test(.timeLimit(.minutes(1))) func aReturnTypedIntoALatchedPressSettlesOnceItsWordsHaveLanded() async throws {
        let loop = try await Loop()
        await loop.latchedPress()
        let answers = Answers()

        loop.steering.answer(.owed(at: loop.typedNow), through: answers)
        #expect(await answers.next() == .owing(.words))
        loop.steering.answer(.settled(at: loop.typedNow), through: answers)

        #expect(await answers.next() == .settlement(.landed))
        #expect(loop.rig.inputMethod.inserted == ["a"])
        #expect(loop.hotkey.phase == .idle)
        #expect(!loop.rig.dictation.owes)
    }

    /// Escape typed into a latched press cancels it: the press ends as cancelled, and the next press
    /// begins fresh. Nothing it said is held.
    @Test(.timeLimit(.minutes(1))) func anEscapeTypedIntoALatchedPressCancelsIt() async throws {
        let loop = try await Loop()
        await loop.latchedPress()

        KeySteering.escape(loop.hotkey)

        #expect(loop.hotkey.phase == .idle)
        let cancelled = try #require(await loop.rig.report().cancelled)
        #expect(cancelled.takenBack == 0)
        #expect(loop.rig.hold.held == nil)
    }

    /// And into a held one, the chord still down: the press ends as cancelled, and the chord's
    /// release after it ends nothing.
    @Test(.timeLimit(.minutes(1))) func anEscapeTypedIntoAHeldPressCancelsIt() async throws {
        let loop = try await Loop()
        loop.chord(.down, atMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])

        KeySteering.escape(loop.hotkey)

        loop.chord(.up, atMilliseconds: 400)
        await loop.delivered()
        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.hotkey.phase == .idle)
    }

    /// An Escape typed after words landed takes them back out of the field: the take-back is the
    /// press's own, reached through the key.
    @Test(.timeLimit(.minutes(1))) func anEscapeTypedAfterWordsLandedTakesThemBack() async throws {
        let loop = try await Loop(hearing: FakeTranscriber(confirming: { $0.count >= 2 ? Transcript(typed: " hello") : Transcript(typed: "") }) { _ in Transcript(typed: " hello") })
        await loop.latchedPress()
        await loop.rig.until { loop.rig.inputMethod.field == " hello" }

        KeySteering.escape(loop.hotkey)

        #expect(loop.hotkey.phase == .idle)
        let cancelled = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == "")
        #expect(loop.rig.inputMethod.takeBacks == [" hello"])
        #expect(cancelled.takenBack == 1)
        #expect(loop.rig.hold.held == nil)
    }

    /// Escape with no press open is nothing to cancel, and leaves the next press to begin normally.
    @Test(.timeLimit(.minutes(1))) func anEscapeWithNoPressOpenCancelsNothing() async throws {
        let loop = try await Loop()

        KeySteering.escape(loop.hotkey)

        #expect(loop.hotkey.phase == .idle)
    }

    /// The Escape the input method reports is the word box's dismissal: the press open is
    /// cancelled, the words held before it are let go, and the box is put away, and stays away
    /// through what the loop shows of the cancelled press after it.
    @Test(.timeLimit(.minutes(1))) func anEscapeTheInputMethodReportsDismissesTheBox() async throws {
        let earlier = Held.unplaced(part(" earlier words", "WARNING: no text field took them"))
        let loop = try await Loop(keeping: FakeHeldStore(keeping: earlier))
        let panel = StubPanel()
        let box = WordBox(panel: panel)
        let ready = EngineReadiness.ready(.default, after: .seconds(1))
        loop.chord(.down, atMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])
        box.show(try #require(loop.rig.shown.activities.last), over: ready, held: loop.rig.hold.held, insertable: true)
        #expect(panel.face?.state == "Listening")
        let shownBefore = loop.rig.shown.activities.count

        box.react(to: .escape, cancelling: loop.hotkey, hold: loop.rig.hold)

        #expect(panel.shown.last == .away)
        #expect(loop.rig.hold.held == nil)
        #expect(loop.rig.hold.dismissed == earlier)
        loop.chord(.up, atMilliseconds: 400)
        await loop.delivered()
        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.hotkey.phase == .idle)
        let after = loop.rig.shown.activities.dropFirst(shownBefore)
        #expect(!after.isEmpty)
        for activity in after {
            box.show(activity, over: ready, held: loop.rig.hold.held, insertable: true)
            #expect(panel.face == nil, "shown \(activity) after the Escape")
        }
    }

    /// A Return the input method reports passed through it, held and sent there: the press stays
    /// open, and the box and the held words are as they were.
    @Test(.timeLimit(.minutes(1))) func aReturnTheInputMethodReportsChangesNothing() async throws {
        let earlier = Held.unplaced(part(" earlier words", "WARNING: no text field took them"))
        let loop = try await Loop(keeping: FakeHeldStore(keeping: earlier))
        let panel = StubPanel()
        let box = WordBox(panel: panel)
        loop.chord(.down, atMilliseconds: 0)
        await loop.delivered()
        box.show(.listening(heard: Transcript(words: [])), over: .ready(.default, after: .seconds(1)), held: loop.rig.hold.held, insertable: true)
        let shown = panel.shown

        box.react(to: .return, cancelling: loop.hotkey, hold: loop.rig.hold)

        #expect(panel.shown == shown)
        #expect(loop.rig.hold.held == earlier)
        guard case .held = loop.hotkey.phase else {
            Issue.record("the press is \(loop.hotkey.phase) after a Return")
            return
        }
        loop.chord(.up, atMilliseconds: 400)
        await loop.delivered()
        #expect(await loop.rig.report().cancelled == nil)
    }

    @Test(.timeLimit(.minutes(1))) func nothingIsOwedWhenNoPressIsOpen() async throws {
        let loop = try await Loop()
        let answers = Answers()

        loop.steering.answer(.owed(at: loop.typedNow), through: answers)
        loop.steering.answer(.settled(at: loop.typedNow), through: answers)

        #expect(await answers.next() == .owing(.nothing))
        #expect(await answers.next() == .settlement(.landed))
    }

    /// With the Return setting off a Return is never held, so nothing is owed even while words are.
    @Test(.timeLimit(.minutes(1))) func nothingIsOwedWhileTheReturnSettingIsOff() async throws {
        let loop = try await Loop(holdsReturn: false)
        await loop.latchedPress()
        let answers = Answers()

        loop.steering.answer(.owed(at: loop.typedNow), through: answers)

        #expect(await answers.next() == .owing(.nothing))
    }

    /// The word box is asked about on the main actor and answered with whether it is open.
    @Test(.timeLimit(.minutes(1))) func theBoxIsAnsweredWithWhetherItIsOpen() async throws {
        let loop = try await Loop(panelOpen: true)
        let answers = Answers()

        loop.steering.answer(.panel(at: loop.typedNow), through: answers)

        #expect(await answers.next() == .panel(.shown))
    }

    /// A press that ended on its own and is still decoding is owed too, though no key steered it.
    @Test(.timeLimit(.minutes(1))) func aPressThatEndedAndIsStillBeingHeardOwesWords() async throws {
        let gate = Gate()
        let rig = try await Rig(transcriber: { FakeTranscriber { _ in await gate.wait(); return Transcript(typed: "a") } })
        rig.hold()
        await gate.changed.settled { gate.waiting == 1 }
        #expect(rig.dictation.owes)

        gate.open()
        try await rig.dictation.finish()
        #expect(!rig.dictation.owes)
    }

    /// Words that reached no cursor are held, so they did not land, and the input method keeps its
    /// Return rather than send a message without them.
    @Test(.timeLimit(.minutes(1))) func wordsThatReachedNoCursorDidNotLand() async throws {
        let loop = try await Loop(refusing: .refused(.noTextFieldHasFocus))
        await loop.latchedPress()
        let answers = Answers()

        loop.steering.answer(.settled(at: loop.typedNow), through: answers)

        #expect(await answers.next() == .settlement(.notLanded))
        #expect(loop.rig.inputMethod.inserted.isEmpty)
    }

    /// A press whose chord the app still reads as down ends as the chord comes up, so there is
    /// nothing to wait for and nothing is waited for: not landed, at once, the press left open.
    @Test(.timeLimit(.minutes(1))) func aChordStillDownIsNotLandedAtOnceAndLeavesThePressOpen() async throws {
        let loop = try await Loop()
        loop.chord(.down, atMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])
        let answers = Answers()

        loop.steering.answer(.settled(at: loop.typedNow), through: answers)

        #expect(await answers.next() == .settlement(.notLanded))
        #expect(loop.rig.dictation.owes)
        // The chord coming up ends the press as it always did.
        loop.chord(.up, atMilliseconds: 400)
        await loop.delivered()
        try await loop.rig.dictation.finish()
        #expect(loop.rig.inputMethod.inserted == ["a"])
    }
}
