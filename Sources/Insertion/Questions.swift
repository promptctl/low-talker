import Darwin
import DarwinCalls
import Foundation
import Identity
import os

/// What the app owes the keyboard when the input method is holding a Return or an Escape: the
/// answer to its first question, which both keys ask. [LAW:types-are-the-program] Two values and
/// no third: an app that said nothing has admitted nothing, and that is the asker's to read, not
/// a case here.
public enum Owing: String, Codable, Sendable {
    /// No press is open and no word is on its way to a cursor.
    case nothing
    /// A press is open, or its words are not all acknowledged yet.
    case words
}

/// How a debt the app admitted to ended, the answer to the second question: every insert it
/// had accepted before the Return is acknowledged, or the words did not all reach a cursor.
public enum Settlement: String, Codable, Sendable {
    case landed
    case notLanded
}

/// What the input method asks the app about a Return it is holding, stamped with the moment the
/// key went down on the clock every key event is stamped by, so the audio is cut where the key
/// was typed and not where the question arrived.
public enum Question: Equatable, Sendable {
    /// Is anything owed? Answered at once, from the port's own queue.
    case owed(at: TimeInterval)
    /// Say when everything owed has settled. Answered later, from the main actor.
    case settled(at: TimeInterval)
}

/// Whatever can answer the questions: the right a question came with, or a test's stand-in,
/// so what the app decides is held without a Mach port. [LAW:decomposition]
public protocol Answering: Sendable {
    func send(_ owing: Owing) -> Reply.Delivery
    func send(_ settlement: Settlement) -> Reply.Delivery
}

/// The one right to answer a question, owned by whoever holds this. Answering consumes it, and
/// a reply that is dropped unanswered releases the right, so the asker hears that it was
/// abandoned rather than waiting out its bound. [LAW:no-silent-failure]
public final class Reply: Answering {
    /// How an answer fared. Whether the asker was still waiting is not here: the kernel accepts
    /// a message to a send-once right whose receive end is gone (measured in `QuestionsTests`),
    /// so a late answer cannot be told from a timely one at the sender.
    public enum Delivery: Equatable, Sendable {
        case delivered
        case failed(kern_return_t)
    }

    private let message: Mach.Received
    private let answered = OSAllocatedUnfairLock(initialState: false)

    init(_ message: Mach.Received) { self.message = message }

    public func send(_ owing: Owing) -> Delivery { send(Wire.owing(owing)) }
    public func send(_ settlement: Settlement) -> Delivery { send(Wire.settlement(settlement)) }

    private func send(_ payload: Data) -> Delivery {
        let first = answered.withLock { answered in
            defer { answered = true }
            return !answered
        }
        precondition(first, "a question is answered once")
        let status = message.answer(payload)
        return status == MACH_MSG_SUCCESS ? .delivered : .failed(status)
    }

    deinit {
        if !answered.withLock({ $0 }) { message.discardReply() }
    }
}

/// Why a question came back with no answer from this installation's app. Each is a fact the
/// asker can act on; none is an answer. [LAW:types-are-the-program]
public enum NotAnswered: Error, Equatable, Sendable, CustomStringConvertible {
    /// No app is listening on the name: the app is not running.
    case nobodyIsListening(port: String)
    /// This process cannot say who the app's signature must be, so no answer could be
    /// believed.
    case unverifiable(PeerIdentity.Unreadable)
    /// Nothing arrived within the bound, whether the question went unheard or the answer
    /// was never made.
    case silent(after: Duration)
    /// The app dropped the question: it quit, or let go of the right to answer.
    case abandoned
    /// Someone answered who is not this installation's app.
    case notBelieved(PeerIdentity.NotAdmitted)
    case notReadable(bytes: Int)
    case failed(port: String, status: kern_return_t)

