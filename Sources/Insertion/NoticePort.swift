import Darwin
import DarwinCalls
import Identity
import Foundation

/// The app's end of the hotkey port: the named port the input method tells each cursor it is
/// given focus in to, which is the moment words no cursor took can be offered again, and its
/// ending itself over its memory ceiling, which is why it went away. Named
/// for the hotkey because that is the one name the input method's sandbox lets it look up.
///
/// **Only this installation's input method is heard.** The name is one anyone can compute,
/// and an arrival heard from anyone else would have the app offer held words to whatever has
/// focus. So every message is checked against `senders` before its bytes are read, and one
/// that fails is told as `turnedAway` and never reaches `cursorArrived`. [LAW:single-enforcer]
///
/// Nothing is answered: the input method sends from a task of its own and waits for
/// nothing. A message that asked for an answer anyway has its reply right released unanswered.
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
        /// A message from the input method that is no notice this app knows, or one whose
        /// payload is not what its id says.
        case notUnderstood(id: mach_msg_id_t, bytes: Int?)
        /// Taking a message off the port failed for a reason of the kernel's.
        case receiveFailed(kern_return_t)

        public var description: String {
            switch self {
            case let .turnedAway(pid, because, required):
                "ignored a notice told by pid \(pid): \(because), and only \(required) is heard"
            case let .notUnderstood(id, bytes):
                "the input method sent message \(id) of \(bytes.map { "\($0) bytes" } ?? "an unreadable shape"), which is no notice this app knows"
            case .receiveFailed(let status):
                "a message could not be taken off the hotkey port: \(Mach.describe(status))"
            }
        }
    }

    /// Hosts the hotkey port, hearing the input method and nobody else.
    /// `heard` and `told` run on `queue`, one message at a time, in the order they were sent.
    public convenience init(
        queue: DispatchQueue,
        told: @escaping @Sendable (Event) -> Void, heard: @escaping @Sendable (InputMethodNotice) -> Void
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
        told: @escaping @Sendable (Event) -> Void, heard: @escaping @Sendable (InputMethodNotice) -> Void
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
            guard let notice = Wire.notice(id: message.id, payload: message.payload, from: message.sender.pid) else {
                told(.notUnderstood(id: message.id, bytes: message.payload?.count))
                return
            }
            heard(notice)
        }, failed: { told(.receiveFailed($0)) })
    }
}

/// What the input method tells the app, from the process `pid` in each case. Who told it was
/// checked off the audit token before this was made.
public enum InputMethodNotice: Equatable, Sendable {
    case cursorArrived(CursorArrival)
    /// The input method is ending itself, holding more memory than its ceiling (IMK rule 7).
    case overMemoryCeiling(pid: pid_t, Overrun)
}

/// An input method's memory footprint over its ceiling, in bytes. One under or at the ceiling,
/// or past the most bytes a byte count can say, cannot be made, here or off the wire.
/// [LAW:parse-dont-validate]
public struct Overrun: Equatable, Sendable, Codable, CustomStringConvertible {
    public let footprint: UInt64
    public let ceiling: UInt64

    public init?(footprint: UInt64, ceiling: UInt64) {
        guard footprint > ceiling, footprint <= Int64.max else { return nil }
        self.footprint = footprint
        self.ceiling = ceiling
    }

    private enum CodingKeys: CodingKey { case footprint, ceiling }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let footprint = try container.decode(UInt64.self, forKey: .footprint)
        let ceiling = try container.decode(UInt64.self, forKey: .ceiling)
        guard let overrun = Overrun(footprint: footprint, ceiling: ceiling) else {
            throw DecodingError.dataCorruptedError(forKey: .footprint, in: container, debugDescription: "\(footprint) is not over \(ceiling)")
        }
        self = overrun
    }

    public var description: String {
        "holding \(Self.said(footprint)), over its \(Self.said(ceiling)) ceiling"
    }

    /// In the units Activity Monitor's Memory column uses.
    private static func said(_ bytes: UInt64) -> String { Int64(bytes).formatted(.byteCount(style: .memory)) }
}

/// A cursor the input method was given focus in, told by the input method process `pid`,
/// which said it is `build`, or said none, as every input method from before builds were
/// compared does. Who told it was checked off the audit token before this was made; the pid
/// only says which of the input method's processes it was.
public struct CursorArrival: Equatable, Sendable {
    public let pid: pid_t
    public let build: Build?

    public init(pid: pid_t, build: Build?) {
        self.pid = pid
        self.build = build
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
    private let build: Build?

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

    /// Telling each arrival with `build`, this input method's own, or with none when its
    /// bundle carries none.
    public init(build: Build?) {
        self.init(portName: AppIdentity.hotkeyPortName, build: build)
    }

    init(portName: String, build: Build?) {
        self.portName = portName
        self.build = build
    }

    /// Tells the app a cursor arrived, and which build says so.
    public func tellCursorArrived() -> Told { tell(Wire.said(build), id: Wire.cursorArrived) }

    /// Tells the app this input method is ending itself over its memory ceiling.
    public func tellOverMemoryCeiling(_ overrun: Overrun) -> Told { tell(Wire.overrun(overrun), id: Wire.overMemoryCeiling) }

    private func tell(_ payload: Data, id: mach_msg_id_t) -> Told {
        var remote = mach_port_t()
        guard lt_bootstrap_look_up(portName, &remote) == KERN_SUCCESS else { return .nobodyIsListening(port: portName) }
        defer { mach_port_deallocate(mach_task_self_, remote) }
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
