import Synchronization

/// A clock that stands still until the test moves it: a sleep on it suspends until
/// `advanceToNextDeadline()` reaches its deadline, so whatever the sleeper raced - another
/// task reading the clock - takes its turn at the instant the test holds the hands at, not at
/// whatever instant the machine got round to it. [LAW:no-ambient-temporal-coupling]
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var since: Duration
        func advanced(by duration: Duration) -> Instant { Instant(since: since + duration) }
        func duration(to other: Instant) -> Duration { other.since - since }
        static func < (a: Instant, b: Instant) -> Bool { a.since < b.since }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let wake: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(since: .zero)
        var sleepers: [Sleeper] = []
        var nextID = 0
        /// Tests waiting for something to sleep.
        var watchers: [Int: CheckedContinuation<Void, any Error>] = [:]

        mutating func takeID() -> Int {
            defer { nextID += 1 }
            return nextID
        }
    }

    private let state = Mutex(State())
    let minimumResolution: Duration = .zero

    var now: Instant { state.withLock { $0.now } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { $0.takeID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                let (verdict, watchers) = state.withLock { state -> (Result<Void, any Error>?, [CheckedContinuation<Void, any Error>]) in
                    if Task.isCancelled { return (.failure(CancellationError()), []) }
                    if deadline <= state.now { return (.success(()), []) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, wake: wake))
                    defer { state.watchers = [:] }
                    return (nil, Array(state.watchers.values))
                }
                if let verdict { wake.resume(with: verdict) }
                watchers.forEach { $0.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                state.sleepers.firstIndex { $0.id == id }.map { state.sleepers.remove(at: $0) }
            }
            sleeper?.wake.resume(throwing: CancellationError())
        }
    }

    /// Waits until something sleeps, then moves the hands to the earliest deadline anything
    /// is sleeping until and wakes whatever sleeps until it. The earliest is chosen as the
    /// hands move, so the clock never runs backward and never steps past a sleeper.
    func advanceToNextDeadline() async throws {
        while true {
            try await untilSomethingSleeps()
            let due = state.withLock { state -> [Sleeper] in
                guard let earliest = state.sleepers.map(\.deadline).min() else { return [] }
                state.now = earliest
                defer { state.sleepers.removeAll { $0.deadline == earliest } }
                return state.sleepers.filter { $0.deadline == earliest }
            }
            due.forEach { $0.wake.resume() }
            if !due.isEmpty { return }
        }
    }

    private func untilSomethingSleeps() async throws {
        let id = state.withLock { $0.takeID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (watcher: CheckedContinuation<Void, any Error>) in
                let verdict = state.withLock { state -> Result<Void, any Error>? in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if !state.sleepers.isEmpty { return .success(()) }
                    state.watchers[id] = watcher
                    return nil
                }
                if let verdict { watcher.resume(with: verdict) }
            }
        } onCancel: {
            state.withLock { $0.watchers.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}
