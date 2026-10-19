import Carbon.HIToolbox
import CoreGraphics
import Darwin
import DarwinCalls
import Identity
import Foundation

/// The modifier keys held at one moment, as the input method read them the moment it was
/// handed a change of them: what crosses from the input method to the app, so the app can
/// hear a chord of modifiers alone with no grant of its own.
///
/// The whole state and not the key that moved. The text input system hands an input method
/// flags that do not tell Right Option from Left, so the state is read from the window
/// server's session instead, which does, and a state read that way can be ahead of the event
/// that prompted it. A state is true whichever event it follows, and one that has not changed
/// is recognisably nothing; a key named as having moved would be neither. For the same reason
/// it is dated by the session's last change and not by the event's. [FRAMING:representation]
public struct HeldModifiers: Equatable, Sendable {
    /// The session's modifier flags, device-side bits included: a `CGEventFlags` raw value,
    /// a `SessionModifiers` reading's `flags`.
    public let flags: UInt64
    /// When the latest change in `flags` happened, in nanoseconds on the clock the machine has
    /// been up on.
    public let uptimeNanoseconds: UInt64
    /// When a key that is not a modifier last went down before the change the reading answers,
    /// on the same clock: what tells a chord pressed alone from one held as the modifier of a
    /// typed key, which the input method is never handed. Nil as `SessionModifiers.typedAt` is.
    public let typedUptimeNanoseconds: UInt64?

    public init(flags: UInt64, uptimeNanoseconds: UInt64, typedUptimeNanoseconds: UInt64?) {
        self.flags = flags
        self.uptimeNanoseconds = uptimeNanoseconds
        self.typedUptimeNanoseconds = typedUptimeNanoseconds
    }

    /// What a reading of the session says is held, since when, and when a key was last typed.
    public init(_ reading: SessionModifiers) {
        // Rounded: seconds as a double do not land on whole nanoseconds.
        func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64((seconds * 1_000_000_000).rounded()) }
        self.init(flags: reading.flags, uptimeNanoseconds: nanoseconds(reading.changedAt),
                  typedUptimeNanoseconds: reading.typedAt.map(nanoseconds))
    }
}

/// One reading of the window server's session: its modifier flags as it gives them, whether
/// the Fn key itself is down, when its modifiers last changed, and when a key was last typed.
/// The session sets the secondary-Fn bit (`NX_SECONDARYFNMASK`) for the arrow, Home, End, Page
/// Up/Down and Forward Delete keys too, Fn held or not, so `flags` takes that bit from the Fn
/// key's own state, read from the same session like the rest, with no tally kept of its presses.
/// [LAW:one-source-of-truth] Both processes read the session through this: the input method
/// at each change it tells, and the app when it confirms what is still held.
public struct SessionModifiers: Equatable, Sendable, CustomStringConvertible {
    public let session: UInt64
    public let fnKeyDown: Bool
    /// Since when the keys it shows have been held: the session's last change of a modifier
    /// key, as `date(lastChange:after:readAt:)` bounds it, in seconds since the machine came up -
    /// `NSEvent.timestamp`'s clock. Measured on studious, 2026-10-03: for keys pressed through
    /// vhid it lands 1.5-9 ms after each one was sent.
    public let changedAt: TimeInterval
    /// When a key that is not a modifier last went down in the session, on the same clock, if
    /// that was before the event the reading answers, as `typed(lastKeyDown:before:)` places
    /// it. Reading it needs no grant: measured on studious, 2026-10-19, an app with neither
    /// Input Monitoring nor Accessibility read the moment of an A typed under a held Right
    /// Option.
    public let typedAt: TimeInterval?

    public init(session: UInt64, fnKeyDown: Bool, changedAt: TimeInterval, typedAt: TimeInterval?) {
        self.session = session
        self.fnKeyDown = fnKeyDown
        self.changedAt = changedAt
        self.typedAt = typedAt
    }

