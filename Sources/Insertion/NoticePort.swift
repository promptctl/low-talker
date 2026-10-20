import Darwin
import DarwinCalls
import Identity
import Foundation

/// The app's end of the hotkey port: the named port the input method tells each cursor it is
/// given focus in to, which is the moment words no cursor took can be offered again. Named
/// for the hotkey because that is the one name the input method's sandbox lets it look up.
///
/// **Only this installation's input method is heard.** The name is one anyone can compute,
/// and an arrival heard from anyone else would have the app offer held words to whatever has
/// focus. So every message is checked against `senders` before its bytes are read, and one
/// that fails is told as `turnedAway` and never reaches `cursorArrived`. [LAW:single-enforcer]
///
/// Nothing is answered: the input method sends from its main thread and waits for nothing
/// there. A message that asked for an answer anyway has its reply right released unanswered.
///
/// Held for as long as the app listens. Released, the name is free before the release
/// returns, because the app hosts it again straight away each time it rebuilds its loop;
/// so it is released off `queue`, which it waits for.
public final class NoticePort {
    private let port: NamedPort

    deinit { port.close() }

    /// Something the port did that nobody asked it for, said so the log can say it.
    public enum Event: CustomStringConvertible {
        /// A message from a process `senders` does not admit.
        case turnedAway(pid: pid_t, because: PeerIdentity.NotAdmitted, required: PeerIdentity)
        /// A message from the input method that is not a cursor arrival.
        case notUnderstood(id: mach_msg_id_t, bytes: Int?)
        /// Taking a message off the port failed for a reason of the kernel's.
        case receiveFailed(kern_return_t)

        public var description: String {
            switch self {
            case let .turnedAway(pid, because, required):
                "ignored a notice told by pid \(pid): \(because), and only \(required) is heard"
            case let .notUnderstood(id, bytes):
                "the input method sent message \(id) of \(bytes.map { "\($0) bytes" } ?? "an unreadable shape"), which is not a cursor arrival"
            case .receiveFailed(let status):
                "a message could not be taken off the hotkey port: \(Mach.describe(status))"
            }
        }
    }

    /// Hosts the hotkey port, hearing the input method and nobody else.
    /// `cursorArrived` and `told` run on `queue`, one message at a time, in the order they were sent.
    public convenience init(
        queue: DispatchQueue,
        told: @escaping @Sendable (Event) -> Void, cursorArrived: @escaping @Sendable () -> Void
    ) throws(PortNotHosted) {
        let senders: PeerIdentity
        do throws(PeerIdentity.Unreadable) {
            senders = try .signedLikeThisProcess(identifier: AppIdentity.inputMethodBundleIdentifier)
        } catch { throw .noRequirement(error) }
        try self.init(portName: AppIdentity.hotkeyPortName, senders: senders, queue: queue, told: told, cursorArrived: cursorArrived)
    }

    /// Under a name and a requirement someone else chose, which is how a test hosts one
    /// without being the app. [LAW:decomposition]
    init(
        portName: String, senders: PeerIdentity, queue: DispatchQueue,
        told: @escaping @Sendable (Event) -> Void, cursorArrived: @escaping @Sendable () -> Void
    ) throws(PortNotHosted) {
        port = try NamedPort(name: portName, queue: queue, received: { message in
            message.discardReply()
            do throws(PeerIdentity.NotAdmitted) {
                try senders.admits(message.sender)
            } catch {
                told(.turnedAway(pid: message.sender.pid, because: error, required: senders))
                return
            }
            // [LAW:parse-dont-validate] The border: past it there is a cursor arrival, and
            // anything else is said by name rather than dropped. [LAW:no-silent-failure]
            guard Wire.isCursorArrival(id: message.id, payload: message.payload) else {
                told(.notUnderstood(id: message.id, bytes: message.payload?.count))
                return
            }
            cursorArrived()
        }, failed: { told(.receiveFailed($0)) })
    }
}

/// The input method's end of the hotkey port: one message, sent and not waited on, so it
/// waits for nothing: the app's queue is either taking messages or it is not. A cursor
/// arrival it missed costs only the wait for the next.
///
/// Nothing asks who holds the name before telling it. What crosses is that a cursor arrived,
/// and the app is the one side that has something to protect - the words it holds - so it is
/// the side that checks. [LAW:single-enforcer]
public struct NoticeSender: Sendable {
    private let portName: String

    /// How a message fared, said so the input method can log a change in it.
    public enum Told: Equatable, Sendable, CustomStringConvertible {
        case told
        /// No app is listening on the name: this installation's app is not running.
        case nobodyIsListening(port: String)
        /// The app is listening and did not take the message at once.
        case notTaken(port: String)
        case failed(port: String, status: kern_return_t)

        /// Whether this is something gone wrong rather than an ordinary state: nobody
        /// listening is how an app that is not running looks from here.
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

    /// Tells the app a cursor arrived.
    public func tellCursorArrived() -> Told {
        var remote = mach_port_t()
        guard lt_bootstrap_look_up(portName, &remote) == KERN_SUCCESS else { return .nobodyIsListening(port: portName) }
        defer { mach_port_deallocate(mach_task_self_, remote) }
        let sent = Mach.send(
            Data(), id: Wire.cursorArrived, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
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
