import Foundation
import Insertion
import InsertionFakes
import LowTalkerCore
import os
import Testing
import TestProbes
@testable import Dictation

/// What a cancel takes back, built from the inserts that landed in the order the field holds
/// them, as each was answered landing, and asked of the fake input method, which proves it against
/// the field by the input method's own rule (`Replacement`). [LAW:behavior-not-structure] Read off
/// the field it leaves.
@Suite @MainActor struct TakeBackTests {
    /// Inserts `texts` at the cursor, as a press's inserts put them, and answers each as it landed.
    private static func field(_ inputMethod: FakeInputMethod, _ texts: String...) async throws -> [Executor.Performed] {
        let executor = Executor(insertingThrough: inputMethod, clock: .system)
        var performed: [Executor.Performed] = []
        for text in texts {
            performed.append(try #require(try await executor.insert(Transcript(typed: text), following: performed.last, since: .keyUp(.now))))
        }
        return performed
    }

    /// A held part of runs said by each owner, as the hold carries it ahead of an insert's words.
    private static func carried(_ runs: (String, (any Held.Owner)?)...) -> Held.Part? {
        Held.Part(runs: runs.map { Held.Run(words: Transcript(typed: $0.0).words, warning: "held", by: $0.1) })
    }

    /// The press's first commit lands, and a later insert carries earlier dictation and the
    /// press's own held words ahead of its next ones, so its words sit on both sides of the
    /// earlier dictation: all of them are taken back, and the earlier dictation is left where
    /// it was delivered, counted in the line as it landed fitted again.
    @Test func thePresssWordsOnBothSidesOfEarlierDictationAreTakenBack() async throws {
        let press = Speaker(), earlier = Speaker()
        let inputMethod = FakeInputMethod()
        let performed = try await Self.field(inputMethod, " hello", " first again there")
        var landed = TakeBack()
        landed.landed(performed[0].landed, carrying: nil, then: Transcript(typed: " hello"), of: press)
        landed.landed(performed[1].landed, carrying: Self.carried((" first", earlier), (" again", press)), then: Transcript(typed: " there"), of: press)
        inputMethod.landing { $0 + "." }
        let since = Date.now

        try await Executor(insertingThrough: inputMethod, clock: .system, log: Logger(subsystem: "lowtalker", category: "take-back-both-sides"))
            .takeBack(landed, from: performed[1])

        #expect(inputMethod.field == " first.")
        #expect(landed.words == 3)
        #expect(landed.earlierWords == 1)
        let lines = try await loggedLines(category: "take-back-both-sides", since: since)
        #expect(lines.contains {
            $0.hasPrefix("took back 17 UTF-16 units from com.apple.TextEdit, replacing 24 before the caret with 7 of earlier dictation, in ")
        })
    }

    /// Earlier dictation ahead of the press's first word, in the same insert, is taken back with it
    /// and put back in its place: the input method fitted the insert whole, so where the earlier
    /// words end inside it is not known here.
    @Test func earlierDictationInThePresssFirstInsertIsPutBack() async throws {
        let press = Speaker()
        let inputMethod = FakeInputMethod()
        let performed = try await Self.field(inputMethod, "old words hello")
        var landed = TakeBack()
        landed.landed(performed[0].landed, carrying: Self.carried(("old words", nil)), then: Transcript(typed: " hello"), of: press)

        try await Executor(insertingThrough: inputMethod, clock: .system).takeBack(landed, from: performed[0])

        #expect(inputMethod.takeBacks == ["old words hello"])
        #expect(inputMethod.field == "old words")
        #expect(landed.earlierWords == 2)
    }

    /// What is taken back is what the input method answered landed, not what was sent: words it
    /// fitted to the field are found there as they were fitted.
    @Test func wordsAreTakenBackAsTheyLanded() async throws {
        let press = Speaker()
        let inputMethod = FakeInputMethod()
        inputMethod.landing { $0.capitalized }
        let performed = try await Self.field(inputMethod, " hello there")
        var landed = TakeBack()
        landed.landed(performed[0].landed, carrying: nil, then: Transcript(typed: " hello there"), of: press)

        try await Executor(insertingThrough: inputMethod, clock: .system).takeBack(landed, from: performed[0])

        #expect(inputMethod.takeBacks == [" Hello There"])
        #expect(inputMethod.field == "")
    }

    /// A field that no longer holds the stretch as the press put it is refused, and changes nothing.
    @Test func aStretchTheFieldNoLongerHoldsIsRefused() async throws {
        let press = Speaker()
        let inputMethod = FakeInputMethod()
        let performed = try await Self.field(inputMethod, " hello", " first", " typed", " there")
        var landed = TakeBack()
        landed.landed(" hello", carrying: nil, then: Transcript(typed: " hello"), of: press)
        landed.landed(" first there", carrying: Self.carried((" first", nil)), then: Transcript(typed: " there"), of: press)

        await #expect(throws: InsertFailure.refused(.wordsCannotBeTakenBack)) {
            try await Executor(insertingThrough: inputMethod, clock: .system).takeBack(landed, from: performed[3])
        }
        #expect(inputMethod.field == " hello first typed there")
    }

    /// An insert that landed only earlier dictation put none of the press's words in the field,
    /// so there is nothing to take back and nothing is asked.
    @Test func onlyEarlierDictationLandedAsksNothing() async throws {
        let inputMethod = FakeInputMethod()
        let performed = try await Self.field(inputMethod, "old words")
        var landed = TakeBack()
        landed.landed(performed[0].landed, carrying: Self.carried(("old words", nil)), then: Transcript(words: []), of: Speaker())

        try await Executor(insertingThrough: inputMethod, clock: .system).takeBack(landed, from: performed[0])

        #expect(inputMethod.asked == 1)
        #expect(inputMethod.field == "old words")
        #expect(landed.earlierWords == 2)
    }
}
