import Darwin
import LowTalkerCore
import Synchronization
import Testing
import TestProbes

/// Whether the object it was given to watch was let go of on the main thread, once it has
/// been let go of at all.
private final class Release: Sendable {
    private let onMainThread = Mutex<Bool?>(nil)

    /// Moves when the watched object is let go, so a test awaits the release
    /// (`await release.changed.settled { release.seen != nil }`) rather than polling for it.
    /// [LAW:no-ambient-temporal-coupling]
    let changed = Changes()

    var seen: Bool? { onMainThread.withLock { $0 } }

    func record() {
        onMainThread.withLock { $0 = pthread_main_np() != 0 }
        changed.note()
    }
}

/// Tells its `Release` where it was let go of.
private final class Held: Sendable {
    let release: Release

    init(_ release: Release) { self.release = release }

    deinit { release.record() }
}

/// Counts operations in flight and remembers the most it ever saw at once.
private actor Occupancy {
    private(set) var active = 0
    private(set) var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
    }
}

private struct Boom: Error {}

@Suite struct SerialQueueTests {
    /// Many operations submitted at once, each yielding mid-flight so an unserialized
    /// queue would interleave them. A correct queue passes regardless of scheduling;
    /// only a broken one depends on timing to be caught, and with this many
    /// submissions each suspending twice, it is.
    @Test func operationsNeverOverlap() async throws {
        let queue = SerialQueue()
        let occupancy = Occupancy()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await queue.run {
                        await occupancy.enter()
                        await Task.yield()
                        await Task.yield()
                        await occupancy.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await occupancy.peak == 1)
        #expect(await occupancy.active == 0)
    }

    @Test func returnsTheOperationsValue() async throws {
        let queue = SerialQueue()
        #expect(try await queue.run { 42 } == 42)
    }

