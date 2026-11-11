import Dictation
import Foundation
import Insertion
import LowTalkerCore
import Testing
import TestProbes

/// A press the person throws away with Escape, held against the document the inserts went into
/// and the hold: every word of it ends in exactly one place. [LAW:behavior-not-structure] The
/// detector ends a held and a latched press the same way, so one ending stands for both here;
/// `HotkeyDetectorTests` holds that they both end.
///
/// The press's own words are the engine's `" hello"`, `" there"`, `" my"` as the samples grow, and
/// an earlier press, whose samples begin with 9, says `"old words"`: so a word's text says whose it is.
@MainActor
@Suite struct CancelTests {
    private static func engine() -> FakeTranscriber {
        FakeTranscriber(confirming: { samples in
            if samples.first == 9 { return Transcript(typed: "") }
            return Transcript(typed: samples.count >= 6 ? " hello there my" : samples.count >= 4 ? " hello there" : samples.count >= 2 ? " hello" : "")
        }) { clip in Transcript(typed: clip.samples.first == 9 ? "old words" : " hello there my friend") }
    }

    private static let refusal = InsertFailure.refused(.noTextFieldHasFocus)

    private static func begin(_ rig: Rig) {
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
    }

    private static func cancel(_ rig: Rig) {
        rig.dictation.press(.ended(.cancelled))
    }

    /// Says `samples`, and waits for the commits those words make to be told of: `inserted`
    /// when the cursor takes them, or `held` words when it does not.
    private static func said(_ samples: [Float], in rig: Rig, until reached: @escaping @MainActor () -> Bool) async throws {
        rig.speak(samples)
        await rig.until { reached() }
    }

    /// An earlier press whose words no cursor took, so the hold offers `"old words"`.
    private static func holdingEarlierWords(_ rig: Rig) async throws {
        rig.inputMethod.refusing(refusal)
        rig.hold(speaking: [9, 9])
        _ = await rig.report()
        rig.inputMethod.refusing(nil)
        #expect(rig.hold.held == .unplaced(part("old words", "\(Refusal.noTextFieldHasFocus)")))
    }

    // MARK: - what landed

    /// The ticket's done-when: dictate a few words, cancel, and the field holds what it held
    /// before. Nothing is held or offered, and the next press dictates normally.
    @Test func cancellingTakesBackWhatLandedAndHoldsNothing() async throws {
        let rig = try await Rig(hearing: Self.engine())
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.inputMethod.field == " hello" }
        try await Self.said([3, 4], in: rig) { rig.inputMethod.field == " hello there" }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(rig.inputMethod.field == "")
        #expect(rig.inputMethod.takeBacks == [" hello there"])
        // The decode read " my friend" past the two commits, which a cancel drops.
        #expect(cancelled == Cancelled(takenBack: 2, earlierWordsLanded: 0, forgotten: 0, dismissed: 0, standing: 0, discarded: 2))
        #expect(rig.hold.held == nil)
        #expect(rig.hold.dismissed == nil)