    public var description: String {
        switch self {
        case .nobodyIsListening(let port): "nothing is listening on \(port)"
        case .unverifiable(let why): "no answer can be believed, because this process cannot say who the app is: \(why)"
        case .silent(let bound): "no answer came within \(bound)"
        case .abandoned: "the app dropped the question unanswered"
        case .notBelieved(let why): "an answer came from someone who is not this installation's app: \(why)"
        case .notReadable(let bytes): "an answer of \(bytes) bytes is not one this input method knows"
        case let .failed(port, status): "a question could not be asked on \(port): \(Mach.describe(status))"
        }
    }
}

/// The input method's end of the questions: one round trip to the app per question, answered
/// only by this installation's app.
///
/// The notice channel's other messages are sent and not waited on, so the input method's
/// queue never depends on the app. These are the exception, and they are only ever made from a
/// thread made for one Return, never from the main thread or a queue anything else shares.
/// Every call makes its own reply port, so an answer to an earlier question cannot be read as
/// this one's. [LAW:no-ambient-temporal-coupling]
///
/// The answerer is checked before its bytes are read, as the app checks the input method: a
/// name anyone can compute is a name anyone can register first, and a process holding it could
/// otherwise make every Return typed anywhere wait. [LAW:single-enforcer]
public struct Asker: Sendable {
    private let portName: String
    private let answerer: Result<PeerIdentity, PeerIdentity.Unreadable>

    /// Asking the app, which `answerer` says how to recognise: the signature of this
    /// installation's app, or the reason it could not be read.
    public init(answerer: Result<PeerIdentity, PeerIdentity.Unreadable>) {
        self.init(portName: AppIdentity.hotkeyPortName, answerer: answerer)
    }

    init(portName: String, answerer: Result<PeerIdentity, PeerIdentity.Unreadable>) {
        self.portName = portName
        self.answerer = answerer
    }

    /// Whether the app owes anything, within `bound`.
    public func owed(at timestamp: TimeInterval, within bound: Duration) -> Result<Owing, NotAnswered> {
        ask(Wire.owed, Wire.stamp(timestamp), within: bound, read: Wire.owing(of:))
    }

    /// Whether what the app owes landed, within `bound`.
    public func settled(at timestamp: TimeInterval, within bound: Duration) -> Result<Settlement, NotAnswered> {
        ask(Wire.settled, Wire.stamp(timestamp), within: bound, read: Wire.settlement(of:))
    }

    private func ask<Answer>(_ id: mach_msg_id_t, _ payload: Data, within bound: Duration, read: (Data) -> Answer?) -> Result<Answer, NotAnswered> {
        let answerer: PeerIdentity
        do throws(PeerIdentity.Unreadable) { answerer = try self.answerer.get() } catch { return .failure(.unverifiable(error)) }
        var remote = mach_port_t()
        guard lt_bootstrap_look_up(portName, &remote) == KERN_SUCCESS else { return .failure(.nobodyIsListening(port: portName)) }
        defer { mach_port_deallocate(mach_task_self_, remote) }
        let reply: ReceiveRight
        do throws(ReceiveRight.NotAllocated) { reply = try ReceiveRight(sendable: false) } catch { return .failure(.failed(port: portName, status: error.status)) }
        let sent = Mach.send(
            payload, id: id, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: reply.port, timeout: bound)
        switch sent {
        case MACH_MSG_SUCCESS: break
        case MACH_SEND_TIMED_OUT: return .failure(.silent(after: bound))
        case MACH_SEND_INVALID_DEST: return .failure(.nobodyIsListening(port: portName))
        default: return .failure(.failed(port: portName, status: sent))
        }
        let received: Mach.Received
        switch Mach.receive(on: reply.port, timeout: bound) {
        case .received(let arrived): received = arrived
        case .failed(MACH_RCV_TIMED_OUT): return .failure(.silent(after: bound))
        case .failed(let status): return .failure(.failed(port: portName, status: status))
        }
        received.discardReply()
        guard received.id != Mach.answerAbandoned else { return .failure(.abandoned) }
        do throws(PeerIdentity.NotAdmitted) { try answerer.admits(received.sender) } catch { return .failure(.notBelieved(error)) }
        guard let payload = received.payload, let answer = read(payload) else {
            return .failure(.notReadable(bytes: received.payload?.count ?? 0))
        }
        return .success(answer)
    }
}
