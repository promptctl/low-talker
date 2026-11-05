import Foundation
@testable import InputMethod
import Insertion
import os
import Testing

/// What happens to a Return the input method is handed, for each thing the app can say about the
/// words it owes. [LAW:behavior-not-structure] The app is a fake with the two answers a case
/// chooses; what is held is the verdict, and for the case that matters most, that the words are
/// committed before the Return is let through.
@Suite struct SteeringGateTests {
    /// The app as the gate asks it, answering each question with what the case gave it.
    private struct App: SteeringAsking {
        var owing: @Sendable () -> Result<Owing, NotAnswered> = { .success(.words) }
        var settling: @Sendable () -> Result<Settlement, NotAnswered> = { .success(.landed) }
        var cancelling: @Sendable () -> Result<Cancellation, NotAnswered> = { .success(.dictation) }

        func owed(at _: TimeInterval, within _: Duration) -> Result<Owing, NotAnswered> { owing() }
        func settled(at _: TimeInterval, within _: Duration) -> Result<Settlement, NotAnswered> { settling() }
        func cancel(at _: TimeInterval, within _: Duration) -> Result<Cancellation, NotAnswered> { cancelling() }
    }

    /// A list that a thread other than the test's appends to.
    private final class Log: Sendable {
        private let lines = OSAllocatedUnfairLock(initialState: [String]())
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    @MainActor private final class Cursor: TextCursor {
        let application = "com.example.editor"
        var committed: [String] = []
        var field: FieldAnswer { .documentAccess(caretLine: nil) }
        nonisolated init() {}
        func commit(_ text: String, replacing _: String) -> Refusal? {
            committed.append(text)
            return nil
        }
    }

    @MainActor
    private static func inFront(_ cursor: Cursor) -> InFront {
        InFront(frontmost: cursor.application, secureInputHolder: nil, selected: true, cursorApplication: cursor.application,
                field: nil, screens: [], cursor: .success(cursor))
    }

    private static let farOff = Duration.seconds(30)

    @MainActor
    @Test func nothingOwedPassesAtOnceAndTheSecondQuestionIsNotAsked() {
        let asked = Log()
        let gate = SteeringGate(ceiling: Self.farOff, asking: App(
            owing: { asked.add("owing"); return .success(.nothing) },
            settling: { asked.add("settled"); return .success(.landed) }))

        #expect(gate.verdict(for: .return, at: 1) == .pass)
        #expect(asked.all == ["owing"])
    }

    /// The case this exists for. The app owes a tail; the insert it makes while the Return is held
    /// is committed by the thread holding it, so the words are in the field before the Return is
    /// let through to the app.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func wordsOwedAreCommittedBeforeTheReturnPasses() {
        let cursor = Cursor()
        let turns = MainTurns()
        let committer = Committer(bound: Self.farOff, turns: turns) { _ in }
        let order = Log()
        let gate = SteeringGate(turns: turns, ceiling: Self.farOff, asking: App(settling: {
            let placed = committer.insert(InsertRequest("the tail", into: .cursorInFront)) { Self.inFront(cursor) }
            order.add("the app was answered \(placed.answer)")
            return .success(.landed)
        }))

        let verdict = gate.verdict(for: .return, at: 1)
        order.add("the Return was let through: \(verdict == .pass)")