    /// A failure reaches its own caller and nobody else; the queue keeps going.
    @Test func failureStaysWithItsCaller() async throws {
        let queue = SerialQueue()
        await #expect(throws: Boom.self) {
            try await queue.run { throw Boom() }
        }
        #expect(try await queue.run { "still running" } == "still running")
    }

    /// An operation that submits to its own queue would wait on itself forever. It
    /// is refused instead, and the queue is still usable afterwards.
    @Test func submittingToOwnQueueIsRefusedNotHung() async throws {
        let queue = SerialQueue()
        await #expect(throws: SerialQueueError.self) {
            try await queue.run {
                try await queue.run { "never" }
            }
        }
        #expect(try await queue.run { "still running" } == "still running")
    }

    /// Submitting to a different queue from inside an operation is ordinary nesting.
    @Test func submittingToAnotherQueueIsAllowed() async throws {
        let outer = SerialQueue()
        let inner = SerialQueue()
        let value = try await outer.run {
            try await inner.run { "nested" }
        }
        #expect(value == "nested")
    }

    /// Coming back to a queue through another one is the same wait-on-yourself, one
    /// hop removed, and is refused the same way.
    @Test func submittingToAnEnclosingQueueThroughAnotherIsRefused() async throws {
        let outer = SerialQueue()
        let inner = SerialQueue()
        await #expect(throws: SerialQueueError.self) {
            try await outer.run {
                try await inner.run {
                    try await outer.run { "never" }
                }
            }
        }
        #expect(try await outer.run { "still running" } == "still running")
    }

    /// The escape hatch for resubmitting later: a detached task inherits nothing, so
    /// its submission is an ordinary one once the operation that spawned it is done.
    @Test func detachedTaskMayResubmitAfterItsOperationReturns() async throws {
        let queue = SerialQueue()
        let later = try await queue.run {
            Task.detached { try await queue.run { "later" } }
        }
        #expect(try await later.value == "later")
    }

    /// `drain` is what a caller waits on before it shuts down, so what it must not do is
    /// come back while work the queue already accepted is still running. The operation is
    /// held at a gate until the drain is asked for, and yields on its way out afterwards,
    /// so a drain that did not wait is caught by the flag still being down.
    @Test func drainReturnsOnlyAfterWorkAlreadySubmittedHasFinished() async throws {
        let queue = SerialQueue()
        let started = Gate()
        let held = Gate()
        let finished = Flag()
        let submitted = Task {
            try await queue.run {
                started.open()
                await held.wait()
                for _ in 0..<50 { await Task.yield() }
                finished.raise()
            }
        }
        // Running, so the queue has accepted it and a drain owes it a wait.
        await started.wait()
        #expect(!finished.raised)
        held.open()
        try await queue.drain()
        #expect(finished.raised)
        try await submitted.value
    }

    /// However it ended: a failed operation is waited for like any other, and its failure
    /// stays with its own caller rather than travelling to whoever drained.
    @Test func drainWaitsForAFailedOperationAndDoesNotCarryItsFailure() async throws {
        let queue = SerialQueue()
        let started = Gate()
        let held = Gate()
        let finished = Flag()
        let submitted = Task {
            try await queue.run {
                started.open()
                await held.wait()
                for _ in 0..<50 { await Task.yield() }
                finished.raise()
                throw Boom()
            }
        }
        await started.wait()
        held.open()
        try await queue.drain()
        #expect(finished.raised)
        await #expect(throws: Boom.self) { try await submitted.value }
    }

    /// The doc's guarantee is plural, and a burst of overlapping presses - not a single
    /// one - is what `Dictation.finish()` leans on it for. The second operation is
    /// submitted while the first is still held, so it joins a chain rather than arriving
    /// at an empty queue, and the drain is asked for while it is still running: a drain
    /// that came back at the end of the first is caught by the second's flag still down.
    @Test func drainWaitsForTheSecondOperationInTheChainAndNotOnlyTheFirst() async throws {
        let queue = SerialQueue()
        let firstRunning = Gate()
        let firstHeld = Gate()
        let secondRunning = Gate()
        let secondHeld = Gate()
        let first = Flag()
        let second = Flag()
        let earlier = Task {
            try await queue.run {
                firstRunning.open()
                await firstHeld.wait()
                first.raise()
            }
        }
        await firstRunning.wait()
        let later = Task {
            try await queue.run {
                secondRunning.open()
                await secondHeld.wait()
                for _ in 0..<50 { await Task.yield() }
                second.raise()
            }
        }
        firstHeld.open()
        await secondRunning.wait()
        // Running, and the queue only reaches it once the first is done: the chain the
        // drain owes a wait to is two long.
        #expect(first.raised)
        #expect(!second.raised)
        secondHeld.open()
        try await queue.drain()
        #expect(second.raised)
        try await earlier.value
        try await later.value
    }

    /// The sequence a caller shutting down actually performs: hand the work over, then
    /// drain, with nothing awaited in between. It is a sequence only a synchronous
    /// `submit` can express - an `async` one would put an `await` between the two, which
    /// is the window this closed - so the compiler holds that half and this test is what
    /// keeps the signature from quietly going back. The run holds the other half: the
    /// operation needs fifty scheduling rounds to reach its flag, so a drain that came
    /// back without waiting for it is caught by the flag still being down.
    @Test func drainWaitsForAnOperationSubmittedWithNothingAwaitedInBetween() async throws {
        let queue = SerialQueue()
        let finished = Flag()
        let submitted = try queue.submit {
            for _ in 0..<50 { await Task.yield() }
            finished.raise()
        }
        try await queue.drain()
        #expect(finished.raised)
        await submitted.value
    }

    /// What an operation holds is let go of on the actor that submitted it. `Dictation`
    /// submits from the main actor holding what must end there, and when a test dropped
    /// its dictation before the queue's task finished, the task's last release ended it on
    /// the cooperative pool instead.
    @Test @MainActor func whatAnOperationHoldsIsLetGoOnTheActorThatSubmittedIt() async throws {
        let queue = SerialQueue()
        let release = Release()
        try await Self.submitHolding(Held(release), to: queue).value
        await release.changed.settled { release.seen != nil }
        #expect(release.seen == true)
    }

    /// Submitted from a call of its own, so nothing but the operation still holds `held`
    /// once the call returns.
    @MainActor
    private static func submitHolding(_ held: Held, to queue: SerialQueue) throws -> Task<Void, Never> {
        try queue.submit { _ = held }
    }

    /// Draining from inside an operation is the same wait-on-yourself a submission is -
    /// the tail being awaited is the caller's own operation - and is refused the same way
    /// rather than left to hang undiagnosed.
    @Test func drainingFromInsideAnOperationIsRefused() async throws {
        let queue = SerialQueue()
        await #expect(throws: SerialQueueError.self) {
            try await queue.run { try await queue.drain() }
        }
        #expect(try await queue.run { "still running" } == "still running")
    }
}

/// Whether work is owed, as the queue says it from any thread.
extension SerialQueueTests {
    @Test(.timeLimit(.minutes(1))) func theQueueIsBusyFromSubmitUntilTheLastOperationFinishes() async throws {
        let queue = SerialQueue()
        #expect(!queue.isBusy)
        let (stream, release) = AsyncStream<Void>.makeStream()
        let first = try queue.submit { for await _ in stream {} }
        let second = try queue.submit { () async -> Void in }
        #expect(queue.isBusy)

        release.finish()
        await first.value
        await second.value

        #expect(!queue.isBusy)
    }

    @Test func aQueueNothingWasSubmittedToIsNotBusy() {
        #expect(!SerialQueue().isBusy)
    }
}
