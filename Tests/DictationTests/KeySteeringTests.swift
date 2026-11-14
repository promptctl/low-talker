import Dictation
import DictationFakes
import Dispatch
import Foundation
import Insertion
import InsertionFakes
import LowTalkerCore
import LowTalkerCoreFakes
import TestProbes
import Testing
import Uptime

private struct LoadFailed: Error {}
private struct BadBuffer: Error {}

/// How the app answers the input method about a Return it is holding, over the real loop, the
/// real hotkey and a keyboard the test types on, with the answers read off a stand-in for the
/// port. [LAW:behavior-not-structure] What is held is what the input method would be told, and
/// that the words are at the cursor by the time it is told they landed.
@MainActor
@Suite struct KeySteeringTests {
    /// The loop and the hotkey that feeds it, with a keyboard.
    @MainActor private struct Loop {
        let rig: Rig
        let hotkey: Hotkey
        let feed: FakeModifierFeed
        let steering: KeySteering
        /// The word box an Escape the input method asks about is taken by, as the app's is.
        let box: WordBox
        let panel: StubPanel

        init(hearing engine: FakeTranscriber = FakeTranscriber { _ in Transcript(typed: "a") }, refusing refusal: InsertFailure? = nil, holdsReturn: Bool = true, keeping store: FakeHeldStore = FakeHeldStore()) async throws {
            try self.init(over: try await Rig(hearing: engine, keeping: store), refusing: refusal, holdsReturn: holdsReturn)
        }

        init(over rig: Rig, refusing refusal: InsertFailure? = nil, holdsReturn: Bool = true) throws {
            self.rig = rig
            rig.inputMethod.refusing(refusal)
            feed = FakeModifierFeed(on: rig.clock.clock)
            hotkey = Hotkey(modes: Config.default.modes, feed: feed)
            let dictation = rig.dictation
            try hotkey.start(feeding: dictation)
            let (panel, hold) = (StubPanel(), rig.hold)
            let box = WordBox(panel: panel)
            (self.panel, self.box) = (panel, box)
            steering = KeySteering(dictation: dictation, hotkey: hotkey, holdsReturn: { holdsReturn }, dismissing: { box.escape(cancelling: $0, hold: hold) })
        }

        /// Right Option going down or up `ms` milliseconds from now on the rig's clock, which the
        /// loop's marks are on, and stamped at that moment.
        func chord(_ direction: KeyEvent.Direction, afterMilliseconds ms: Int64) {
            // The time passes, and the key is stamped at the moment it is typed.
            rig.clock.advance(by: .milliseconds(ms))
            feed.type(KeyEvent(
                key: .rightOption, direction: direction, modifiers: direction == .down ? [.rightOption] : [],
                time: rig.now, lastTyped: HostTime(uptime: .seconds(-60))))
        }

        func delivered() async {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }

        /// A tap, which latches the press open, with words spoken into it.
        func latchedPress() async {
            chord(.down, afterMilliseconds: 0)
            await delivered()
            rig.speak([1, 2, 3])
            chord(.up, afterMilliseconds: 100)
            await delivered()
        }

        /// A hold, `samples` spoken into it, and its release.
        func release(speaking samples: [Float]) async {
            chord(.down, afterMilliseconds: 0)
            await delivered()
            rig.speak(samples)
            chord(.up, afterMilliseconds: 400)
            await delivered()
        }

        /// The person putting the word box away, as an Escape the app takes does.
        func escapeTheBox() {
            box.dismiss(cancelling: steering, hold: rig.hold)
        }

        /// The box drawn over `activity`, as the app draws it.
        func show(_ activity: Dictation.Activity) {
            box.show(activity, over: .ready(.default, after: .seconds(1)), held: rig.hold.held, insertable: true)
        }

        /// The box drawn over what the loop last showed.
        func showTheBox() throws {
            show(try #require(rig.shown.activities.last))
        }

        /// What the app did with an Escape the input method asked it to take.
        func escape() async -> FakeReply.Said {
            let reply = FakeReply()
            steering.answer(.escape(at: typedNow), through: reply)
            return await reply.said()
        }

        /// Now, as a Return's stamp: on the rig's clock, which the press is ended against.
        var typedNow: TimeInterval { rig.now.uptime / .seconds(1) }
    }

