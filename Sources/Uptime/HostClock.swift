/// The clock a decision reads time from: what `now` is on the host clock, and a sleep until a
/// moment of it.
///
/// [LAW:effects-at-boundaries] [LAW:no-ambient-temporal-coupling] A reading of the clock is an
/// effect, so a decision is handed one of these rather than reaching for `HostTime.now`, and a
/// test hands it one it moves itself. Concrete rather than `any Clock<Duration>`, because
/// `Clock` leaves its instant abstract and an existential of it cannot be asked `now`. Its
/// instant is the one key events and microphone buffers are already stamped on, so a figure
/// timed from one of them is a subtraction on one clock.
public struct HostClock: Clock, Sendable {
    public typealias Instant = HostTime

    private let read: @Sendable () -> HostTime
    private let wait: @Sendable (HostTime) async throws -> Void

    /// A clock that reads `now` and sleeps with `sleepUntil`, which throws `CancellationError`
    /// when the task sleeping is cancelled.
    public init(now: @escaping @Sendable () -> HostTime, sleepUntil: @escaping @Sendable (HostTime) async throws -> Void) {
        read = now
        wait = sleepUntil
    }

    public var now: HostTime { read() }

    public var minimumResolution: Duration { .nanoseconds(1) }

    public func sleep(until deadline: HostTime, tolerance: Duration? = nil) async throws {
        try await wait(deadline)
    }

    /// The machine's: `CLOCK_UPTIME_RAW`, which stops while the Mac sleeps. Sleeps on
    /// `SuspendingClock`, which on Darwin is that same clock, so a sleep ends when `now` reaches
    /// its deadline, and time the Mac spends asleep counts toward neither.
    public static let system = HostClock(now: { HostTime.now }) { deadline in
        let suspending = SuspendingClock()
        try await suspending.sleep(until: suspending.now.advanced(by: deadline - HostTime.now))
    }
}