        rig.hold(speaking: [1, 2, 3])
        _ = try await rig.session()
        #expect(rig.inputMethod.field == " hello there my friend")
    }

    /// A press cancelled before anything landed asks the input method nothing.
    @Test func aPressCancelledBeforeAnythingLandedMakesNoRequest() async throws {
        let rig = try await Rig(hearing: Self.engine())
        Self.begin(rig)
        rig.speak([1])
        Self.cancel(rig)

        let cancelled = try #require(await rig.report().cancelled)

        #expect(rig.inputMethod.takeBacks.isEmpty)
        #expect(cancelled.takenBack == 0)
        #expect(rig.hold.held == nil)
    }

    /// Earlier dictation the press's first insert carried into the field was delivered, and
    /// stays; only what the press said is taken back, and the request never carries held words.
    @Test func earlierWordsTheFirstInsertDeliveredStayInTheField() async throws {
        let rig = try await Rig(hearing: Self.engine())
        try await Self.holdingEarlierWords(rig)
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.inputMethod.field == "old words hello" }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(rig.inputMethod.field == "old words")
        #expect(rig.inputMethod.takeBacks == [" hello"])
        #expect(cancelled.takenBack == 1)
        #expect(cancelled.earlierWordsLanded == 2)
        #expect(rig.hold.held == nil)
    }

    /// Counts decide which words are the press's, not comparison: an earlier word that reads
    /// and is built exactly as the press's first leaves the earlier one in the field.
    @Test func equalWordsAreToldApartByCountNotByComparison() async throws {
        let engine = FakeTranscriber(confirming: { samples in Transcript(typed: samples.first != 9 && samples.count >= 2 ? "yes" : "") }) { _ in Transcript(typed: "yes") }
        let rig = try await Rig(hearing: engine)
        rig.inputMethod.refusing(Self.refusal)
        rig.hold(speaking: [9, 9])
        _ = await rig.report()
        rig.inputMethod.refusing(nil)
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.inputMethod.field == "yesyes" }

        Self.cancel(rig)
        _ = try #require(await rig.report().cancelled)

        #expect(rig.inputMethod.field == "yes")
        #expect(rig.inputMethod.takeBacks == ["yes"])
    }

    // MARK: - what no cursor took

    /// Words the press failed to land are let go from the hold, and nothing is taken back
    /// because nothing landed.
    @Test func wordsNoCursorTookAreLetGo() async throws {
        let rig = try await Rig(hearing: Self.engine())
        rig.inputMethod.refusing(Self.refusal)
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.hold.held != nil }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(rig.inputMethod.takeBacks.isEmpty)
        #expect(cancelled.forgotten == 1)
        #expect(rig.hold.held == nil)
        #expect(rig.store.kept == nil)
    }

    /// The hold goes back to the earlier part it held, under that part's own warning, not the
    /// warning of the failure the press met.
    @Test func theEarlierHeldPartComesBackWithItsOwnWarning() async throws {
        let rig = try await Rig(hearing: Self.engine())
        try await Self.holdingEarlierWords(rig)
        rig.inputMethod.refusing(.refused(.cursorIsInAnotherApp))
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.hold.held?.words == Transcript(typed: "old words hello") }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(cancelled.forgotten == 1)
        #expect(rig.hold.held == .unplaced(part("old words", "\(Refusal.noTextFieldHasFocus)")))
    }

    /// Earlier words, a first insert that fails, and a later one that lands carrying both the
    /// earlier words and the press's own failed ones: the field keeps the earlier words only.
    @Test func aLaterInsertThatCarriesTheEarlierWordsAndTheFailedOnesIsTakenBackToTheEarlierWords() async throws {
        let rig = try await Rig(hearing: Self.engine())
        try await Self.holdingEarlierWords(rig)
        rig.inputMethod.refusing(Self.refusal)
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.hold.held?.words == Transcript(typed: "old words hello") }
        rig.inputMethod.refusing(nil)
        try await Self.said([3, 4], in: rig) { rig.inputMethod.field == "old words hello there" }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(rig.inputMethod.field == "old words")
        #expect(rig.inputMethod.takeBacks == [" hello there"])
        #expect(cancelled.takenBack == 2)
        #expect(cancelled.earlierWordsLanded == 2)
        #expect(rig.hold.held == nil)
    }

    /// The person dismissed the press's failed words before cancelling: they are theirs, and
    /// stay dismissed, and the report says so.
    @Test func wordsThePersonDismissedStayDismissed() async throws {
        let rig = try await Rig(hearing: Self.engine())
        rig.inputMethod.refusing(Self.refusal)
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.hold.held != nil }
        let dismissing = try #require(rig.hold.held)
        rig.hold.dismiss()

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(cancelled.dismissed == 1)
        #expect(cancelled.forgotten == 0)
        #expect(rig.hold.dismissed == dismissing)
        #expect(rig.hold.held == nil)
    }

    /// Earlier words dismissed before the press's first insert, which then fails, leave the hold
    /// empty after a cancel, and the earlier words dismissed as the person left them.
    @Test func earlierWordsDismissedBeforeAFailedInsertLeaveNothingHeld() async throws {
        let rig = try await Rig(hearing: Self.engine())
        try await Self.holdingEarlierWords(rig)
        let earlier = try #require(rig.hold.held)
        Self.begin(rig)
        rig.hold.dismiss()
        rig.inputMethod.refusing(Self.refusal)
        try await Self.said([1, 2], in: rig) { rig.hold.held != nil }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(cancelled.forgotten == 1)
        #expect(rig.hold.held == nil)
        #expect(rig.hold.dismissed == earlier)
    }

    /// An insert carrying the earlier words and the press's first is in the air when the person
    /// dismisses what is held, and then fails without landing: the hold rebuilds its offered part
    /// from the press's words alone, onto a generation of it the press did not make.
    private static func dismissedWhileAnInsertIsInTheAir(_ rig: Rig) async throws -> Held {
        try await holdingEarlierWords(rig)
        let earlier = try #require(rig.hold.held)
        begin(rig)
        rig.inputMethod.hold()
        rig.speak([1, 2])
        await rig.until { rig.inputMethod.holding == 1 }
        rig.hold.dismiss()
        rig.inputMethod.refusing(refusal)
        rig.inputMethod.letGo()
        await rig.until { rig.hold.held?.words == Transcript(typed: " hello") }
        return earlier
    }

    @Test func aDismissalWhileAnInsertIsInTheAirThenCancellingLeavesNothingHeld() async throws {
        let rig = try await Rig(hearing: Self.engine())
        let earlier = try await Self.dismissedWhileAnInsertIsInTheAir(rig)

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(cancelled.forgotten == 1)
        #expect(rig.hold.held == nil)
        #expect(rig.hold.dismissed == earlier)
        #expect(rig.inputMethod.field == "")
    }

    /// The same, and then a later insert lands with the press's failed word: that word is the
    /// press's, so it is taken back, and the earlier words were never in the field.
    @Test func aLaterInsertAfterThatDismissalIsTakenBackWhole() async throws {
        let rig = try await Rig(hearing: Self.engine())
        let earlier = try await Self.dismissedWhileAnInsertIsInTheAir(rig)
        rig.inputMethod.refusing(nil)
        try await Self.said([3, 4], in: rig) { rig.inputMethod.field == " hello there" }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(rig.inputMethod.takeBacks == [" hello there"])
        #expect(cancelled.takenBack == 2)
        #expect(cancelled.earlierWordsLanded == 0)
        #expect(rig.inputMethod.field == "")
        #expect(rig.hold.held == nil)
        #expect(rig.hold.dismissed == earlier)
    }

    /// The same, and then another insert fails too: both of the press's words are in the offered
    /// part, and both are let go.
    @Test func anotherFailureAfterThatDismissalIsLetGoWhole() async throws {
        let rig = try await Rig(hearing: Self.engine())
        let earlier = try await Self.dismissedWhileAnInsertIsInTheAir(rig)
        try await Self.said([3, 4], in: rig) { rig.hold.held?.words == Transcript(typed: " hello there") }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(cancelled.forgotten == 2)
        #expect(rig.hold.held == nil)
        #expect(rig.hold.dismissed == earlier)
    }

    /// The press holds one word and the person dismisses it; then, with the commits stopped by a
    /// device change, kept speech is read into one held word while the key is still down. The hold
    /// offers as many words as the press last knew, but none is the press's, so the cancel leaves
    /// the recovered word held and says the press's word stays dismissed.
    @Test func anotherDictationsWordsHeldMidPressAreNotLetGo() async throws {
        let kept = FakeUnheardStore()
        _ = try kept.keep(UnheardSpeech(said: .now, vocabulary: [], samples: [7]))
        let rig = try await Rig(hearing: Self.engine(), keepingSpeech: kept)
        rig.inputMethod.refusing(Self.refusal)
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.hold.held != nil }
        rig.hold.dismiss()
        rig.changeDevice()
        rig.speak([3, 4])
        rig.recovery.landed(FakeTranscriber { _ in Transcript(typed: " first") })
        await rig.recovery.settled()
        let recovered = try #require(rig.hold.held)
        #expect(recovered.words == Transcript(typed: " first"))

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(cancelled.forgotten == 0)
        #expect(cancelled.dismissed == 1)
        #expect(rig.hold.held == recovered)
    }

    // MARK: - what may have landed, and what could not be taken back

    /// An insert that may have landed is not the press's to take back: its words stand in the hold
    /// under the failure's warning, as for any such insert, and the report counts them.
    @Test func wordsThatMayHaveLandedStand() async throws {
        let rig = try await Rig(hearing: Self.engine())
        let unanswered = InsertFailure.unreachable(.answerDidNotArrive(port: "port", after: .seconds(1)))
        rig.inputMethod.refusing(unanswered)
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.hold.held != nil }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(rig.inputMethod.takeBacks.isEmpty)
        #expect(cancelled.standing == 1)
        #expect(rig.hold.held == .unaccounted(part(" hello", "\(unanswered)")))
    }

    /// An insert that may have landed covers what it carried: the earlier words and the press's own
    /// failed ones stand with it, and the report counts every one.
    @Test func earlierAndFailedWordsAnUnansweredInsertCarriedStandToo() async throws {
        let rig = try await Rig(hearing: Self.engine())
        let unanswered = InsertFailure.unreachable(.answerDidNotArrive(port: "port", after: .seconds(1)))
        try await Self.holdingEarlierWords(rig)
        rig.inputMethod.refusing(Self.refusal)
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.hold.held?.words == Transcript(typed: "old words hello") }
        rig.inputMethod.refusing(unanswered)
        try await Self.said([3, 4], in: rig) { rig.hold.held == .unaccounted(part("old words hello there", "\(unanswered)")) }

        Self.cancel(rig)
        let cancelled = try #require(await rig.report().cancelled)

        #expect(cancelled == Cancelled(takenBack: 0, earlierWordsLanded: 0, forgotten: 0, dismissed: 0, standing: 4, discarded: 2))
    }

    /// Words that landed on either side of one that may have landed are not one run at the caret,
    /// so the take-back is refused, loudly, and the words stay and are counted.
    @Test func wordsAroundAnUnansweredInsertCannotBeTakenBack() async throws {
        let rig = try await Rig(hearing: Self.engine())
        let unanswered = InsertFailure.unreachable(.answerDidNotArrive(port: "port", after: .seconds(1)))
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.inputMethod.field == " hello" }
        rig.inputMethod.refusing(unanswered)
        rig.inputMethod.landingDespiteFailure()
        try await Self.said([3, 4], in: rig) { rig.inputMethod.field == " hello there" }
        rig.inputMethod.refusing(nil)
        try await Self.said([5, 6], in: rig) { rig.inputMethod.field == " hello there my" }

        Self.cancel(rig)
        let left = try #require(await rig.report().failure as? CancelLeftWords)

        #expect(left.left == 2)
        #expect(left.cause == .refused(.wordsCannotBeTakenBack))
        #expect(rig.inputMethod.field == " hello there my")
        #expect(left.cancelled.standing == 1)
        #expect(failureLine(left).hasPrefix("WARNING: You cancelled a dictation, but 2 of its words are still in com.apple.TextEdit"))
    }

    /// An app that will not give the words back keeps them, and the person is told how many and where.
    @Test func aRefusedTakeBackSaysHowManyWordsStay() async throws {
        let rig = try await Rig(hearing: Self.engine())
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.inputMethod.field == " hello" }
        rig.inputMethod.refusingTakeBack(.refused(.wordsCannotBeTakenBack))

        Self.cancel(rig)
        let left = try #require(await rig.report().failure as? CancelLeftWords)

        #expect(left.left == 1)
        #expect(failureLine(left).hasPrefix("WARNING: You cancelled a dictation, but 1 of its words is still in com.apple.TextEdit, and nothing more was done. "))
        #expect(rig.inputMethod.field == " hello")
        #expect(rig.hold.held == nil)
    }

    /// A take-back whose answer never came may have happened, so it is said as that and is never
    /// asked twice: a second could take words that are not the dictation's.
    @Test func aTakeBackWhoseAnswerIsLostIsNeverRetried() async throws {
        let rig = try await Rig(hearing: Self.engine())
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.inputMethod.field == " hello" }
        rig.inputMethod.refusingTakeBack(.unreachable(.answerDidNotArrive(port: "port", after: .seconds(1))))

        Self.cancel(rig)
        let left = try #require(await rig.report().failure as? CancelLeftWords)

        #expect(rig.inputMethod.takeBacks == [" hello"])
        #expect("\(left)".hasPrefix("WARNING: You cancelled a dictation, but 1 of its words may have been taken back, or may still be in com.apple.TextEdit, and nothing more was done. "))
    }

    /// A take-back is not an insert, so a failed one says why, and what became of the words in the
    /// field, and nothing of what becomes of an insert's: not that a dictation was not inserted or
    /// not sent, nor that it is offered again, nor that it may have landed and must not be said again.
    @Test(arguments: failedInserts.map(\.failure))
    func aFailedTakeBackSaysNothingOfAnInsertsFate(_ failure: InsertFailure) async throws {
        let rig = try await Rig(hearing: Self.engine())
        Self.begin(rig)
        try await Self.said([1, 2], in: rig) { rig.inputMethod.field == " hello" }
        rig.inputMethod.refusingTakeBack(failure)

        Self.cancel(rig)
        let left = try #require(await rig.report().failure as? CancelLeftWords)

        let line = failureLine(left)
        #expect(line.hasPrefix("WARNING: You cancelled a dictation, but 1 of its words "))
        #expect(line.contains(failure.reason), "\(line)")
        for fate in ["not inserted", "not sent", "offered again", "may have been inserted", "do not dictate", "if it recovers"] {
            #expect(!line.contains(fate), "\(line)")
        }
    }

    /// A cancelled press's account agrees with each of its counts, one and more than one.
    @Test(arguments: [
        (1, "1 word taken back, 1 held word let go, 1 heard after the commits dropped; "
            + "1 earlier word delivered with its first insert stays, 1 dismissed word stays dismissed, 1 word that may have landed stands"),
        (2, "2 words taken back, 2 held words let go, 2 heard after the commits dropped; "
            + "2 earlier words delivered with its first insert stay, 2 dismissed words stay dismissed, 2 words that may have landed stand"),
    ])
    func aCancelledPressTellsEachCountInItsNumber(_ count: Int, _ told: String) {
        let cancelled = Cancelled(takenBack: count, earlierWordsLanded: count, forgotten: count, dismissed: count, standing: count, discarded: count)
        #expect("\(cancelled)" == told)
    }
}
