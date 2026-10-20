import Synchronization

/// The one owner of whose decode the engine runs next. Dictation comes first: a hold takes
/// the engine the moment it begins, cancelling any served decode in flight, and served
/// decodes wait until every hold has had its final transcript. A cancelled decode runs
/// again, whole, once they have, so a served caller sees only the wait and never an error
/// dictation caused. Work that holds the engine and gives way to dictation, a bench run, is
/// told to stop by the first dictation decode it meets.
///
/// [LAW:single-enforcer] The rule lives here and nowhere else. Dictation takes holds and
/// both it and the server decode through this, as `Caller.dictation` and `Caller.served`;
/// neither asks whether the other is busy.
///
/// [LAW:no-ambient-temporal-coupling] Decodes run one at a time, because the engine they
/// share must not be re-entered, and a decode cancelled for a hold is waited out before the
/// hold's first decode starts. State sits under a lock rather than in an actor so that
/// `hold` returns having already cancelled: key-down cannot fall between asking for the
/// engine and a served decode learning it has lost it.
public final class EngineTurns: Sendable {
    /// Who a decode is for.
    public enum Caller: Sendable {
        /// The speaker's own hold: never waits on a served decode and is never cancelled
        /// for one.
        case dictation
        /// Another program asking through the server: waits while any hold is open.
        case served
    }

    /// The owner at one moment, and what it has done so far.
    public struct Reading: Equatable, Sendable {
        public var holds = 0
        /// Whose decode the engine is running, if any.
        public var decoding: Caller?
        /// Decodes waiting their turn.
        public var waiting = 0
        public var tally = Tally()
    }

    /// What served decodes went through because of holds.
    public struct Tally: Equatable, Sendable, Codable {
        /// Served decodes a hold cancelled, each run again afterwards.
        public var cancelled = 0
        /// Served decodes that asked while a hold was open and waited for it.
        public var deferred = 0

        public init(cancelled: Int = 0, deferred: Int = 0) {
            self.cancelled = cancelled
            self.deferred = deferred
        }
    }

    /// The tally of one served request's decodes, so the event the server records about the
    /// request carries what holds did to it. [LAW:nothing-unseen] Bound around a request
    /// with `EngineTurns.$ledger.withValue`, the way a trace context rides one: this owner
    /// counts where it decides, and the request reads the count when it is answered.
    public final class Ledger: Sendable {
        private let counted = Mutex(Tally())

        public init() {}

        public var tally: Tally { counted.withLock { $0 } }

        fileprivate func count(_ fact: WritableKeyPath<Tally, Int>) {
            counted.withLock { $0[keyPath: fact] += 1 }
        }
    }

    /// The ledger of the request the current task is decoding for; nil for dictation, and
    /// for any caller that did not ask for one.
    @TaskLocal public static var ledger: Ledger?

    private struct Waiter {
        let id: Int
        let caller: Caller
        /// Resumed true when the engine is the waiter's, false when it stopped waiting.
        let go: CheckedContinuation<Bool, Never>
    }

    private struct Decoding {
        let id: Int
        let caller: Caller
        /// Set once the decode's task exists; a hold that comes before then marks it
        /// preempted and the decode cancels itself as it starts.
        var cancel: (@Sendable () -> Void)?
        var preempted = false
    }

    private struct State {
        var reading = Reading()
        var decoding: Decoding?
        var waiting: [Waiter] = []
        /// What each open hold that gives way to dictation does to give way, by its id.
        var yielders: [Int: @Sendable () -> Void] = [:]
        var ids = 0

        /// The next waiter to decode, taken off the queue and made the one decoding, when
        /// the engine is free: the first dictation decode, or else the first served one if
        /// no hold is open.
        mutating func admit() -> CheckedContinuation<Bool, Never>? {
            guard decoding == nil,
                  let next = waiting.firstIndex(where: { $0.caller == .dictation })
                    ?? (reading.holds == 0 ? waiting.indices.first : nil)
            else { return nil }
            let waiter = waiting.remove(at: next)
            decoding = Decoding(id: waiter.id, caller: waiter.caller)
            sync()
            return waiter.go
        }

        mutating func sync() {
            reading.decoding = decoding?.caller
            reading.waiting = waiting.count
        }
    }

    private let state = Mutex(State())

    public init() {}

    public var reading: Reading {
        state.withLock { $0.reading }
    }

    /// Takes the engine for a hold, from key-down until the hold's final transcript is out.
    /// A served decode in flight is told to stop before this returns.
    public func hold() -> EngineHold {
        take(yielding: nil)
    }

    /// Takes the engine for work that gives way to dictation, a bench run: served decodes wait
    /// for it as for a hold, and the first dictation decode admitted while it is open calls
    /// `yield`, once. A press that is refused, or still waits on its engine, decodes nothing,
    /// so it stops nothing.
    public func hold(yieldingToDictation yield: @escaping @Sendable () -> Void) -> EngineHold {
        take(yielding: yield)
    }

    private func take(yielding yield: (@Sendable () -> Void)?) -> EngineHold {
        let (cancel, preempted, yielder) = state.withLock { state -> ((@Sendable () -> Void)?, Bool, Int?) in
            state.reading.holds += 1
            let yielder = yield.map { yield in
                state.ids += 1
                state.yielders[state.ids] = yield
                return state.ids
            }
            guard var decoding = state.decoding, decoding.caller == .served, !decoding.preempted else { return (nil, false, yielder) }
            decoding.preempted = true
            state.decoding = decoding
            return (decoding.cancel, true, yielder)
        }
        cancel?()
        return EngineHold(turns: self, preempted: preempted, yielder: yielder)
    }