        #expect(cursor.committed == ["the tail"])
        #expect(order.all == [
            "the app was answered \(InsertionAnswer.inserted(characters: 8, into: cursor.application))",
            "the Return was let through: true",
        ])
    }

    @MainActor
    @Test func wordsThatDidNotAllLandKeepTheReturn() {
        let gate = SteeringGate(ceiling: Self.farOff, asking: App(settling: { .success(.notLanded) }))
        #expect(gate.verdict(for: .return, at: 1) == .keep)
    }

    /// A debt the app admitted and then did not settle is not a debt that was settled.
    @MainActor
    @Test(arguments: [NotAnswered.silent(after: .seconds(5)), .abandoned, .notReadable(bytes: 3)])
    func aDebtTheAppAdmittedAndDidNotSettleKeepsTheReturn(why: NotAnswered) {
        let gate = SteeringGate(ceiling: Self.farOff, asking: App(settling: { .failure(why) }))
        #expect(gate.verdict(for: .return, at: 1) == .keep)
    }

    /// The Return is held only against a debt the app has admitted to: an app that cannot be
    /// reached, or cannot say, has admitted none, and the Return passes as it would with no
    /// LowTalker at all.
    @MainActor
    @Test(arguments: [NotAnswered.nobodyIsListening(port: "p"), .silent(after: .milliseconds(100)), .abandoned, .notReadable(bytes: 0)])
    func anAppThatAdmitsNoDebtLetsTheReturnPass(why: NotAnswered) {
        let asked = Log()
        let gate = SteeringGate(ceiling: Self.farOff, asking: App(
            owing: { .failure(why) }, settling: { asked.add("settled"); return .success(.notLanded) }))

        #expect(gate.verdict(for: .return, at: 1) == .pass)
        #expect(asked.all.isEmpty)
    }

    /// The ceiling protects the keyboard: a debt not settled by it is kept, at it, and the thread
    /// that was asking is left to end by itself.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func aDebtNotSettledByTheCeilingKeepsTheReturnAtTheCeiling() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let gate = SteeringGate(ceiling: .milliseconds(150), asking: App(settling: { release.wait(); return .success(.landed) }))

        let started = ContinuousClock.now
        #expect(gate.verdict(for: .return, at: 1) == .keep)
        #expect(ContinuousClock.now - started >= .milliseconds(150))
    }

    /// A Return typed after one the gate gave up on is decided on its own answers: the earlier
    /// one's late answer, which says the words did not land, is read by nobody.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func anEarlierReturnsLateAnswerIsNotTheNextOnes() {
        let release = DispatchSemaphore(value: 0)
        let earlierAnswered = DispatchSemaphore(value: 0)
        let gate = SteeringGate(ceiling: .milliseconds(500), asking: App(settling: {
            release.wait()
            defer { earlierAnswered.signal() }
            return .success(.notLanded)
        }))
        #expect(gate.verdict(for: .return, at: 1) == .keep)

        gate.connect(App(settling: {
            release.signal()
            earlierAnswered.wait()
            return .success(.landed)
        }))
        #expect(gate.verdict(for: .return, at: 2) == .pass)
    }

    /// Before an app is connected nobody admits anything, so every Return passes.
    @MainActor
    @Test func aGateNoAppWasConnectedToPassesEveryReturn() {
        #expect(SteeringGate().verdict(for: .return, at: 1) == .pass)
    }

    // MARK: - Escape

    /// An Escape typed with nothing owed is the app's to receive, as it always was, and the app is
    /// not asked to cancel anything.
    @MainActor
    @Test func anEscapeTypedWithNothingOwedPassesAndNothingIsCancelled() {
        let asked = Log()
        let gate = SteeringGate(ceiling: Self.farOff, asking: App(
            owing: { .success(.nothing) },
            cancelling: { asked.add("cancel"); return .success(.dictation) }))

        #expect(gate.verdict(for: .escape, at: 1) == .pass)
        #expect(asked.all == [])
    }

    /// A dictation thrown away spends the Escape, so the app in front never sees it.
    @MainActor
    @Test func anEscapeThatCancelledADictationIsKept() {
        let gate = SteeringGate(ceiling: Self.farOff, asking: App(cancelling: { .success(.dictation) }))
        #expect(gate.verdict(for: .escape, at: 1) == .keep)
    }

    /// A debt that was only a finished press's tail has no dictation to cancel, so the Escape is the
    /// app's, as typed.
    @MainActor
    @Test func anEscapeWithNoDictationOpenToCancelPasses() {
        let gate = SteeringGate(ceiling: Self.farOff, asking: App(cancelling: { .success(.nothing) }))
        #expect(gate.verdict(for: .escape, at: 1) == .pass)
    }

    /// The app admitted a debt and then did not say what became of the Escape: it may have cancelled,
    /// so the Escape is kept, as a Return whose debt did not settle is.
    @MainActor
    @Test func anEscapeTheAppAdmittedADebtForAndDidNotAnswerIsKept() {
        let gate = SteeringGate(ceiling: Self.farOff, asking: App(cancelling: { .failure(.silent(after: .seconds(5))) }))
        #expect(gate.verdict(for: .escape, at: 1) == .keep)
    }

    @MainActor
    @Test(arguments: [NotAnswered.nobodyIsListening(port: "port"), .silent(after: .milliseconds(100)), .abandoned])
    func anEscapeTheAppAdmittedNothingForPasses(why: NotAnswered) {
        let gate = SteeringGate(ceiling: Self.farOff, asking: App(owing: { .failure(why) }))
        #expect(gate.verdict(for: .escape, at: 1) == .pass)
    }

    @MainActor
    @Test func aGateNoAppWasConnectedToPassesEveryEscape() {
        #expect(SteeringGate().verdict(for: .escape, at: 1) == .pass)
    }

    /// The ceiling is the longest the app itself waits on an insert, one number and not two, and
    /// the app is asked whether anything is owed in far less than the Return may be held.
    @Test func theCeilingIsWhatTheAppWaitsOnAnInsert() {
        #expect(SteeringGate.standardCeiling == InputMethodInserter.standardTimeout)
        #expect(SteeringGate.standardQuestion < SteeringGate.standardCeiling)
    }
}
