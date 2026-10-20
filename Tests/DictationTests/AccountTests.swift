import Dictation
import Insertion
import LowTalkerCore
import Testing
import TestProbes

/// What a failed press tells the log: its facts in the clear, and the words the person
/// dictated, when it carries any, apart from them.
@MainActor
@Suite struct AccountTests {
    /// A reading the engine could not turn into a transcript carries what was said. Through
    /// the loop it reaches the report with those words apart from the facts, and the facts
    /// still say what went wrong and how many words had already landed.
    @Test func wordsAReadingCarriesAreKeptApartFromItsFacts() async throws {
        let said = " the rest of what was said"
        let engine = FakeTranscriber(confirming: { samples in Transcript(typed: samples.count >= 2 ? "hello there" : "") }) { _ throws(TranscriptionFailure) in
            throw .unreadable(.speechWithoutWords(text: said))
        }
        let rig = try await Rig(hearing: engine)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello there"] })
        rig.keyUp()
        let stopped = try #require(await rig.report().failure as? PressStopped)

        #expect(stopped.account == Account(
            facts: "2 words inserted before: WhisperKit returned a segment of \(said.count) characters without word timings",
            dictated: said))
    }

    /// A failure that states only facts is logged whole, with nothing held apart.
    @Test(arguments: [
        TranscriptionFailure.nothingSpoken(peak: 0.004, quiet: Quiet(letGo: 1, room: 0.002, refusedAsRoom: 0, refusedAsNotSpeech: 0, transients: .none, range: nil, keptOut: nil, keptOutFrames: 0)),
        .vocabulary(.tooLong(tokens: 300, limit: 224)),
        .cancelled,
    ])
    func aTranscriptionFailureOfFactsIsLoggedWhole(failure: TranscriptionFailure) {
        #expect(failure.account == Account(facts: failure.description))
    }

    @Test(arguments: Refusal.allCases)
    func anInsertRefusalIsLoggedWhole(refusal: Refusal) {
        let failure = InsertFailure.refused(refusal)
        #expect(failure.account == Account(facts: failure.description))
    }
}
