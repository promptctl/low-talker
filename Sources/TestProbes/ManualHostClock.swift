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
    private let hands: Hands
    /// The clock to hand a decision: it reads and sleeps on this one, and is the same clock
    /// however often it is asked for.
    public let clock: HostClock

    public init(startingAt start: HostTime = HostTime(uptime: .zero)) {
        let hands = Hands(now: start)
        self.hands = hands
        clock = HostClock(now: { hands.now }, sleepUntil: { deadline in try await hands.sleep(until: deadline) })
    }

    public var now: HostTime { hands.now }

    /// Moves `now` forward and wakes every sleeper whose deadline it has reached.
    public func advance(by duration: Duration) {
        hands.set(to: hands.now + duration)
    }

    /// Moves `now` to `moment`, which may not be earlier: the host clock never goes back.
    public func set(to moment: HostTime) {
        hands.set(to: moment)
    }
}

/// What the clock reads and what its sleepers wait on.
private final class Hands: Sendable {
    private struct State {
        var now: HostTime
        var sleepers: [Int: (deadline: HostTime, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var next = 0
    }

    private let state: Mutex<State>

    init(now: HostTime) {
        state = Mutex(State(now: now))
    }

    var now: HostTime { state.withLock { $0.now } }

    func set(to moment: HostTime) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            precondition(moment >= state.now, "the host clock never goes back; \(moment.uptime) is before \(state.now.uptime)")
            state.now = moment
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            due.keys.forEach { state.sleepers.removeValue(forKey: $0) }
            return due.values.map(\.continuation)
        }
        woken.forEach { $0.resume() }
    }

    func sleep(until deadline: HostTime) async throws {
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
