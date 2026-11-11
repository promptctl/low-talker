import Darwin
import DarwinCalls
import Foundation

/// Why a message to the far end of a named port came back with no answer to read. Each case is
/// what the kernel or the far end did, said without naming either process, because the app's
/// inserts and the input method's questions cross the same wire and fail it the same ways.
/// What a failure means for an insert's words is the inserter's to say (`Unreachable`).
/// [LAW:one-source-of-truth] [LAW:domain-language]
public enum WireFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// No process holds the name, or the one that did went away before the message was sent.
    case nobodyIsListening(port: String)
    /// The send timed out: the message never entered the far end's queue.
    case notTaken(port: String, after: Duration)
    /// The far end took the message and did not answer within the bound.
    case noAnswer(port: String, after: Duration)
    /// The far end took the message and let go of the way back without answering.
    case abandoned(port: String)
    /// Whoever answered is not the process this end asked for.
    case answeredByAStranger(port: String, pid: pid_t, because: PeerIdentity.NotAdmitted, required: PeerIdentity)
    /// A Mach status none of the others names, before the message was queued.
    case failedToSend(port: String, status: kern_return_t)
    /// A Mach status none of the others names, after the message was queued.
    case failedToReceive(port: String, status: kern_return_t)
    /// Bytes came back in a shape this build does not read: a far end of another build.
    case notReadable(port: String, bytes: Int)

    /// Whether the message reached the far end's queue, which is what decides whether it may
    /// have been acted on.
    public var queued: Bool {
        switch self {
        case .nobodyIsListening, .notTaken, .failedToSend: false
        case .noAnswer, .abandoned, .answeredByAStranger, .failedToReceive, .notReadable: true
        }
    }

    public var description: String {
        switch self {
        case let .nobodyIsListening(port): "nothing is listening on \(port)"
        case let .notTaken(port, after): "nothing on \(port) took the message within \(after)"
        case let .noAnswer(port, after): "\(port) took the message and did not answer within \(after)"
        case let .abandoned(port): "\(port) took the message and dropped it unanswered"
        case let .answeredByAStranger(port, pid, because, required): "pid \(pid) answered on \(port) and is not \(required) - \(because)"
        case let .failedToSend(port, status): "a message to \(port) could not be sent: \(Mach.describe(status))"
        case let .failedToReceive(port, status): "the answer from \(port) could not be received: \(Mach.describe(status))"
        case let .notReadable(port, bytes): "\(port) answered \(bytes) bytes in a shape this build does not read"
        }
    }
}

/// One exchange with the far end of a named port, from the side that asks: the name looked up
/// once, the reply right its answers come on, and who may answer them. Released with the
/// exchange. The app's inserter asks the input method through one, and the input method's
/// asker asks the app, so a message crosses and its answer is checked by one rule.
/// [LAW:single-enforcer] [LAW:one-type-per-behavior]
///
/// Every exchange makes its own reply right, so an answer to an earlier message cannot be read
/// as this one's. The answerer is checked before its bytes are returned: a name anyone can
/// compute is a name anyone can register first.
package final class Exchange {
    private let portName: String
    private let remote: mach_port_t
    private let reply: ReceiveRight
    private let answerer: PeerIdentity

    /// Looks the port up and makes the reply right, before any message is sent.
    package init(portName: String, answerer: PeerIdentity) throws(WireFailure) {
        var remote = mach_port_t()
        // [LAW:parse-dont-validate] The boundary: past here there is a port or a thrown
        // reason, never a maybe-port that later code has to keep asking about.
        guard lt_bootstrap_look_up(portName, &remote) == KERN_SUCCESS else {
            throw .nobodyIsListening(port: portName)
        }
        do throws(ReceiveRight.NotAllocated) { reply = try ReceiveRight(sendable: false) } catch {
            mach_port_deallocate(mach_task_self_, remote)
            throw .failedToSend(port: portName, status: error.status)
        }
        self.portName = portName
        self.remote = remote
        self.answerer = answerer
    }

    deinit { mach_port_deallocate(mach_task_self_, remote) }

    /// One message out and its answer's payload back, from the answerer and nobody else, each
    /// half bounded by `phase`.
    package func roundTrip(_ payload: Data, id: mach_msg_id_t, within phase: Duration) throws(WireFailure) -> Data {
        let sent = Mach.send(
            payload, id: id, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: reply.port, timeout: phase)
        switch sent {
        case MACH_MSG_SUCCESS:
            break
        case MACH_SEND_TIMED_OUT:
            throw .notTaken(port: portName, after: phase)
        // The far end went away between resolving the name and sending to it, which is the
        // same fact as never having found it and is said the same way.
        case MACH_SEND_INVALID_DEST:
            throw .nobodyIsListening(port: portName)
        default:
            throw .failedToSend(port: portName, status: sent)
        }
        let received: Mach.Received
        switch Mach.receive(on: reply.port, timeout: phase) {
        case .received(let arrived): received = arrived
        case .failed(MACH_RCV_TIMED_OUT): throw .noAnswer(port: portName, after: phase)
        case .failed(let status): throw .failedToReceive(port: portName, status: status)
        }
        received.discardReply()
        // The kernel's word that the right the answer was to come back on was destroyed
        // unanswered: the far end took the message and then went away, or dropped it.
        guard received.id != Mach.answerAbandoned else { throw .abandoned(port: portName) }
        do throws(PeerIdentity.NotAdmitted) {
            try answerer.admits(received.sender)
        } catch {
            throw .answeredByAStranger(port: portName, pid: received.sender.pid, because: error, required: answerer)
        }
        return received.payload ?? Data()
    }
}
