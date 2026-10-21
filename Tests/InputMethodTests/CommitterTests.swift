import Foundation
@testable import InputMethod
import Insertion
import os
import TestProbes
import Testing

/// Committing on the main actor, and how long an answer waits for it.
///
/// [LAW:behavior-not-structure] Held through `TextCursor`, with a cursor that records what it
/// was asked and given. The port giving up is played by waiting on the turn at the moment
/// under test - before the main actor reaches it, while it decides, while it commits - so no
/// case has to hold the main thread to make an app look hung.
@Suite struct CommitterTests {
    /// A cursor in some app, which records what it was given, and runs `during` inside each
    /// commit.
    @MainActor private final class Cursor: TextCursor {
        let application: String
        var committed: [String] = []
        var during: () -> Void = {}

        nonisolated init(in application: String = "com.example.editor") { self.application = application }

        // Never asked here: whether a cursor takes words is decided by `FocusedClient`, and
        // what that decided is handed to the committer as an `InFront`.
        var field: FieldAnswer { .documentAccess(caretLine: nil) }

        func commit(_ text: String) {
            during()
            committed.append(text)
        }
    }

    private static let request = InsertRequest("🫠 hello", into: .cursorInFront)

    /// What `FocusedClient` would have seen: the cursor chosen, or the refusal.
    @MainActor
    private static func seen(_ cursor: Result<any TextCursor, Refusal>) -> InFront {
        InFront(frontmost: "com.example.editor", secureInputHolder: nil, selected: true, cursorApplication: "com.example.editor",
                field: nil, screens: [], cursor: cursor)
    }

    private static let seenLine = "with com.example.editor in front and the cursor in com.example.editor"

    /// The words go in, and the answer counts them as a person would: an emoji is one
    /// character to whoever dictated it.
    @MainActor
    @Test func wordsCommittedInTimeAreAnsweredInsertedWithTheirCount() {
        let cursor = Cursor()
        let turn = Turn()

        let did = Committer.place(Self.request, turn: turn, inFront: { Self.seen(.success(cursor)) })

        #expect(cursor.committed == ["🫠 hello"])
        #expect(turn.wait(.zero) == .answered(.inserted(characters: 7, into: cursor.application), seen: Self.seenLine))
        guard case .committed(7, cursor.application, _, _, late: false) = did else { Issue.record("\(did)"); return }
    }

    @MainActor
    @Test func aRefusalIsAnsweredAndNothingIsCommitted() {
        let turn = Turn()

        let did = Committer.place(Self.request, turn: turn, inFront: { Self.seen(.failure(.noTextFieldHasFocus)) })

        #expect(turn.wait(.zero) == .answered(.refused(.noTextFieldHasFocus), seen: Self.seenLine))
        guard case .refused(.noTextFieldHasFocus, _, late: false) = did else { Issue.record("\(did)"); return }
    }

    /// The port gave up before the main actor reached the insert: it answered busy, so the
    /// main actor makes no call into any app - not even to read the field of one that may be
    /// hung - and commits nothing.
    @MainActor
    @Test func anInsertGivenUpBeforeItIsReachedAsksNoApp() {
        let cursor = Cursor()
        let turn = Turn()
        var decided = 0

        #expect(turn.wait(.zero) == .busy(reached: false))
        let did = Committer.place(Self.request, turn: turn, inFront: {
            decided += 1
            return Self.seen(.success(cursor))
        })

        #expect(did == .letGo)
        #expect(decided == 0)
        #expect(cursor.committed.isEmpty)
    }

    /// The port gave up while the main actor was asking which cursor is in front: it answered
    /// busy, so the words are not committed once the answer arrives.
    @MainActor
    @Test func anInsertGivenUpWhileDecidingIsNotCommitted() {
        let cursor = Cursor()
        let turn = Turn()
        var answered: Placed.Outcome?

        let did = Committer.place(Self.request, turn: turn, inFront: {
            answered = turn.wait(.zero)
            return Self.seen(.success(cursor))
        })

        #expect(answered == .busy(reached: true))
        #expect(cursor.committed.isEmpty)
        guard case .letGoAfterDeciding(_, Self.seenLine) = did else { Issue.record("\(did)"); return }
    }

    /// A refusal decided after the port gave up is still said, and said as late.
    @MainActor
    @Test func aRefusalDecidedAfterThePortGaveUpIsLate() {
        let turn = Turn()

        let did = Committer.place(Self.request, turn: turn, inFront: {
            _ = turn.wait(.zero)
            return Self.seen(.failure(.secureInputIsOn))
        })

        guard case .refused(.secureInputIsOn, _, late: true) = did else { Issue.record("\(did)"); return }
    }

    /// The port gave up while the words were being handed over: it answered that the app has
    /// not taken them yet, naming the app, and the commit finishes - once - and says it
    /// finished late.
    @MainActor
    @Test func aCommitOutlastingThePortsWaitIsNotYetTakenAndFinishesOnce() {
        let cursor = Cursor()
        let turn = Turn()
        var answered: Placed.Outcome?
        cursor.during = { answered = turn.wait(.zero) }

        let did = Committer.place(Self.request, turn: turn, inFront: { Self.seen(.success(cursor)) })

        #expect(answered == .notYetTaken(characters: 7, into: cursor.application, seen: Self.seenLine))
        #expect(cursor.committed == ["🫠 hello"])
        guard case .committed(7, cursor.application, _, _, late: true) = did else { Issue.record("\(did)"); return }
    }

