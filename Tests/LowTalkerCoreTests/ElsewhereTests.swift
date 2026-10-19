import Dispatch
import LowTalkerCore
import Synchronization
import Testing

private struct Refused: Error, Equatable {}

/// A serial queue a test holds shut until it says otherwise, so what is handed to it can be
/// looked at while it has not run.
private final class GatedQueue: Sendable {
    let queue = DispatchQueue(label: "ElsewhereTests")
    private let gate = DispatchSemaphore(value: 0)

    init() {
        queue.async { [gate] in gate.wait() }
    }

    func open() { gate.signal() }
}

/// Whether readying off the main actor keeps the two promises it is used for: the caller gets
/// its answer back without doing the work, and work replaced before its turn is never done.
@Suite struct ElsewhereTests {
    /// The request returns while the queue is still busy with something else, and nothing
    /// says the work finished until it has.
    @Test func handingWorkOverDoesNotWaitForIt() throws {
        let gated = GatedQueue()
        let handed = Elsewhere(on: gated.queue) { 42 }
        #expect(handed.finished == nil)
        gated.open()
        #expect(try handed.result().get() == 42)
        #expect(try handed.finished?.get() == 42)
    }

    /// A wait is a wait for whatever of the work is left, and hands back what it came to -
    /// including the throw, which is how a readying that failed reaches the press.
    @Test func waitingThrowsWhatTheWorkThrew() {
        let gated = GatedQueue()
        let handed = Elsewhere<Int>(on: gated.queue) { throw Refused() }
        gated.open()
        #expect(throws: Refused.self) { try handed.result().get() }
    }

    /// An awaited wait comes back once the work has run, so `finished` has what it came to by
    /// then. The gate opens a moment after the waiter is under way, so a wait that came back
    /// before the work ran would find nothing finished. That the wait holds no thread is the
    /// compiler's to keep: the blocking `result()` is unavailable to async code.
    @Test func anAwaitedWaitComesBackWithWhatTheWorkCameTo() async throws {
        let gated = GatedQueue()
        let handed = Elsewhere(on: gated.queue) { 42 }
        let waiter = Task { await handed.wait(); return handed.finished }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { gated.open() }
        #expect(try await waiter.value?.get() == 42)
    }

    /// Work let go of before the queue reached it costs the queue nothing, which is what lets
    /// a run of readyings for one device change do the newest and not every one before it.
    @Test func workNobodyHoldsWhenItsTurnComesIsNeverDone() throws {
        let gated = GatedQueue()
        let done = Atomic<Int>(0)
        var replaced: Elsewhere<Int>? = Elsewhere(on: gated.queue) {
            done.add(1, ordering: .relaxed)
            return 1
        }
        #expect(replaced?.finished == nil)
        replaced = nil
        let newest = Elsewhere(on: gated.queue) {
            done.add(1, ordering: .relaxed)
            return 2
        }
        gated.open()
        #expect(try newest.result().get() == 2)
        #expect(done.load(ordering: .relaxed) == 1)
    }
}
