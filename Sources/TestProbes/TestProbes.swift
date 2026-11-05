import Synchronization

// What a test plants in concurrent work to know where that work has got to, instead of
// inferring it from how much time has passed. [LAW:no-ambient-temporal-coupling]
//
// Its own target rather than a copy in each suite: SwiftPM test targets cannot import
// one another's sources, so a plain target both depend on is where one of each can live
// for both. [LAW:one-source-of-truth] It is in no product, so it ships nowhere.

/// Something a test holds shut, and everything that arrives at it waits until the test
/// opens it. How many are waiting is readable, so a test can prove work is held here.
///
/// A cancelled waiter comes back rather than staying held: a gate that outlived its
/// cancellation would hold a whole suite forever, and a task group whose first failure
/// cancels its siblings is the ordinary way a suite arrives here. Coming back is all it
/// does - the caller reads cancellation where it already reads it, so `wait` stays a
/// thing that returns. [LAW:no-ambient-temporal-coupling]
public final class Gate: Sendable {
    private struct State {
        var open = false
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var arrivals = 0
    }

    private let state = Mutex(State())

    /// Moves whenever the count of waiters changes, so a test awaits work arriving here
    /// (`await gate.changed.settled { gate.waiting == 1 }`) rather than polling for it.
    public let changed = Changes()

    public init() {}

    public var waiting: Int { state.withLock { $0.waiters.count } }

    public func open() {
        let released = state.withLock { state in
            state.open = true
            defer { state.waiters = [:] }
            return state.waiters
        }
        released.values.forEach { $0.resume() }
        if !released.isEmpty { changed.note() }
    }

    public func wait() async {
        let arrival = state.withLock { state in
            state.arrivals += 1
            return state.arrivals
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation is read under the same lock the handler takes, which is
                // what makes the two arrivals meet: whichever gets the lock second finds
                // what the first left, so the continuation is resumed exactly once
                // whether the cancellation lands before this waiter is filed or after.
                let through = state.withLock { state in
                    guard !state.open, !Task.isCancelled else { return true }
                    state.waiters[arrival] = continuation
                    return false
                }
                if through { continuation.resume() } else { changed.note() }
            }
        } onCancel: {
            if let waiter = state.withLock({ $0.waiters.removeValue(forKey: arrival) }) {
                waiter.resume()
                changed.note()
            }
        }
    }
}

/// Raised by work as the last thing it does, so a wait that came back early is caught by
/// what has not happened yet rather than by a deadline.
public final class Flag: Sendable {
    private let value = Mutex(false)

    /// Moves when the flag is raised, so a test awaits the raise
    /// (`await flag.changed.settled { flag.raised }`) rather than polling for it.
    /// [LAW:no-ambient-temporal-coupling]
    public let changed = Changes()

    public init() {}

    public var raised: Bool { value.withLock { $0 } }

    public func raise() {
        value.withLock { $0 = true }
        changed.note()
    }
}

/// The dual of `Gate`: where a gate holds work back until a test opens it, this wakes a test
/// when work moved, so a test proves an effect arrived by awaiting it rather than by polling a
/// clock until a deadline. Whatever mutates calls `note`; an observer calls `settled` and
/// comes back the moment its condition holds. [LAW:no-ambient-temporal-coupling]
///
/// Lost-wakeup-free by a count read under the same lock a wake bumps: an observer reads the
/// count, checks its condition, and parks only for a count still equal to the one it read, so a
/// `note` landing between the read and the park is not missed - it moved the count, and the
/// park sees it moved and comes back at once to re-check.
public final class Changes: Sendable {
    private struct State {
        var moved = 0
        var parked: [Int: CheckedContinuation<Void, Never>] = [:]
        var next = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Work moved: wake every observer so each re-checks its condition.
    public func note() {
        let woken = state.withLock { state in
            state.moved += 1
            defer { state.parked = [:] }
            return state.parked.values
        }
        woken.forEach { $0.resume() }
    }

    /// Await until `condition` holds, re-checked on every `note`. No clock and no deadline: a
    /// condition that never holds is a bug that hangs here for the test runner's outer timeout
    /// to name, not a partial result read after a window lapsed. [LAW:no-silent-failure]
    ///
    /// `condition` is the caller's and is asked on the caller's actor; this owns only the
    /// waking. A cancelled wait comes back rather than staying parked, the same reason `Gate`'s
    /// does: a task group whose first failure cancels its siblings is the ordinary way a suite
    /// arrives here, and a wait that outlived its cancellation would hold the whole suite.
    public func settled(
        isolation: isolated (any Actor)? = #isolation,
        _ condition: () throws -> Bool
    ) async rethrows {
        while !Task.isCancelled {
            let seen = state.withLock { $0.moved }
            if try condition() { return }
            let id = state.withLock { state in
                let id = state.next
                state.next += 1
                return id
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    // Resumed under the same lock a wake and a cancellation take, so it is
                    // resumed exactly once whichever reaches the lock first: a note that already
                    // moved the count, a cancellation, or neither, in which case it is parked.
                    let resumeNow = state.withLock { state in
                        guard !Task.isCancelled, state.moved == seen else { return true }
                        state.parked[id] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                state.withLock { $0.parked.removeValue(forKey: id) }?.resume()
            }
        }
    }
}
