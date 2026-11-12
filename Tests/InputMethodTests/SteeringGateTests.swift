import Foundation
@testable import InputMethod
import InputMethodFakes
import Insertion
import InsertionFakes
import os
import Testing

/// What happens to a Return the input method is handed, for each thing the app can say about the
/// words it owes. [LAW:behavior-not-structure] The app is a fake with the two answers a case
/// chooses; what is held is the verdict, and for the case that matters most, that the words are
/// committed before the Return is let through.
@Suite struct SteeringGateTests {
    /// A list that a thread other than the test's appends to.
    private final class Log: Sendable {
        private let lines = OSAllocatedUnfairLock(initialState: [String]())
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    @MainActor
    private static func inFront(_ cursor: Client) -> InFront {
        InFront(frontmost: cursor.application, selected: true, cursorApplication: cursor.application, cursors: 1, ruledOut: 0,
                field: nil, screens: [], cursor: .success(cursor))
    }

    private static let farOff = Duration.seconds(30)

    @MainActor
    @Test func nothingOwedPassesAtOnceAndTheSecondQuestionIsNotAsked() {
        let asked = Log()
        let gate = SteeringGate(ceiling: Self.farOff, asking: FakeApp(
            owing: { asked.add("owing"); return .success(.nothing) },
            settling: { asked.add("settled"); return .success(.landed) }))

        #expect(gate.verdict(at: 1).verdict == .pass)
        #expect(asked.all == ["owing"])
    }

    /// The case this exists for. The app owes a tail; the insert it makes while the Return is held
    /// is committed by the thread holding it, so the words are in the field before the Return is
    /// let through to the app.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func wordsOwedAreCommittedBeforeTheReturnPasses() throws {
        let field = FakeTextInputClient()
        let cursor = try field.cursor()
        let turns = MainTurns()
        let committer = Committer(bound: Self.farOff, turns: turns) { _ in }
        let order = Log()
        let gate = SteeringGate(turns: turns, ceiling: Self.farOff, asking: FakeApp(owing: { .success(.words) }, settling: {
            let placed = committer.insert(InsertRequest("the tail", into: .cursorInFront)) { Self.inFront(cursor) }
            order.add("the app was answered \(placed.answer)")
            return .success(.landed)
        }))

        let verdict = gate.verdict(at: 1).verdict
        order.add("the Return was let through: \(verdict == .pass)")