    /// The case this exists for: a Return typed into a latched press ends it, and the app says
    /// the words landed only once they are at the cursor.
    @Test(.timeLimit(.minutes(1))) func aReturnTypedIntoALatchedPressSettlesOnceItsWordsHaveLanded() async throws {
        let loop = try await Loop()
        await loop.latchedPress()
        let (owed, settled) = (FakeReply(), FakeReply())

        loop.steering.answer(.owed(at: loop.typedNow), through: owed)
        #expect(await owed.said() == .owing(.words))
        loop.steering.answer(.settled(at: loop.typedNow), through: settled)

        #expect(await settled.said() == .settlement(.landed))
        #expect(loop.rig.inputMethod.inserted == ["a"])
        #expect(loop.hotkey.phase == .idle)
        #expect(!loop.rig.dictation.owes)
    }

    /// Escape typed into a latched press cancels it: the press ends as cancelled, and the next press
    /// begins fresh. Nothing it said is held.
    @Test(.timeLimit(.minutes(1))) func anEscapeTypedIntoALatchedPressCancelsIt() async throws {
        let loop = try await Loop()
        await loop.latchedPress()

        loop.steering.escape()

        #expect(loop.hotkey.phase == .idle)
        let cancelled = try #require(await loop.rig.report().cancelled)
        #expect(cancelled.takenBack == 0)
        #expect(loop.rig.hold.held == nil)
    }

    /// And into a held one, the chord still down: the press ends as cancelled, and the chord's
    /// release after it ends nothing.
    @Test(.timeLimit(.minutes(1))) func anEscapeTypedIntoAHeldPressCancelsIt() async throws {
        let loop = try await Loop()
        loop.chord(.down, afterMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])

        loop.steering.escape()

        loop.chord(.up, afterMilliseconds: 400)
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

        loop.steering.escape()

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

        loop.steering.escape()

        #expect(loop.hotkey.phase == .idle)
    }