    /// The session now, read in answer to a change that happened at `event`, or to none.
    public static func read(after event: TimeInterval = 0) -> SessionModifiers {
        let readAt = ProcessInfo.processInfo.systemUptime
        let session = CGEventSource.flagsState(.combinedSessionState).rawValue
        let fnKeyDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Function))
        let sinceChange = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged)
        let sinceTyped = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let now = ProcessInfo.processInfo.systemUptime
        return SessionModifiers(session: session, fnKeyDown: fnKeyDown,
                                changedAt: date(lastChange: now - sinceChange, after: event, readAt: readAt),
                                typedAt: typed(lastKeyDown: now - sinceTyped, before: event))
    }

    /// When a key was last typed, given the session's last key down, if that was before the
    /// event a reading answers; nil otherwise. The event's own stamp is the moment of the change
    /// and not the reading's date, which a later change of another modifier moves. The session
    /// keeps only its latest key, so one typed since the event hides any typed before it, and a
    /// reading that answers no event places no key. A session with no key typed reports one
    /// near when the machine came up, taken as no earlier than that. [LAW:parse-dont-validate]
    static func typed(lastKeyDown: TimeInterval, before event: TimeInterval) -> TimeInterval? {
        let typed = max(lastKeyDown, 0)
        return typed < event ? typed : nil
    }

    /// When a reading taken at `readAt` has held its keys since, given the session's last
    /// change: not before the event it answers - it shows that change or a later one - and
    /// not after the reading. The session's last
    /// change is asked for after the keys are read, so it can be one the reading does not
    /// show; dated by it, a reading the app's confirm has already overtaken would arrive
    /// looking newer than the confirm and press a released key again.
    /// [LAW:no-ambient-temporal-coupling]
    static func date(lastChange: TimeInterval, after event: TimeInterval, readAt: TimeInterval) -> TimeInterval {
        min(max(lastChange, event), readAt)
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
            + ", changed at \(changedAt)" + (typedAt.map { ", typed at \($0)" } ?? ", a key typed since")
    }
}

/// What the input method tells the app unasked: the modifier keys it was just handed, which
/// the app hears its hotkey from, or a cursor it was just given focus in, which is the moment
/// words no cursor took can be offered again.
public enum Notice: Equatable, Sendable {
    case modifiersMoved(HeldModifiers)
    case cursorArrived
}

/// The app's end of the hotkey port: the named port the input method tells each `Notice` to.
/// One port for both, because the input method is sandboxed and this is the one name its
/// entitlements let it look up.
///
/// **Only this installation's input method is heard.** The name is one anyone can compute,
/// and a change heard from anyone else is a press anyone can fake, which opens the
/// microphone. So every message is checked against `senders` before its bytes are read, and
/// one that fails is told as `turnedAway` and never reaches `heard`. [LAW:single-enforcer]
///
/// Nothing is answered: the input method sends from the thread every key passes through, and
/// it waits for nothing there. A message that asked for an answer anyway has its reply right
/// released unanswered.
///
/// Held for as long as the app listens. Released, the name is free before the release
/// returns, because the app hosts it again straight away each time it rebuilds its hotkey;
/// so it is released off `queue`, which it waits for.
public final class NoticePort {
    private let port: NamedPort

    deinit { port.close() }

    /// Something the port did that nobody asked it for, said so the log can say it.
    public enum Event: CustomStringConvertible {
        /// A message from a process `senders` does not admit.
        case turnedAway(pid: pid_t, because: PeerIdentity.NotAdmitted, required: PeerIdentity)
        /// A message from the input method that is not a notice.
        case notUnderstood(id: mach_msg_id_t, bytes: Int?)
        /// Taking a message off the port failed for a reason of the kernel's.
        case receiveFailed(kern_return_t)

        public var description: String {
            switch self {
            case let .turnedAway(pid, because, required):
                "ignored a notice told by pid \(pid): \(because), and only \(required) is heard"
            case let .notUnderstood(id, bytes):
                "the input method sent message \(id) of \(bytes.map { "\($0) bytes" } ?? "an unreadable shape"), which is not a notice"
            case .receiveFailed(let status):
                "a message could not be taken off the hotkey port: \(Mach.describe(status))"
            }
        }
    }