    /// Closes one hold and hands the engine on; returns how many served decodes were waiting.
    fileprivate func release(yielder: Int?) -> Int {
        let (next, waiting) = state.withLock { state in
            state.reading.holds -= 1
            yielder.map { state.yielders[$0] = nil }
            let waiting = state.waiting.count { $0.caller == .served }
            return (state.admit(), waiting)
        }
        next?.resume(returning: true)
        return waiting
    }

    /// Runs `decode` on the engine when `caller`'s turn comes, and again from the start if a
    /// hold cancelled it; its outcome is the last run's. Cancelling the caller cancels the
    /// decode, whether it is waiting or running.
    public func decode<T: Sendable>(as caller: Caller, _ decode: @escaping @Sendable () async throws(TranscriptionFailure) -> T) async throws(TranscriptionFailure) -> T {
        let ledger = Self.ledger
        var rerun = false
        while true {
            let id = try await turn(caller, rerun: rerun, ledger: ledger)
            // A task of its own, so that a hold can cancel the decode without cancelling the
            // caller, who is still owed its outcome.
            let task = Task { await Result(catching: decode) }
            let preemptedBeforeStart = state.withLock { state in
                state.decoding?.cancel = { task.cancel() }
                return state.decoding?.preempted == true
            }
            if preemptedBeforeStart { task.cancel() }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            let (preempted, next) = state.withLock { state in
                precondition(state.decoding?.id == id, "the engine ran a decode that was not the one admitted")
                let preempted = state.decoding?.preempted == true
                state.decoding = nil
                state.sync()
                return (preempted, state.admit())
            }
            next?.resume(returning: true)
            // A decode a hold cancelled failed because of the hold, so it is owed another run;
            // one that finished anyway keeps its result, and was not cancelled.
            guard preempted, !Task.isCancelled, case .failure = result else { return try result.get() }
            state.withLock { $0.reading.tally.cancelled += 1 }
            ledger?.count(\.cancelled)
            rerun = true
        }
    }

    /// Waits until the engine is `caller`'s. A decode run again after a hold goes first among
    /// served decodes, since it has already had its turn once.
    private func turn(_ caller: Caller, rerun: Bool, ledger: Ledger?) async throws(TranscriptionFailure) -> Int {
        let id = state.withLock { state in
            state.ids += 1
            return state.ids
        }
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (go: CheckedContinuation<Bool, Never>) in
                let (admitted, refused) = state.withLock { state -> (CheckedContinuation<Bool, Never>?, Bool) in
                    // Under the lock the cancellation handler also takes, so a cancel either
                    // lands before this and is seen here, or after and finds the waiter.
                    guard !Task.isCancelled else { return (nil, true) }
                    let waiter = Waiter(id: id, caller: caller, go: go)
                    if rerun { state.waiting.insert(waiter, at: 0) } else { state.waiting.append(waiter) }
                    let deferred = caller == .served && !rerun && state.reading.holds > 0
                    if deferred {
                        state.reading.tally.deferred += 1
                        ledger?.count(\.deferred)
                    }
                    state.sync()
                    return (state.admit(), false)
                }
                if refused { go.resume(returning: false) }
                admitted?.resume(returning: true)
            }
        } onCancel: {
            state.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                defer { state.sync() }
                return state.waiting.remove(at: index).go
            }?.resume(returning: false)
        }
        guard admitted else { throw .cancelled }
        // [LAW:single-enforcer] Dictation first, for work that gives way to it as for served
        // decodes: called outside the lock, since what a yield does is its owner's.
        if caller == .dictation {
            state.withLock { state in
                defer { state.yielders = [:] }
                return Array(state.yielders.values)
            }.forEach { $0() }
        }
        return id
    }
}

/// The engine taken for one hold. Released once, when the hold's final transcript is out,
/// which is when served decodes may run again.
public final class EngineHold: Sendable {
    /// What a hold put off: whether it told a served decode in flight to stop as it began
    /// (one that finished anyway kept its result), and how many served decodes were waiting
    /// on it when it let go.
    public struct Displaced: Equatable, Sendable, CustomStringConvertible {
        public let preempted: Bool
        public let waiting: Int

        public var description: String {
            "\(preempted ? 1 : 0) served preempted, \(waiting) served waiting"
        }
    }

    private let turns: EngineTurns
    private let preempted: Bool
    /// The id its yield is kept under, for a hold that gives way to dictation.
    private let yielder: Int?
    private let released = Atomic(false)

    fileprivate init(turns: EngineTurns, preempted: Bool, yielder: Int?) {
        self.turns = turns
        self.preempted = preempted
        self.yielder = yielder
    }

    /// Lets the engine go. [LAW:no-silent-failure] A second release would count another
    /// hold's opening as closed, so it is refused.
    @discardableResult
    public func release() -> Displaced {
        precondition(!released.exchange(true, ordering: .relaxed), "a hold was released twice")
        return Displaced(preempted: preempted, waiting: turns.release(yielder: yielder))
    }
}
