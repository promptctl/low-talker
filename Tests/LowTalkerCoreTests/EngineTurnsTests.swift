@testable import LowTalkerCore
import Synchronization
import Testing
import TestProbes

/// The engine owner's rule: a hold takes the engine at once, a served decode it cancelled
/// runs again once every hold lets go, and served callers see only the wait.
///
/// A decode that stands in for a long one sleeps until it is cancelled, which is what a
/// WhisperKit decode does when its task is: it throws `CancellationError`.
@Suite struct EngineTurnsTests {
    private static func soon(_ condition: () -> Bool) async throws -> Bool {
        try await holds(within: .seconds(10), askingEvery: .milliseconds(2), condition)
    }

    @Test func aHoldCancelsTheServedDecodeInFlightWhichRunsAgainOnceTheHoldLetsGo() async throws {
        let turns = EngineTurns()
        let runs = Count()
        let served = Task {
            try await turns.decode(as: .served) { () async throws(TranscriptionFailure) in
                if runs.add() == 1 { try? await Task.sleep(for: .seconds(600)) }
                guard !Task.isCancelled else { throw .cancelled }
                return "heard"
            }
        }
        #expect(try await Self.soon { turns.reading.decoding == .served })
        let hold = turns.hold()
        #expect(try await Self.soon { turns.reading.decoding == nil && turns.reading.waiting == 1 })
        #expect(try await turns.decode(as: .dictation) { "spoken" } == "spoken")
        #expect(runs.now == 1)
        #expect(hold.release() == EngineHold.Displaced(preempted: true, waiting: 1, yielded: false))
        #expect(try await served.value == "heard")
        #expect(runs.now == 2)
        #expect(turns.reading == EngineTurns.Reading(tally: EngineTurns.Tally(cancelled: 1)))
    }

    /// A hold that gives way to dictation is told to by the first dictation decode, once, and
    /// its release says so. A press's hold alone, a served decode, and a dictation decode
    /// after the hold let go do not tell it.
    @Test func aYieldingHoldIsToldByTheFirstDictationDecodeOnly() async throws {
        let turns = EngineTurns()
        let yields = Count()
        let bench = turns.hold(yieldingToDictation: { _ = yields.add() })
        turns.hold().release()
        let served = Task { try await turns.decode(as: .served) { () throws(TranscriptionFailure) in "asked" } }
        #expect(yields.now == 0)
        let press = turns.hold()
        #expect(try await turns.decode(as: .dictation) { "spoken" } == "spoken")
        #expect(try await turns.decode(as: .dictation) { "again" } == "again")
        press.release()
        #expect(yields.now == 1)
        #expect(bench.release().yielded)
        #expect(try await served.value == "asked")
        let after = turns.hold(yieldingToDictation: { _ = yields.add() })
        #expect(!after.release().yielded)
        #expect(try await turns.decode(as: .dictation) { "later" } == "later")
        #expect(yields.now == 1)
    }

    @Test func aServedDecodeAskedForDuringAHoldWaitsForEveryHoldToLetGo() async throws {
        let turns = EngineTurns()
        let first = turns.hold()
        let second = turns.hold()
        let served = Task { try await turns.decode(as: .served) { "heard" } }
        #expect(try await Self.soon { turns.reading.waiting == 1 })
        first.release()
        #expect(turns.reading.waiting == 1 && turns.reading.decoding == nil)
        #expect(second.release() == EngineHold.Displaced(preempted: false, waiting: 1, yielded: false))
        #expect(try await served.value == "heard")
        #expect(turns.reading == EngineTurns.Reading(tally: EngineTurns.Tally(deferred: 1)))
    }

    @Test func aDictationDecodeInFlightIsNotCancelledByAHold() async throws {
        let turns = EngineTurns()
        let gate = Gate()
        let spoken = Task { try await turns.decode(as: .dictation) { await gate.wait(); return "spoken" } }
        #expect(try await Self.soon { gate.waiting == 1 })
        let hold = turns.hold()
        gate.open()
        #expect(try await spoken.value == "spoken")
        #expect(hold.release() == EngineHold.Displaced(preempted: false, waiting: 0, yielded: false))
        #expect(turns.reading.tally.cancelled == 0)
    }

    /// A hold is not the only thing that ends a served decode: a caller that goes away
    /// takes its decode with it, waiting or running, and it is not run again.
    @Test func aServedCallerThatIsCancelledEndsItsDecodeWhetherWaitingOrRunning() async throws {
        let turns = EngineTurns()
        let runs = Count()
        let running = Task {
            try await turns.decode(as: .served) { () async throws(TranscriptionFailure) in
                _ = runs.add()
                try? await Task.sleep(for: .seconds(600))
                throw .cancelled
            }
        }
        #expect(try await Self.soon { turns.reading.decoding == .served })
        running.cancel()
        let runningEnded = await #expect(throws: TranscriptionFailure.self) { try await running.value }
        if case .cancelled? = runningEnded {} else { Issue.record("the running decode ended on \(String(describing: runningEnded)), not cancelled") }
        #expect(runs.now == 1)

        let hold = turns.hold()
        let waiting = Task { try await turns.decode(as: .served) { _ = runs.add() } }
        #expect(try await Self.soon { turns.reading.waiting == 1 })
        waiting.cancel()
        let waitingEnded = await #expect(throws: TranscriptionFailure.self) { try await waiting.value }
        if case .cancelled? = waitingEnded {} else { Issue.record("the waiting decode ended on \(String(describing: waitingEnded)), not cancelled") }
        #expect(turns.reading.waiting == 0)
        hold.release()
        #expect(runs.now == 1)
    }

    /// The engine must not be re-entered, so however many callers ask at once, one decode
    /// runs at a time.
    @Test func decodesNeverOverlap() async throws {
        let turns = EngineTurns()
        let inside = Count()
        let most = Count()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await turns.decode(as: index.isMultiple(of: 3) ? .dictation : .served) {
                        most.atLeast(inside.add())
                        await Task.yield()
                        _ = inside.add(-1)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(most.now == 1)
        #expect(turns.reading == EngineTurns.Reading())
    }
}

private final class Count: Sendable {
    private let value = Atomic(0)

    var now: Int { value.load(ordering: .relaxed) }

    func add(_ amount: Int = 1) -> Int {
        value.add(amount, ordering: .relaxed).newValue
    }

    func atLeast(_ floor: Int) {
        value.max(floor, ordering: .relaxed)
    }
}
