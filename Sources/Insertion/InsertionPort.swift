import Darwin
import Identity
import Foundation
import DarwinCalls

/// The input method's end of the channel: the named port the app sends to.
///
/// [LAW:effects-at-boundaries] Hosting the port, checking who sent each request and
/// decoding its bytes is all this does. What to do with the request is the closure's, and the
/// closure is where the text input system lives - so the half that knows about macOS
/// clients knows nothing about ports, and this half knows nothing about clients.
///
/// **Only this installation's app is answered.** The name is derived from the public bundle
/// identifier, so any process running as the person can compute it, and a request answered
/// without asking who sent it is text typed into the front window for anyone, with no grant
/// at all. So every request is checked against `senders` before its bytes are read, and one
/// that fails is answered `senderIsNotThisInstallationsApp` and told to `turnedAway` - the
/// insert closure never sees it. [LAW:single-enforcer]
///
/// Both closures run on `queue`, one request at a time, and the answer is sent when the
/// closure returns. Whatever the closure touches that lives elsewhere, it reaches itself:
/// the input method hosts this on a queue of its own and asks the main actor only which
/// cursor is in front, so a slow answer never holds the keys the main thread handles.
/// [LAW:no-ambient-temporal-coupling]
///
/// Held for the life of the process by whoever makes it. Released, the port closes and the
/// app's next request finds nothing listening; a request already being answered finishes
/// first, because the port is only taken down once the queue is out of it.
public final class InsertionPort {
    private let port: NamedPort

    /// Something the port did that nobody asked it for, said so the log can say it.
    public enum Event: CustomStringConvertible {
        /// A request from a process `senders` does not admit, answered with a refusal.
        case turnedAway(pid: pid_t, because: PeerIdentity.NotAdmitted, required: PeerIdentity)
        /// An answer that could not be delivered: the sender is gone, or asked in a shape
        /// that leaves nowhere to answer.
        case answerNotDelivered(kern_return_t)
        /// Taking a request off the port failed for a reason of the kernel's.
        case receiveFailed(kern_return_t)

        public var description: String {
            switch self {
            case let .turnedAway(pid, because, required):
                "refused an insert from pid \(pid): \(because), and only \(required) may insert"
            case .answerNotDelivered(let status):
                "an answer could not be delivered: \(Mach.describe(status))"
            case .receiveFailed(let status):
                "a request could not be taken off the port: \(Mach.describe(status))"
            }
        }
    }

    /// Hosts the insert port, admitting the app and nobody else, and answering each greeting
    /// with `build`, this input method's own, or with none when its bundle carries none.
    public convenience init(
        build: Build?, queue: DispatchQueue,
        told: @escaping @Sendable (Event) -> Void, answer: @escaping @Sendable (InsertRequest) -> InsertionAnswer
    ) throws(PortNotHosted) {
        let senders: PeerIdentity
        do throws(PeerIdentity.Unreadable) { senders = try .signedLikeThisProcess(identifier: AppIdentity.bundleIdentifier) } catch { throw .noRequirement(error) }
        try self.init(portName: AppIdentity.inputMethodPortName, senders: senders, build: build, queue: queue, told: told, answer: answer)
    }

    /// Under a name and a requirement someone else chose, which is how a test hosts one
    /// without being an input method. [LAW:decomposition]
    convenience init(
        portName: String, senders: PeerIdentity, build: Build?, queue: DispatchQueue,
        told: @escaping @Sendable (Event) -> Void, answer: @escaping @Sendable (InsertRequest) -> InsertionAnswer
    ) throws(PortNotHosted) {
        try self.init(portName: portName, queue: queue, told: told) { request in
            do throws(PeerIdentity.NotAdmitted) {
                try senders.admits(request.sender)
            } catch {
                told(.turnedAway(pid: request.sender.pid, because: error, required: senders))
                return Wire.answer(.refused(.senderIsNotThisInstallationsApp))
            }
            // The greeting is answered with the build: the sender has been admitted, and it
            // decides whether this build is one to send its words to. [LAW:single-enforcer]
            // [LAW:dataflow-not-control-flow] The id is the wire's own discriminator, and
            // these are its two values.
            guard request.id != Wire.greeting else { return Wire.said(build) }
            // Bytes that are not a request are answered, never dropped: a sender that hears
            // nothing waits out its timeout and learns nothing. [LAW:no-silent-failure]
            let asked = request.payload.flatMap(Wire.request(of:))
            return Wire.answer(asked.map(answer) ?? .refused(.requestWasNotReadable))
        }
    }

    /// A port that answers each message with whatever `respond` makes of it - the channel
    /// with nobody checked, which only the initializer above and the suite's hand-made far
    /// ends build on.
    init(portName: String, queue: DispatchQueue, told: @escaping @Sendable (Event) -> Void, respond: @escaping @Sendable (Mach.Received) -> Data) throws(PortNotHosted) {
        port = try NamedPort(name: portName, queue: queue, received: { request in
            let sent = request.answer(respond(request))
            if sent != MACH_MSG_SUCCESS { told(.answerNotDelivered(sent)) }
        }, failed: { told(.receiveFailed($0)) })
    }
}