    /// Hosts the hotkey port, hearing the input method and nobody else.
    /// `heard` and `told` run on `queue`, one message at a time, in the order they were sent.
    public convenience init(
        queue: DispatchQueue,
        told: @escaping @Sendable (Event) -> Void, heard: @escaping @Sendable (Notice) -> Void
    ) throws(PortNotHosted) {
        let senders: PeerIdentity
        do throws(PeerIdentity.Unreadable) {
            senders = try .signedLikeThisProcess(identifier: AppIdentity.inputMethodBundleIdentifier)
        } catch { throw .noRequirement(error) }
        try self.init(portName: AppIdentity.hotkeyPortName, senders: senders, queue: queue, told: told, heard: heard)
    }

    /// Under a name and a requirement someone else chose, which is how a test hosts one
    /// without being the app. [LAW:decomposition]
    init(
        portName: String, senders: PeerIdentity, queue: DispatchQueue,
        told: @escaping @Sendable (Event) -> Void, heard: @escaping @Sendable (Notice) -> Void
    ) throws(PortNotHosted) {
        port = try NamedPort(name: portName, queue: queue, received: { message in
            message.discardReply()
            do throws(PeerIdentity.NotAdmitted) {
                try senders.admits(message.sender)
            } catch {
                told(.turnedAway(pid: message.sender.pid, because: error, required: senders))
                return
            }
            // [LAW:parse-dont-validate] The border: past it there is a notice, and anything
            // else is said by name rather than dropped. [LAW:no-silent-failure]
            guard let notice = Wire.notice(id: message.id, payload: message.payload) else {
                told(.notUnderstood(id: message.id, bytes: message.payload?.count))
                return
            }
            heard(notice)
        }, failed: { told(.receiveFailed($0)) })
    }
}

/// The input method's end of the hotkey port: one message, sent and not waited on.
///
/// Called from the thread every key this source passes through is handled on, so it waits
/// for nothing: the app's queue is either taking messages or it is not. A change the app was
/// too busy to take is corrected by the next, since each carries the whole state, or - for a
/// release, which may have no next - by the app reading the session itself while a key is held.
/// A cursor arrival it missed costs only the wait for the next.
///
/// Nothing asks who holds the name before telling it. What crosses is which modifier keys
/// are down and that a cursor arrived, and the app is the one side that has something to
/// protect - its microphone - so it is the side that checks. [LAW:single-enforcer]
public struct NoticeSender: Sendable {
    private let portName: String

    /// How a message fared, said so the input method can log a change in it.
    public enum Told: Equatable, Sendable, CustomStringConvertible {
        case told
        /// No app is listening on the name: this installation's app is not running, or is
        /// hearing its hotkey some other way.
        case nobodyIsListening(port: String)
        /// The app is listening and did not take the message at once.
        case notTaken(port: String)
        case failed(port: String, status: kern_return_t)

        /// Whether this is something gone wrong rather than an ordinary state: nobody
        /// listening is how every app hearing its hotkey another way looks from here.
        public var isFault: Bool {
            switch self {
            case .told, .nobodyIsListening: false
            case .notTaken, .failed: true
            }
        }

        public var description: String {
            switch self {
            case .told: "the app hears this input method's notices"
            case .nobodyIsListening(let port): "nothing is listening on \(port), so the app does not hear this input method's notices"
            case .notTaken(let port): "the app on \(port) did not take a notice at once, so it missed that one"
            case let .failed(port, status): "a notice could not be sent to \(port): \(Mach.describe(status))"
            }
        }
    }

    public init() {
        self.init(portName: AppIdentity.hotkeyPortName)
    }

    init(portName: String) {
        self.portName = portName
    }

    public func tell(_ notice: Notice) -> Told {
        var remote = mach_port_t()
        guard lt_bootstrap_look_up(portName, &remote) == KERN_SUCCESS else { return .nobodyIsListening(port: portName) }
        defer { mach_port_deallocate(mach_task_self_, remote) }
        let (id, payload) = Wire.notice(notice)
        let sent = Mach.send(
            payload, id: id, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: Mach.noPort, timeout: .zero)
        return switch sent {
        case MACH_MSG_SUCCESS: .told
        // The app went away between the lookup and the send, which is the same fact as
        // finding nobody.
        case MACH_SEND_INVALID_DEST: .nobodyIsListening(port: portName)
        case MACH_SEND_TIMED_OUT: .notTaken(port: portName)
        default: .failed(port: portName, status: sent)
        }
    }
}
