import Foundation
import Insertion
import InsertionFakes
import LowTalkerCore
import os
import Testing
import TestProbes
@testable import Dictation

/// What a cancel takes back, built from the inserts that landed in the order the field holds
/// them, and asked of the fake input method, which proves it against the field by the input
/// method's own rule (`Replacement`). [LAW:behavior-not-structure] Read off the field it leaves.
@Suite @MainActor struct TakeBackTests {
    /// Inserts `texts` at the cursor, as a press's inserts put them, and answers the last.
    private static func field(_ inputMethod: FakeInputMethod, _ texts: String...) async throws -> Executor.Performed {
        let executor = Executor(insertingThrough: inputMethod)
        var last: Executor.Performed?
        for text in texts { last = try await executor.insert(Transcript(typed: text), following: last, since: .keyUp(.now)) }
        return try #require(last)
    }

    /// The press's first commit lands, and a later insert carries earlier dictation ahead of the
    /// press's next words, so its words sit on both sides of it: all of them are taken back, and
    /// the earlier dictation is left where it was delivered.
    @Test func thePresssWordsOnBothSidesOfEarlierDictationAreTakenBack() async throws {
        var landed = TakeBack()
        landed.landed(Transcript(typed: " hello"), own: true)
        landed.landed(Transcript(typed: " first"), own: false)
        landed.landed(Transcript(typed: " there"), own: true)
        let inputMethod = FakeInputMethod()
        let last = try await Self.field(inputMethod, " hello", " first there")
        let since = Date.now

        try await Executor(insertingThrough: inputMethod, log: Logger(subsystem: "lowtalker", category: "take-back-both-sides")).takeBack(landed, from: last)

        #expect(inputMethod.field == " first")
        #expect(landed.words == 2)
        #expect(landed.earlierWords == 1)
        let lines = try await loggedLines(category: "take-back-both-sides", since: since)
        #expect(lines.contains { $0.hasPrefix("took back 18 UTF-16 units from com.apple.TextEdit, putting back 6 of earlier dictation, in ") })
    }

    /// Earlier dictation ahead of the press's first word is not between anything taken back, so
    /// the request names only the press's words, and the earlier ones are not rewritten.
    @Test func earlierDictationAheadOfThePresssFirstWordIsNotReplaced() async throws {
        var landed = TakeBack()
        landed.landed(Transcript(typed: "old words"), own: false)
        landed.landed(Transcript(typed: " hello"), own: true)
        let inputMethod = FakeInputMethod()
        let last = try await Self.field(inputMethod, "old words hello")

        try await Executor(insertingThrough: inputMethod).takeBack(landed, from: last)

        #expect(inputMethod.takeBacks == [" hello"])
        #expect(inputMethod.field == "old words")
        #expect(landed.earlierWords == 2)
    }

    /// A field that no longer holds the stretch as the press put it is refused, and changes nothing.
    @Test func aStretchTheFieldNoLongerHoldsIsRefused() async throws {
        var landed = TakeBack()
        landed.landed(Transcript(typed: " hello"), own: true)
        landed.landed(Transcript(typed: " first"), own: false)
        landed.landed(Transcript(typed: " there"), own: true)
        let inputMethod = FakeInputMethod()
        let last = try await Self.field(inputMethod, " hello", " first", " typed", " there")

        await #expect(throws: InsertFailure.refused(.wordsCannotBeTakenBack)) {
            try await Executor(insertingThrough: inputMethod).takeBack(landed, from: last)
        }
        #expect(inputMethod.field == " hello first typed there")
    }

    /// A press with nothing landed asks nothing.
    @Test func nothingLandedAsksNothing() async throws {
        let inputMethod = FakeInputMethod()
        let last = try await Self.field(inputMethod, "old words")
        var landed = TakeBack()
        landed.landed(Transcript(typed: "old words"), own: false)

        try await Executor(insertingThrough: inputMethod).takeBack(landed, from: last)

        #expect(inputMethod.asked == 1)
        #expect(inputMethod.field == "old words")
    }
}