        #expect(field.text == "the tail")
        #expect(order.all == [
            "the app was answered \(InsertionAnswer.inserted(characters: 8, into: cursor.application))",
            "the Return was let through: true",
        ])
    }

    @MainActor
    @Test func wordsThatDidNotAllLandKeepTheReturn() {
        let gate = SteeringGate(ceiling: Self.farOff, asking: FakeApp(owing: { .success(.words) }, settling: { .success(.notLanded) }))
        #expect(gate.verdict(at: 1).verdict == .keep)
    }

    /// A debt the app admitted and then did not settle is not a debt that was settled.
    @MainActor
    @Test(arguments: [NotAnswered.wire(.noAnswer(port: "p", after: .seconds(5))), .wire(.notTaken(port: "p", after: .seconds(5))), .wire(.abandoned(port: "p")), .wire(.notReadable(port: "p", bytes: 3))])
    func aDebtTheAppAdmittedAndDidNotSettleKeepsTheReturn(why: NotAnswered) {
        let gate = SteeringGate(ceiling: Self.farOff, asking: FakeApp(owing: { .success(.words) }, settling: { .failure(why) }))
        #expect(gate.verdict(at: 1).verdict == .keep)
    }

    /// The Return is held only against a debt the app has admitted to: an app that cannot be
    /// reached, or cannot say, has admitted none, and the Return passes as it would with no
    /// LowTalker at all.
    @MainActor
    @Test(arguments: [NotAnswered.wire(.nobodyIsListening(port: "p")), .wire(.notTaken(port: "p", after: .milliseconds(100))), .wire(.noAnswer(port: "p", after: .milliseconds(100))), .wire(.abandoned(port: "p")), .wire(.notReadable(port: "p", bytes: 0))])
    func anAppThatAdmitsNoDebtLetsTheReturnPass(why: NotAnswered) {
        let asked = Log()
        let gate = SteeringGate(ceiling: Self.farOff, asking: FakeApp(
            owing: { .failure(why) }, settling: { asked.add("settled"); return .success(.notLanded) }))

        #expect(gate.verdict(at: 1).verdict == .pass)
        #expect(asked.all.isEmpty)
    }

    /// The ceiling protects the keyboard: a debt not settled by it is kept, at it, and the thread
    /// that was asking is left to end by itself.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func aDebtNotSettledByTheCeilingKeepsTheReturnAtTheCeiling() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let gate = SteeringGate(ceiling: .milliseconds(20), asking: FakeApp(owing: { .success(.words) }, settling: { release.wait(); return .success(.landed) }))

        let started = ContinuousClock.now
        let decided = gate.verdict(at: 1)
        #expect(decided.verdict == .keep)
        #expect(decided.because.contains("had not answered"), "\(decided)")
        #expect(ContinuousClock.now - started >= .milliseconds(20))
    }

    /// A Return typed after one the gate gave up on is decided on its own answers: the earlier
    /// one's late answer, which says the words did not land, is read by nobody.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func anEarlierReturnsLateAnswerIsNotTheNextOnes() {
        let release = DispatchSemaphore(value: 0)
        let earlierAnswered = DispatchSemaphore(value: 0)
        // Long enough for the second Return's handshake with the first's thread under a loaded suite.
        let gate = SteeringGate(ceiling: .milliseconds(500), asking: FakeApp(owing: { .success(.words) }, settling: {
            release.wait()
            defer { earlierAnswered.signal() }
            return .success(.notLanded)
        }))
        #expect(gate.verdict(at: 1).verdict == .keep)

        gate.connect(FakeApp(owing: { .success(.words) }, settling: {
            release.signal()
            earlierAnswered.wait()
            return .success(.landed)
        }))
        #expect(gate.verdict(at: 2).verdict == .pass)
    }

    /// Before an app is connected nobody admits anything, so every Return passes.
    @MainActor
    @Test func aGateNoAppWasConnectedToPassesEveryReturn() {
        #expect(SteeringGate().verdict(at: 1).verdict == .pass)
    }

    // MARK: - Escape

    /// An Escape the app put its word box away with is kept: it did what it was typed for.
    @MainActor
    @Test func anEscapeTheAppDismissedTheBoxWithIsKept() {
        let gate = SteeringGate(ceiling: Self.farOff, asking: FakeApp(dismissing: { .success(.dismissed) }))
        #expect(gate.escapeVerdict(at: 1).verdict == .keep)
    }

    /// An Escape with no box shown when the app acts on it, the box having closed since the key
    /// was typed included, is the app in front's, as typed.
    @MainActor
    @Test func anEscapeWithNoBoxShownPasses() {
        let gate = SteeringGate(ceiling: Self.farOff, asking: FakeApp(dismissing: { .success(.nothingShown) }))
        #expect(gate.escapeVerdict(at: 1).verdict == .pass)
    }

    /// An app that does not say what it did with the Escape has said nothing, so the Escape passes.
    @MainActor
    @Test(arguments: [NotAnswered.wire(.nobodyIsListening(port: "port")), .wire(.noAnswer(port: "p", after: .milliseconds(100))), .wire(.abandoned(port: "p"))])
    func anEscapeTheAppDoesNotAnswerForPasses(why: NotAnswered) {
        let gate = SteeringGate(ceiling: Self.farOff, asking: FakeApp(dismissing: { .failure(why) }))
        #expect(gate.escapeVerdict(at: 1).verdict == .pass)
    }

    /// With no app connected, nothing is shown and every Escape passes.
    @MainActor
    @Test func anEscapeWithNoAppConnectedPasses() {
        #expect(SteeringGate().escapeVerdict(at: 1).verdict == .pass)
    }

    /// The ceiling is the longest the app itself waits on an insert, one number and not two, and
    /// the app is asked whether anything is owed in far less than the Return may be held.
    @Test func theCeilingIsWhatTheAppWaitsOnAnInsert() {
        #expect(SteeringGate.standardCeiling == InputMethodInserter.standardTimeout)
        #expect(SteeringGate.standardQuestion < SteeringGate.standardCeiling)
    }
}
