import Foundation

/// A moment on the clock the machine has been up on, counted from when it came up.
/// The window server stamps every keyboard event on it and CoreAudio stamps every
/// microphone buffer on it, so how long before a sample a key went down is a
/// subtraction rather than a guess.
///
/// [LAW:one-source-of-truth] Each source hands out a bare integer in a unit of its
/// own choosing - the window server nanoseconds, CoreAudio the machine's raw ticks.
/// Each becomes one of these at the seam that parses it, so nothing downstream holds
/// a number whose clock and unit it has to remember.
public struct HostTime: Hashable, Comparable, Sendable {
    public let uptime: Duration

    public init(uptime: Duration) {
        self.uptime = uptime
    }

    /// A moment given in seconds since the machine came up, the unit `NSEvent.timestamp` and
    /// `ProcessInfo.systemUptime` count in. Rounded: seconds as a double do not land on whole
    /// nanoseconds.
    public init(seconds: TimeInterval) {
        self.init(uptime: .nanoseconds(Int64((seconds * 1_000_000_000).rounded())))
    }

    /// [LAW:effects-at-boundaries] The one reading of this clock; a moment that comes
    /// from an event carries its own and never wants this.
    public static var now: HostTime {
        HostTime(uptime: .nanoseconds(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
    }

    public static func - (moment: HostTime, earlier: HostTime) -> Duration {
        moment.uptime - earlier.uptime
    }

    public static func + (moment: HostTime, elapsed: Duration) -> HostTime {
        HostTime(uptime: moment.uptime + elapsed)
    }

    public static func < (moment: HostTime, later: HostTime) -> Bool {
        moment.uptime < later.uptime
    }
}

extension ContinuousClock.Instant {
    /// `moment` on the clock every latency here is timed by. The host clock stops while
    /// the machine sleeps and this one does not, so the two differ by every sleep since
    /// startup; what carries across is `moment`'s age, read on its own clock now.
    public init(_ moment: HostTime) {
        self = .now - (HostTime.now - moment)
    }
}
