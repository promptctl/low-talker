import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One reading of the window server's session: its modifier flags as it gives them, whether
/// the Fn key itself is down, and when its modifiers last changed. The session sets the
/// secondary-Fn bit (`NX_SECONDARYFNMASK`) for the arrow, Home, End, Page Up/Down and Forward
/// Delete keys too, Fn held or not, so `flags` takes that bit from the Fn key's own state,
/// read from the same session like the rest, with no tally kept of its presses.
///
/// What the app reads while a key is held, to let go of a release no event told it: a reading
/// of now, never of a change, so it can only confirm. Reading it needs no grant.
public struct SessionModifiers: Equatable, Sendable, CustomStringConvertible {
    public let session: UInt64
    public let fnKeyDown: Bool
    /// Since when the keys it shows have been held: the session's last change of a modifier
    /// key, no later than the reading, in seconds since the machine came up - `NSEvent.timestamp`'s
    /// clock. Measured on studious, 2026-10-03: for keys pressed through vhid it lands 1.5-9 ms
    /// after each one was sent. Measured on u2 (macOS 26.5.2), 2026-10-20: while an app holds
    /// Secure Event Input this time is stale, though the flags are not, so it only ever holds a
    /// release back, never times a press.
    public let changedAt: TimeInterval

    public init(session: UInt64, fnKeyDown: Bool, changedAt: TimeInterval) {
        self.session = session
        self.fnKeyDown = fnKeyDown
        self.changedAt = changedAt
    }

    /// The session now.
    public static func read() -> SessionModifiers {
        let readAt = ProcessInfo.processInfo.systemUptime
        let session = CGEventSource.flagsState(.combinedSessionState).rawValue
        let fnKeyDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Function))
        let sinceChange = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged)
        return SessionModifiers(session: session, fnKeyDown: fnKeyDown,
                                changedAt: date(lastChange: ProcessInfo.processInfo.systemUptime - sinceChange, readAt: readAt))
    }

    /// When a reading taken at `readAt` has held its keys since, given the session's last
    /// change. Not after the reading: the last change is asked for after the keys are read,
    /// so it can be one the reading does not show. Not before the machine came up: a session
    /// with no change since reports one long before it. [LAW:parse-dont-validate]
    static func date(lastChange: TimeInterval, readAt: TimeInterval) -> TimeInterval {
        min(max(lastChange, 0), readAt)
    }

    /// The modifiers held: the session's flags, with the secondary-Fn bit the Fn key's.
    public var flags: UInt64 {
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        return session & ~fn | (fnKeyDown ? fn : 0)
    }

    /// [LAW:nothing-unseen] Both readings, and what was held when the Fn key's state and the
    /// session's bit disagree, so the log tells an arrow key taken for Fn from Fn unheard.
    public var description: String {
        "session 0x\(String(session, radix: 16)), Fn key \(fnKeyDown ? "down" : "up")"
            + (flags == session ? "" : ", held 0x\(String(flags, radix: 16))")
            + ", changed at \(changedAt)"
    }
}
