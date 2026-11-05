import Synchronization

/// Runs operations one at a time: each waits for every earlier submission to finish,
/// succeed or fail, before it starts.
///
/// [LAW:no-ambient-temporal-coupling] Actor isolation alone does not give this: an
/// actor is reentrant at every `await`, so two calls that each await something can
/// interleave. This queue owns the order explicitly as a chain of tasks, and it is
/// the one place that fact lives for anything that wraps a non-reentrant resource.
/// The chain is held under a lock rather than by an actor so that a submission can be
/// made without awaiting anything: a caller that hands work over and then drains must
/// not be able to fall between the two.
///
/// An operation may neither submit to a queue it is running inside nor drain one,
/// directly or through other queues, and neither may any task that inherits the
/// operation's context: either wait would be a wait on itself, forever, so both are
/// refused instead. A task that must come back later without waiting is spawned with
/// `Task.detached`, which inherits nothing.
public final class SerialQueue: Sendable {
    /// The latest submission, whatever its outcome. The next one awaits it.
    private let tail = Mutex<Task<Void, Never>?>(nil)
    /// Operations submitted and not yet finished, whatever their outcome.
    private let unfinished = Mutex(0)

    /// Whether any operation submitted has yet to finish, readable from any thread. The
    /// queue's own fact, so a caller that must know whether work is owed asks here and keeps no
    /// second count that could disagree. [LAW:one-source-of-truth]
    public var isBusy: Bool { unfinished.withLock { $0 > 0 } }

    /// Every queue whose operation encloses the current task.
    @TaskLocal private static var enclosing: Set<ObjectIdentifier> = []

    public init() {}

    /// Puts an operation on the chain and hands back the task that will run it, without
    /// waiting for its turn to come. Nothing suspends between entering here and the
    /// chain being extended, so an operation submitted is an operation every later
    /// `drain` owes a wait to - there is no window in which the queue has taken the work
    /// but cannot yet be seen to hold it. [LAW:no-ambient-temporal-coupling]
    ///
    /// What the operation holds is let go of on the actor that submitted it.
    ///
    /// The operation does not throw: what it can fail with is part of what it hands back, so
    /// the only failure here is the queue's own refusal. [LAW:types-are-the-program]
    @discardableResult
    public func submit<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: @escaping @Sendable () async -> T
    ) throws(SerialQueueError) -> Task<T, Never> {
        let id = ObjectIdentifier(self)
        // [LAW:no-silent-failure] The alternative is a hang with no diagnostics.
        guard !Self.enclosing.contains(id) else { throw .reentrantWait }
        return tail.withLock { tail in
            let earlier = tail
            unfinished.withLock { $0 += 1 }
            let task = Task {
                // Named rather than captured in a list, so the task is isolated to that actor
                // and ends there, which is where a task lets go of its closure.
                _ = isolation
                await earlier?.value
                let outcome = await Self.$enclosing.withValue(Self.enclosing.union([id])) { await operation() }
                unfinished.withLock { $0 -= 1 }
                return outcome
            }
            // Only the order matters to the next submission; this one's outcome goes to
            // whoever holds the task.
            tail = Task { _ = await task.result }
            return task
        }
    }

    /// The operation's turn and its outcome, for a caller with nothing to do until then.
    public func run<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await submit { () async -> Result<T, any Error> in
            do { return .success(try await operation()) } catch { return .failure(error) }
        }.value.get()
    }

    /// Returns once every operation submitted before this call has finished, however it
    /// ended. Operations submitted after it are not waited for, so a caller draining
    /// before it shuts down waits exactly as long as the work already accepted.
    ///
    /// [LAW:no-ambient-temporal-coupling] The queue owns the order, so it owns the
    /// question of when the ordered work is done; a caller that timed a sleep against it
    /// instead would be betting on how long the work takes.
    public func drain() async throws(SerialQueueError) {
        // [LAW:single-enforcer] The same refusal `submit` makes, read off the same set:
        // from inside an operation the tail is that operation, so the wait would never
        // return.
        guard !Self.enclosing.contains(ObjectIdentifier(self)) else { throw .reentrantWait }
        await tail.withLock { $0 }?.value
    }
}

public enum SerialQueueError: Error, CustomStringConvertible {
    /// A task waited on a queue it is running inside, by submitting to it or draining it.
    case reentrantWait

    public var description: String {
        switch self {
        case .reentrantWait:
            "a task waited on a SerialQueue it is running inside, which would wait on itself forever"
        }
    }
}