    /// The case low-dictation-keys-652.1hf exists for: an Escape the input method reports while a
    /// released press is still being transcribed throws it away. The words it committed are taken
    /// back, nothing of it is held, and it reports as cancelled.
    @Test(.timeLimit(.minutes(1))) func anEscapeWhileAReleasedPressIsTranscribedCancelsIt() async throws {
        let gate = Gate()
        let loop = try await Loop(hearing: FakeTranscriber(confirming: { $0.count >= 2 ? Transcript(typed: " hello") : Transcript(typed: "") }) { _ in
            await gate.wait()
            return Transcript(typed: " hello world")
        })
        await loop.release(speaking: [1, 2, 3])
        await loop.rig.until { loop.rig.inputMethod.field == " hello" }
        #expect(loop.rig.shown.activities.last == .transcribing)

        loop.escapeTheBox()
        gate.open()

        let cancelled = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == "")
        #expect(cancelled.takenBack == 1)
        #expect(loop.rig.hold.held == nil)
    }

    /// An Escape while a released press's last words are going in takes them back once they land.
    @Test(.timeLimit(.minutes(1))) func anEscapeWhileAReleasedPressInsertsTakesItsWordsBack() async throws {
        let loop = try await Loop(hearing: FakeTranscriber { _ in Transcript(typed: " hello") })
        loop.rig.inputMethod.hold()
        await loop.release(speaking: [1, 2, 3])
        await loop.rig.until { loop.rig.inputMethod.holding == 1 }

        loop.escapeTheBox()
        loop.rig.inputMethod.letGo()

        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == "")
        #expect(loop.rig.inputMethod.takeBacks == [" hello"])
        #expect(loop.rig.hold.held == nil)
    }

    /// And when that insert is refused, its words are let go rather than held behind the dismissal.
    @Test(.timeLimit(.minutes(1))) func anEscapeWhileARefusedInsertGoesInHoldsNothing() async throws {
        let loop = try await Loop(hearing: FakeTranscriber { _ in Transcript(typed: " hello") })
        loop.rig.inputMethod.hold()
        await loop.release(speaking: [1, 2, 3])
        await loop.rig.until { loop.rig.inputMethod.holding == 1 }

        loop.escapeTheBox()
        loop.rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        loop.rig.inputMethod.letGo()

        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == "")
        #expect(loop.rig.hold.held == nil)
        #expect(loop.rig.hold.dismissed == nil)
    }

    /// The case low-dictation-keys-652.6nx exists for: an Escape into a latched press while its
    /// first commit is in the air, which is then refused. Once the Escape is delivered the press
    /// is not shown on its way, and the refused word is never held: the hold lets it go and the
    /// report counts it. So a circle clicked while the press drains finds nothing held, and the
    /// person's earlier dismissal is still theirs to bring back.
    @Test(.timeLimit(.minutes(1))) func anEscapedPressIsShownToNoOneWhileItDrains() async throws {
        let earlier = Held.unplaced(part(" before", "\(Refusal.noTextFieldHasFocus)"))
        let loop = try await Loop(hearing: FakeTranscriber(confirming: { $0.count >= 2 ? Transcript(typed: " hello") : Transcript(typed: "") }) { _ in
            Transcript(typed: " hello")
        }, keeping: FakeHeldStore(dismissed: earlier))
        loop.rig.inputMethod.hold()
        await loop.latchedPress()
        await loop.rig.until { loop.rig.inputMethod.holding == 1 }

        loop.escapeTheBox()
        await loop.delivered()
        #expect(loop.rig.shown.activities.last == .idle)
        let shownBefore = loop.rig.shown.states.count
        loop.rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        loop.rig.inputMethod.letGo()
        await loop.rig.until { loop.rig.inputMethod.holding == 0 }
        loop.rig.hold.dismiss()

        let cancelled = try #require(await loop.rig.report().cancelled)
        #expect(cancelled.forgotten == 1)
        #expect(loop.rig.shown.states.dropFirst(shownBefore).allSatisfy { $0.held == nil && $0.dismissed == earlier })
        #expect(loop.rig.hold.held == nil)
        #expect(loop.rig.hold.dismissed == earlier)
        #expect(loop.rig.store.kept == nil)
    }

    /// The two ways an Escape reaches the press it throws away: the detector ends one it holds
    /// open, and the loop hears of it a main-queue turn later, or the loop throws away one on its
    /// way at once.
    enum EscapedPress: CaseIterable, Sendable {
        case latched
        case released
    }

    /// A press whose word no cursor took, under a person's earlier dismissal, held by the gate
    /// `final` waits on. More speech into it confirms a second word.
    private func pressHoldingItsRefusedWord(_ press: EscapedPress, keeping store: FakeHeldStore, final: Gate) async throws -> Loop {
        let loop = try await Loop(hearing: FakeTranscriber(confirming: { samples in
            Transcript(typed: samples.count >= 5 ? " hello there" : samples.count >= 2 ? " hello" : "")
        }) { _ in
            await final.wait()
            return Transcript(typed: " hello there")
        }, refusing: .refused(.noTextFieldHasFocus), keeping: store)
        switch press {
        case .latched: await loop.latchedPress()
        case .released: await loop.release(speaking: [1, 2, 3])
        }
        await loop.rig.until { loop.rig.hold.held?.allWords.line.contains("hello") == true }
        return loop
    }

    /// The case low-dictation-keys-652.fxl exists for: an Escape dismisses what is held before it
    /// reaches the press it throws away, so when that press's words were all that was held, the
    /// Escape dismissed nothing, and the person's earlier dismissal is still theirs to bring back.
    @Test(.timeLimit(.minutes(1)), arguments: EscapedPress.allCases)
    func anEscapeOverOnlyItsPressWordsLeavesTheEarlierDismissal(_ press: EscapedPress) async throws {
        let earlier = Held.unplaced(part(" before", "\(Refusal.noTextFieldHasFocus)"))
        let final = Gate()
        let loop = try await pressHoldingItsRefusedWord(press, keeping: FakeHeldStore(dismissed: earlier), final: final)

        loop.escapeTheBox()
        await loop.delivered()
        final.open()

        let cancelled = try #require(await loop.rig.report().cancelled)
        #expect(cancelled.forgotten == 1)
        #expect(loop.rig.hold.held == nil)
        #expect(loop.rig.hold.dismissed == earlier)
    }

    /// And when the press's held word is in an insert on its way at the Escape: the insert lands,
    /// the press takes the word back out of the field, and the earlier dismissal is still there.
    @Test(.timeLimit(.minutes(1)), arguments: EscapedPress.allCases)
    func anEscapeOverItsPressWordsAnInsertCarriesLeavesTheEarlierDismissal(_ press: EscapedPress) async throws {
        let earlier = Held.unplaced(part(" before", "\(Refusal.noTextFieldHasFocus)"))
        let final = Gate()
        let loop = try await pressHoldingItsRefusedWord(press, keeping: FakeHeldStore(dismissed: earlier), final: final)
        loop.rig.inputMethod.refusing(nil)
        loop.rig.inputMethod.hold()
        switch press {
        case .latched: loop.rig.speak([4, 5])
        case .released: final.open()
        }
        await loop.rig.until { loop.rig.inputMethod.holding == 1 }

        loop.escapeTheBox()
        await loop.delivered()
        loop.rig.inputMethod.letGo()
        final.open()

        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == "")
        #expect(loop.rig.hold.held == nil)
        #expect(loop.rig.hold.dismissed == earlier)
        #expect(loop.rig.store.state == HoldState(dismissed: earlier))
    }

    /// Words held there that the press did not say are dismissed by the Escape, as any dismissal
    /// does, in place of the earlier one.
    @Test(.timeLimit(.minutes(1)), arguments: EscapedPress.allCases)
    func anEscapeDismissesTheWordsItsPressDidNotSay(_ press: EscapedPress) async throws {
        let earlier = Held.unplaced(part(" before", "\(Refusal.noTextFieldHasFocus)"))
        let kept = Held.unplaced(part(" kept", "\(Refusal.noTextFieldHasFocus)"))
        let final = Gate()
        let loop = try await pressHoldingItsRefusedWord(press, keeping: FakeHeldStore(keeping: kept, dismissed: earlier), final: final)

        loop.escapeTheBox()
        await loop.delivered()
        final.open()

        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.hold.held == nil)
        #expect(loop.rig.hold.dismissed?.allWords == kept.allWords)
        #expect(loop.rig.store.state.dismissed?.allWords == kept.allWords)
        #expect(loop.rig.store.state.dismissed?.warnings == kept.warnings)
    }

    /// An Escape throws away the press whose key-up is still in delivery, and the box then shows
    /// the press before it, still on its way, as Transcribing: a second Escape throws that one away.
    @Test(.timeLimit(.minutes(1))) func aSecondEscapeThrowsAwayWhatTheFirstLeftShown() async throws {
        let loop = try await Loop()
        loop.rig.inputMethod.hold()
        await loop.release(speaking: [1, 2, 3])
        await loop.rig.until { loop.rig.inputMethod.holding == 1 }
        loop.chord(.down, afterMilliseconds: 1000)
        await loop.delivered()
        loop.rig.speak([4, 5, 6])
        loop.chord(.up, afterMilliseconds: 400)

        loop.escapeTheBox()
        #expect(loop.rig.shown.activities.last == .transcribing)
        loop.escapeTheBox()
        #expect(loop.rig.shown.activities.last == .idle)
        loop.rig.inputMethod.letGo()

        _ = try #require(await loop.rig.report().cancelled)
        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == "")
    }

    /// A press cut short, its engine still loading when Escape comes and then failing: nothing of
    /// it is held, and its speech is not kept to be read later.
    @Test(.timeLimit(.minutes(1))) func anEscapeWhileACutPressWaitsOnItsEngineKeepsNothing() async throws {
        let gate = Gate()
        let rig = try await Rig(engine: { () throws(EngineUnavailable) -> Dictation.Engine in
            { () async throws(EngineUnavailable) -> any Transcriber in
                await gate.wait()
                throw EngineUnavailable(LoadFailed())
            }
        })
        let loop = try Loop(over: rig)
        loop.chord(.down, afterMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])
        loop.hotkey.stop()
        await loop.delivered()
        await gate.changed.settled { gate.waiting == 1 }

        loop.escapeTheBox()
        gate.open()

        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.hold.held == nil)
        #expect(loop.rig.unheard.kept.isEmpty)
    }

    /// An Escape that reaches the loop before the key-up it follows is delivered still cancels the
    /// press: the detector has let it go, so the loop throws it away, and the key-up's release does
    /// not undo it.
    @Test(.timeLimit(.minutes(1))) func aPressCancelledBeforeItsReleaseIsDeliveredStaysCancelled() async throws {
        let loop = try await Loop()
        loop.chord(.down, afterMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])

        loop.chord(.up, afterMilliseconds: 400)
        loop.escapeTheBox()
        await loop.delivered()

        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == "")
    }

    /// An Escape throws away the press the box shows: the open one, and not an earlier press still
    /// on its way, whose words land.
    @Test(.timeLimit(.minutes(1))) func anEscapeIntoAnOpenPressLeavesTheOneBeforeIt() async throws {
        let gate = Gate()
        let loop = try await Loop(hearing: FakeTranscriber { _ in
            await gate.wait()
            return Transcript(typed: " one")
        })
        await loop.release(speaking: [1, 2, 3])
        loop.chord(.down, afterMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])

        loop.escapeTheBox()
        loop.chord(.up, afterMilliseconds: 400)
        await loop.delivered()
        gate.open()

        _ = try await loop.rig.report().get()
        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == " one")
    }

    /// With no press open the box shows every press on its way as one Transcribing, so an Escape
    /// throws every one of them away.
    @Test(.timeLimit(.minutes(1))) func anEscapeWithTwoPressesOnTheirWayCancelsBoth() async throws {
        let gate = Gate()
        let loop = try await Loop(hearing: FakeTranscriber { _ in
            await gate.wait()
            return Transcript(typed: " one")
        })
        await loop.release(speaking: [1, 2, 3])
        await loop.release(speaking: [1, 2, 3])

        loop.escapeTheBox()
        gate.open()

        _ = try #require(await loop.rig.report().cancelled)
        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == "")
    }

    /// An Escape in the moment after a chord goes down, before its press reaches the loop, is that
    /// press's alone: the detector cancels it, and the press before it, on its way, lands.
    @Test(.timeLimit(.minutes(1))) func anEscapeAsAChordGoesDownCancelsOnlyThatPress() async throws {
        let gate = Gate()
        let loop = try await Loop(hearing: FakeTranscriber { _ in
            await gate.wait()
            return Transcript(typed: " one")
        })
        await loop.release(speaking: [1, 2, 3])
        loop.chord(.down, afterMilliseconds: 0)

        loop.escapeTheBox()
        await loop.delivered()
        loop.chord(.up, afterMilliseconds: 400)
        await loop.delivered()
        gate.open()

        _ = try await loop.rig.report().get()
        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.rig.inputMethod.field == " one")
    }

    /// A refused press shows its refusal, so an Escape into it throws away nothing on its way.
    @Test(.timeLimit(.minutes(1))) func anEscapeIntoARefusedPressLeavesTheOneBeforeIt() async throws {
        let gate = Gate()
        let loop = try await Loop(hearing: FakeTranscriber { _ in
            await gate.wait()
            return Transcript(typed: " one")
        })
        await loop.release(speaking: [1, 2, 3])
        loop.rig.hardware.failingToLaunch = BadBuffer()
        loop.chord(.down, afterMilliseconds: 0)
        await loop.delivered()

        loop.escapeTheBox()
        gate.open()
        loop.chord(.up, afterMilliseconds: 400)
        await loop.delivered()

        _ = try await loop.rig.report().get()
        #expect(await loop.rig.report().failure is NoMicrophone)
        #expect(loop.rig.inputMethod.field == " one")
    }

    /// The case low-dictation-keys-652.9ix exists for: an Escape the app takes while the box shows
    /// a press is the box's dismissal, done in the turn it answers. The press open is cancelled, the
    /// words held before it are let go, and the box is put away, and stays away through what the
    /// loop shows of the cancelled press after it.
    @Test(.timeLimit(.minutes(1))) func anEscapeTheAppTakesCancelsThePressTheBoxShowed() async throws {
        let earlier = Held.unplaced(part(" earlier words", "WARNING: no text field took them"))
        let loop = try await Loop(keeping: FakeHeldStore(keeping: earlier))
        loop.chord(.down, afterMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])
        try loop.showTheBox()
        #expect(loop.panel.face?.state == "Listening")
        let shownBefore = loop.rig.shown.activities.count

        #expect(await loop.escape() == .dismissal(.dismissed))

        #expect(loop.panel.shown.last == .away)
        #expect(loop.rig.hold.held == nil)
        #expect(loop.rig.hold.dismissed == earlier)
        loop.chord(.up, afterMilliseconds: 400)
        await loop.delivered()
        _ = try #require(await loop.rig.report().cancelled)
        #expect(loop.hotkey.phase == .idle)
        let after = loop.rig.shown.activities.dropFirst(shownBefore)
        #expect(!after.isEmpty)
        for activity in after {
            loop.show(activity)
            #expect(loop.panel.face == nil, "shown \(activity) after the Escape")
        }
    }

    /// An Escape whose box closed before the app acts on it, its press having landed since the box
    /// last showed it, does nothing, and is the app in front's.
    @Test(.timeLimit(.minutes(1))) func anEscapeWhoseBoxClosedBeforeTheAppActsIsTheAppInFronts() async throws {
        let loop = try await Loop()
        loop.rig.inputMethod.hold()
        await loop.release(speaking: [1, 2, 3])
        await loop.rig.until { loop.rig.inputMethod.holding == 1 }
        try loop.showTheBox()
        #expect(loop.panel.isShown)
        loop.rig.inputMethod.letGo()
        #expect(await loop.rig.report().cancelled == nil)
        await loop.rig.until { loop.rig.shown.activities.last == .idle }
        try loop.showTheBox()
        #expect(!loop.panel.isShown)

        #expect(await loop.escape() == .dismissal(.nothingShown))

        #expect(loop.rig.inputMethod.field == "a")
        #expect(loop.rig.inputMethod.takeBacks.isEmpty)
    }

    /// An Escape after a dismissal, the box put away while the press before the one it threw away is
    /// still on its way, does nothing: that press is not thrown away with it, and lands.
    @Test(.timeLimit(.minutes(1))) func anEscapeAfterADismissalCancelsNoPressOnItsWay() async throws {
        let loop = try await Loop()
        loop.rig.inputMethod.hold()
        await loop.release(speaking: [1, 2, 3])
        await loop.rig.until { loop.rig.inputMethod.holding == 1 }
        loop.chord(.down, afterMilliseconds: 1000)
        await loop.delivered()
        loop.rig.speak([4, 5, 6])
        try loop.showTheBox()
        #expect(await loop.escape() == .dismissal(.dismissed))
        loop.chord(.up, afterMilliseconds: 400)
        await loop.delivered()
        try loop.showTheBox()
        #expect(!loop.panel.isShown)

        #expect(await loop.escape() == .dismissal(.nothingShown))

        loop.rig.inputMethod.letGo()
        let reports = [await loop.rig.report(), await loop.rig.report()]
        #expect(reports.filter { $0.cancelled != nil }.count == 1)
        await loop.rig.until { loop.rig.inputMethod.field == "a" }
    }

    @Test(.timeLimit(.minutes(1))) func nothingIsOwedWhenNoPressIsOpen() async throws {
        let loop = try await Loop()
        let (owed, settled) = (FakeReply(), FakeReply())

        loop.steering.answer(.owed(at: loop.typedNow), through: owed)
        loop.steering.answer(.settled(at: loop.typedNow), through: settled)

        #expect(await owed.said() == .owing(.nothing))
        #expect(await settled.said() == .settlement(.landed))
    }

    /// With the Return setting off a Return is never held, so nothing is owed even while words are.
    @Test(.timeLimit(.minutes(1))) func nothingIsOwedWhileTheReturnSettingIsOff() async throws {
        let loop = try await Loop(holdsReturn: false)
        await loop.latchedPress()
        let answers = FakeReply()

        loop.steering.answer(.owed(at: loop.typedNow), through: answers)

        #expect(await answers.said() == .owing(.nothing))
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
        let answers = FakeReply()

        loop.steering.answer(.settled(at: loop.typedNow), through: answers)

        #expect(await answers.said() == .settlement(.notLanded))
        #expect(loop.rig.inputMethod.inserted.isEmpty)
    }

    /// A press whose chord the app still reads as down ends as the chord comes up, so there is
    /// nothing to wait for and nothing is waited for: not landed, at once, the press left open.
    @Test(.timeLimit(.minutes(1))) func aChordStillDownIsNotLandedAtOnceAndLeavesThePressOpen() async throws {
        let loop = try await Loop()
        loop.chord(.down, afterMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])
        let answers = FakeReply()

        loop.steering.answer(.settled(at: loop.typedNow), through: answers)

        #expect(await answers.said() == .settlement(.notLanded))
        #expect(loop.rig.dictation.owes)
        // The chord coming up ends the press as it always did.
        loop.chord(.up, afterMilliseconds: 400)
        await loop.delivered()
        try await loop.rig.dictation.finish()
        #expect(loop.rig.inputMethod.inserted == ["a"])
    }
}
