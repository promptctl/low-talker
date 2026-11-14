import Foundation
import Insertion
import InsertionFakes
import LowTalkerCore
import Testing
@testable import Dictation

/// The executor: the words are asked of the input method, and what it
/// does not put at the cursor is a failure, thrown by name.
///
/// [LAW:behavior-not-structure] Asked through `Inserter`, which is one method and mentions
/// no port and no macOS - so every case here runs with no second process, no input source
/// selected, and nothing at a real cursor. What cannot be asked of a double is whether the
/// words appear in a window, and that is the live checkpoint, not a thing to mock an answer to.
@Suite @MainActor struct InsertingExecutorTests {
    /// `nonisolated` where the suite is not: a bundle id is a value, and the double that
    /// names one is asked on a thread of the executor's choosing rather than on this actor.
    nonisolated static let textEdit = BundleID(rawValue: "com.apple.TextEdit")
    nonisolated static let slack = BundleID(rawValue: "com.tinyspeck.slackmacgap")

    private static func inserting(into app: BundleID) -> FakeInputMethod {
        let inputMethod = FakeInputMethod()
        inputMethod.reaching(app.rawValue)
        return inputMethod
    }

    @Test func wordsAtTheFocusAreInsertedAtTheCursor() async throws {
        let inputMethod = Self.inserting(into: Self.textEdit)
        let performed = try #require(await Executor(insertingThrough: inputMethod, clock: .system)
            .insert(Transcript(typed: "héllo there"), following: nil, since: .keyUp(.now)))

        #expect(inputMethod.inserted == ["héllo there"])
        #expect(performed.into == Self.textEdit)
        #expect(performed.characters == 11)
        #expect("\(performed)".hasPrefix("inserted 11 characters at the cursor in com.apple.TextEdit, key-up to acknowledged "))
    }

    /// The app the outcome names is the app the input method says it reached, which is not
    /// always the one in front at key-down: the person holds the chord in one
    /// window and is somewhere else by the time the words are ready, and the input method
    /// commits where the cursor is then. [FRAMING:representation]
    @Test func theAppNamedIsTheOneTheInputMethodReached() async throws {
        let performed = try #require(await Executor(insertingThrough: Self.inserting(into: Self.slack), clock: .system)
            .insert(Transcript(typed: "hi"), following: nil, since: .keyUp(.now)))

        #expect(performed.into == Self.slack)
        #expect("\(performed)".hasPrefix("inserted 2 characters at the cursor in com.tinyspeck.slackmacgap, key-up to acknowledged "))
    }

    /// A dictation's first words go to the cursor in front, and each insert after them only
    /// to the app the one before it reached.
    @Test func eachInsertIsBoundToTheAppTheOneBeforeItReached() async throws {
        let inputMethod = Self.inserting(into: Self.textEdit)
        let executor = Executor(insertingThrough: inputMethod, clock: .system)
        let first = try #require(await executor.insert(Transcript(typed: "one"), following: nil, since: .keyDown(.now)))
        let second = try #require(await executor.insert(Transcript(typed: " two"), following: first, since: .keyDown(.now)))
        _ = try await executor.insert(Transcript(typed: " three"), following: second, since: .keyUp(.now))

        #expect(inputMethod.destinations == [.cursorInFront, .app(Self.textEdit.rawValue), .app(Self.textEdit.rawValue)])
    }

    /// Nothing said is nothing inserted: the input method is never asked.
    @Test func aBlankTranscriptInsertsNothing() async throws {
        let inputMethod = Self.inserting(into: Self.textEdit)
        let executor = Executor(insertingThrough: inputMethod, clock: .system)
        for blank in [Transcript(words: []), Transcript(words: [.init(text: " ", time: 0...0, confidence: 1.0)])] {
            #expect(try await executor.insert(blank, following: nil, since: .keyUp(.now)) == nil)
        }
        #expect(inputMethod.asked == 0)
    }

    /// Every way an insert fails is thrown as it is, with nothing performed: the words are not
    /// at the cursor, and nothing puts them anywhere else.
    @Test(arguments: failedInserts)
    func aFailedInsertIsThrownAsItIs(failed: FailedInsert) async throws {
        let inputMethod = FakeInputMethod()
        inputMethod.refusing(failed.failure)
        let thrown = try await #require(throws: InsertFailure.self) {
            try await Executor(insertingThrough: inputMethod, clock: .system)
                .insert(Transcript(typed: "héllo there"), following: nil, since: .keyUp(.now))
        }

        #expect(thrown == failed.failure)
    }
}
