import Synchronization
import Uptime

/// A host clock the test moves by hand: `now` only changes when the test sets or advances it,
/// and a sleep comes back the moment `now` reaches its deadline. So what a decision timed is
/// time the test owns, not the scheduler getting CPU within a window.
///
/// [LAW:no-ambient-temporal-coupling] `HostClock`'s one fake. A waiter is filed and read under
/// the one lock `advance` takes, so no wake is lost, and a cancelled sleep comes back rather than
/// staying parked.
public final class ManualHostClock: Sendable {
    private struct State {
        var now: HostTime
        var sleepers: [Int: (deadline: HostTime, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var next = 0
    }

    private let state: Mutex<State>

    public init(startingAt start: HostTime = HostTime(uptime: .zero)) {
        state = Mutex(State(now: start))
    }

    public var now: HostTime { state.withLock { $0.now } }

    /// The clock to hand a decision: it reads and sleeps on this one.
    public var clock: HostClock {
        HostClock(now: { [self] in now }, sleepUntil: { [self] deadline in try await sleep(until: deadline) })
    }

    /// Moves `now` forward and wakes every sleeper whose deadline it has reached.
    public func advance(by duration: Duration) {
        set(to: now + duration)
    }

    /// Moves `now` to `moment`, which may not be earlier: the host clock never goes back.
    public func set(to moment: HostTime) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            precondition(moment >= state.now, "the host clock never goes back; \(moment.uptime) is before \(state.now.uptime)")
            state.now = moment
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            due.keys.forEach { state.sleepers.removeValue(forKey: $0) }
            return due.values.map(\.continuation)
        }
        woken.forEach { $0.resume() }
    }

    private func sleep(until deadline: HostTime) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state in
            defer { state.next += 1 }
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow = state.withLock { state -> (() -> Void)? in
                    if Task.isCancelled { return { continuation.resume(throwing: CancellationError()) } }
                    if state.now >= deadline { return { continuation.resume() } }
                    state.sleepers[id] = (deadline, continuation)
                    return nil
                }
                resumeNow?()
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id)?.continuation }?.resume(throwing: CancellationError())
        }
    }
}
