import Dispatch
import Synchronization

/// Work handed to a serial queue instead of done by the caller: the caller gets this back at
/// once, can look at what the work came to without waiting, and can wait for whatever of it is
/// left.
///
/// Work that nobody holds by the time its turn comes is never done. That is what lets a queue
/// of these coalesce: a caller that replaces one before the queue reaches it costs the queue
/// nothing, so a run of requests with only the newest still wanted does at most two pieces of
/// work - the one already under way, which cannot be taken back, and the newest.
///
/// [LAW:no-ambient-temporal-coupling] Waiting is a wait on the queue itself rather than on a
/// flag this sets: the work was put on a serial queue before any wait on it can be, so a wait
/// that returns has the work done behind it, whichever thread got there first.
///
/// `Value` is let go of wherever the last reference to it is dropped, which can be the queue.
/// A value whose teardown has to happen on one particular thread cannot be carried here.
public final class Elsewhere<Value: Sendable>: Sendable {
    private let queue: DispatchQueue
    private let outcome = Mutex<Result<Value, any Error>?>(nil)

    public init(on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> Value) {
        self.queue = queue
        queue.async { [weak self] in
            // Nobody holds it any more, so nobody can ask what it came to.
            guard let self else { return }
            let result = Result { try work() }
            outcome.withLock { $0 = result }
        }
    }

    /// What the work came to, or nothing while it has not finished.
    public var finished: Result<Value, any Error>? { outcome.withLock { $0 } }

    /// What the work came to, waiting for whatever of it is left. The wait holds the thread
    /// that waits, so async code awaits `wait()` instead. [LAW:types-are-the-program]
    @available(*, noasync, message: "holds the waiting thread; await wait() and read finished")
    public func result() -> Result<Value, any Error> {
        // A wait on the queue from inside it would be a wait on itself, forever.
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {}
        guard let finished else { preconditionFailure("a wait on a serial queue returned before work handed to it earlier had run") }
        return finished
    }

    /// Waits for whatever of the work is left without holding the thread that waits: the
    /// caller is resumed by a step handed to the queue behind the work, so `finished` has the
    /// outcome by the time this returns.
    public func wait() async {
        await withCheckedContinuation { resumed in queue.async { resumed.resume() } }
    }
}