    /// Through the main queue, as the insert port asks: answered in time, the words land in
    /// the order they were asked for, and each turn's end is said.
    @Test func insertsThroughTheMainActorAreAnsweredAndLandInOrder() async {
        let cursor = Cursor()
        let ends = OSAllocatedUnfairLock(initialState: [Ended]())
        let committer = Committer(bound: .seconds(20)) { ended in ends.withLock { $0.append(ended) } }

        let answers = await onAThreadOfItsOwn {
            ["one", "two", "three"].map { word in
                committer.insert(InsertRequest(word, into: .cursorInFront)) { Self.seen(.success(cursor)) }.answer
            }
        }

        #expect(answers == [3, 3, 5].map { .inserted(characters: $0, into: "com.example.editor") })
        #expect(await cursor.committed == ["one", "two", "three"])
        let said = ends.withLock { $0 }
        #expect(said.map(\.insert) == [1, 2, 3])
        #expect(said.allSatisfy { if case .committed(_, _, _, _, late: false) = $0.did { true } else { false } })
    }

    /// Through the main queue while something else holds it - another app's stalled commit, or
    /// anything at all: the port answers busy at its bound, and the main actor, reaching the
    /// insert after that, lets it go without asking any app and says how long it waited.
    @Test func anInsertTheMainActorDoesNotReachInTimeIsBusyAndAsksNoApp() async {
        let cursor = Cursor()
        let decided = OSAllocatedUnfairLock(initialState: 0)
        let ends = OSAllocatedUnfairLock(initialState: [Ended]())
        let committer = Committer(bound: .milliseconds(50)) { ended in ends.withLock { $0.append(ended) } }
        let held = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            held.signal()
            released.wait()
        }

        let placed = await onAThreadOfItsOwn {
            held.wait()
            defer { released.signal() }
            return committer.insert(Self.request) {
                decided.withLock { $0 += 1 }
                return Self.seen(.success(cursor))
            }
        }
        await MainActor.run {}

        #expect(placed.outcome == .busy(reached: false))
        #expect(placed.answer == .refused(.inputMethodIsBusy))
        let said = ends.withLock { $0 }
        #expect(said.map(\.did) == [.letGo])
        #expect(said.allSatisfy { $0.waited >= .milliseconds(50) })
        #expect(decided.withLock { $0 } == 0)
        #expect(await cursor.committed.isEmpty)
    }

    /// The port's line for each way its wait can end, numbered as the main actor's line is.
    @Test func thePortsLineSaysWhatItKnewWhenItAnswered() {
        func line(_ outcome: Placed.Outcome) -> String { Placed(insert: 4, request: Self.request, outcome: outcome).description }
        let head = "insert 4 of 7 characters into the cursor in front: "

        let inserted = InsertionAnswer.inserted(characters: 7, into: "com.apple.TextEdit")
        let notYet = InsertionAnswer.notYetTaken(characters: 7, into: "com.apple.TextEdit")
        let busy = InsertionAnswer.refused(.inputMethodIsBusy)

        #expect(line(.answered(inserted, seen: Self.seenLine)) == head + "\(inserted), " + Self.seenLine)
        #expect(line(.notYetTaken(characters: 7, into: "com.apple.TextEdit", seen: Self.seenLine))
            == head + "\(notYet), " + Self.seenLine + ", still committing when time ran out")
        #expect(line(.busy(reached: false))
            == head + "\(busy), without knowing what is in front, since the main thread did not reach the insert in time")
        #expect(line(.busy(reached: true))
            == head + "\(busy), without knowing what is in front, since the main thread was still deciding what is in front when time ran out")
        #expect(Placed(insert: 4, request: Self.request, outcome: .busy(reached: true)).answer == .refused(.inputMethodIsBusy))
    }

    /// The main actor's line for each thing a turn can do there, with how long it waited for
    /// it and how long it held it.
    @Test func theMainActorsLineSaysWhatTheTurnDidAndForHowLong() {
        func line(_ did: Ended.Did) -> String { Ended(insert: 4, waited: .microseconds(800), did: did).description }
        let main = "insert 4 on the main thread, reached after 0.8 ms: "

        #expect(line(.letGo) == main + "let go before any call into an app, since the port had already answered that the input method is busy")
        #expect(line(.letGoAfterDeciding(deciding: .milliseconds(2900), seen: Self.seenLine))
            == main + "let go after 2900.0 ms deciding \(Self.seenLine), since the port had already answered that the input method is busy; nothing was committed")
        #expect(line(.refused(.noTextFieldHasFocus, deciding: .microseconds(1500), late: false)) == main + "refused noClientHasFocus after 1.5 ms deciding")
        #expect(line(.refused(.noTextFieldHasFocus, deciding: .microseconds(1500), late: true))
            == main + "refused noClientHasFocus after 1.5 ms deciding, after the port had answered that the input method is busy")
        #expect(line(.committed(characters: 7, into: "com.apple.TextEdit", deciding: .milliseconds(2), committing: .milliseconds(12), late: false))
            == main + "2.0 ms deciding, then 12.0 ms committing 7 characters into com.apple.TextEdit")
        #expect(line(.committed(characters: 7, into: "com.apple.TextEdit", deciding: .milliseconds(2), committing: .milliseconds(2950), late: true))
            == main + "2.0 ms deciding, then 2950.0 ms committing 7 characters into com.apple.TextEdit, finishing after the port had answered that they were not yet taken")
    }

    /// The answer naming a hung app has to reach the app before the app stops listening, which
    /// it does after one of its four phases; and it has to come before IMK's own wait on a hung
    /// app runs out, 3 s on the main thread (measured on low-input-method-s71.c7d), since past
    /// that `insertText` returns as if the words were taken.
    @Test func theWaitEndsBeforeTheAppsPhaseAndBeforeIMKGivesUp() {
        #expect(Committer.standardBound < InputMethodInserter.standardTimeout / 4)
        #expect(Committer.standardBound < .seconds(3))
    }
}
