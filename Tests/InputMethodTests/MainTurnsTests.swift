import Foundation
@testable import InputMethod
import os
import Testing

/// The turns waiting for the main actor, and the hold that runs them while a callback on the
/// main thread waits for something they bring about. [LAW:behavior-not-structure]
@Suite struct MainTurnsTests {
    /// What the held main thread is for: turns pushed from other threads run on the main thread,
    /// once each and in the order pushed, and the block each push also left on the main queue finds
    /// nothing to run when it comes.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func aHoldRunsTurnsPushedFromAnotherThreadOnceAndInOrder() async {
        let turns = MainTurns()
        let ran = OSAllocatedUnfairLock(initialState: [(Int, onMain: Bool)]())
        let done = OSAllocatedUnfairLock(initialState: false)
        Thread {
            for number in 1...5 {
                turns.push { ran.withLock { $0.append((number, Thread.isMainThread)) } }
            }
            done.withLock { $0 = true }
            turns.poke()
        }.start()

        turns.hold(until: .now + .seconds(30), while: { !done.withLock { $0 } })
        // Drained once more through the main queue, where each push left its own block.
        await MainActor.run {}

        let seen = ran.withLock { $0 }
        #expect(seen.map { $0.0 } == [1, 2, 3, 4, 5])
        #expect(seen.allSatisfy { $0.onMain })
    }

    /// A turn can be what ends the wait: nothing else has to wake it.
    @MainActor
    @Test func aTurnThatEndsTheWaitEndsIt() {
        let turns = MainTurns()
        let ended = OSAllocatedUnfairLock(initialState: false)
        turns.push { ended.withLock { $0 = true } }

        turns.hold(until: .now + .seconds(30), while: { !ended.withLock { $0 } })

        #expect(ended.withLock { $0 })
    }

    @MainActor
    @Test func aHoldWaitingForNothingReturnsAtOnce() {
        let started = ContinuousClock.now
        MainTurns().hold(until: started + .seconds(30), while: { false })
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @MainActor
    @Test func aHoldEndsAtItsDeadlineWhenNothingEndsIt() {
        let started = ContinuousClock.now
        MainTurns().hold(until: started + .milliseconds(100), while: { true })
        #expect(ContinuousClock.now - started >= .milliseconds(100))
    }

    /// A wake that came before the hold is not carried into it: a bare semaphore would be, and
    /// the hold would return as if something had changed.
    @MainActor
    @Test func aWakeBeforeTheHoldDoesNotEndIt() {
        let turns = MainTurns()
        turns.poke()
        let started = ContinuousClock.now
        turns.hold(until: started + .milliseconds(150), while: { true })
        #expect(ContinuousClock.now - started >= .milliseconds(150))
    }

    /// What ends the wait changes what is read first and wakes after, so a change that lands
    /// between the reading and the sleep is not lost.
    @MainActor
    @Test(.timeLimit(.minutes(1)), arguments: 0..<200)
    func aWakeFromAnotherThreadEndsTheWait(_: Int) {
        let turns = MainTurns()
        let done = OSAllocatedUnfairLock(initialState: false)
        Thread {
            done.withLock { $0 = true }
            turns.poke()
        }.start()
        turns.hold(until: .now + .seconds(30), while: { !done.withLock { $0 } })
        #expect(done.withLock { $0 })
    }
}
