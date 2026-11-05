import Foundation

/// The turns waiting for the main actor, in the order they were asked for, and the one place
/// that says who runs them.
///
/// A turn reaches the main actor two ways, and both run it through `drain()`: the block this
/// queues on the main queue, as every turn has always gone, and a `hold`, which a callback on
/// the main thread makes while it waits on something that cannot arrive until a turn has run.
/// Whichever gets to a turn first pops and runs it, and the other finds nothing, so a turn runs
/// once and in order. [LAW:no-ambient-temporal-coupling]
///
/// That is what a held Return needs. The words it waits for are committed by turns, and the
/// main thread is the one that commits them; a main thread that only waited would be waiting
/// for itself. A nested run loop would run those turns too, and every other callback IMK hands
/// this process with them, in the middle of the wait. Here nothing runs but turns.
///
/// `@unchecked Sendable`: the condition guards every access to `pending`, and turns run only on
/// the main thread, outside the lock.
public nonisolated final class MainTurns: @unchecked Sendable {
    public typealias Turn = @MainActor @Sendable () -> Void

    private let condition = NSCondition()
    private var pending: [Turn] = []

    public init() {}

    /// Queues `turn` to run on the main actor, and wakes a `hold` that is waiting.
    public func push(_ turn: @escaping Turn) {
        condition.lock()
        pending.append(turn)
        condition.broadcast()
        condition.unlock()
        DispatchQueue.main.async { MainActor.assumeIsolated { self.drain() } }
    }

    /// Wakes a `hold` to read whatever it is waiting on again.
    public func poke() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// Runs every queued turn, oldest first, and any queued while they ran. Each is taken under
    /// the lock and run outside it, so a push from another thread never waits on a commit.
    @MainActor
    func drain() {
        while let turn = next() { turn() }
    }

    private func next() -> Turn? {
        condition.lock()
        defer { condition.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Runs turns as they arrive until `waiting` says there is nothing left to wait for, or
    /// `deadline` passes. Whether it ended on the first or the second is the caller's to read
    /// off whatever `waiting` reads.
    ///
    /// `waiting` is read under the lock, and whatever ends the wait calls `poke` or `push`
    /// after it has changed what `waiting` reads, so the change cannot land between the read and
    /// the sleep: a condition re-checks its predicate and carries no signal from one wait to the
    /// next, which a bare semaphore would.
    @MainActor
    func hold(until deadline: ContinuousClock.Instant, while waiting: () -> Bool) {
        while true {
            drain()
            condition.lock()
            while pending.isEmpty && waiting() && ContinuousClock.now < deadline {
                condition.wait(until: Date(timeIntervalSinceNow: ContinuousClock.now.duration(to: deadline) / .seconds(1)))
            }
            let done = pending.isEmpty && (!waiting() || ContinuousClock.now >= deadline)
            condition.unlock()
            if done { return }
        }
    }
}
