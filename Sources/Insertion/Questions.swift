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

/// Whether the app's word box is open: the answer to whether an Escape is the app's to cancel with.
/// [LAW:types-are-the-program] Two values: the box is open, or it is not.
public enum PanelState: String, Codable, Sendable {
    case shut
    case shown
}

/// What the input method asks the app about a key it is holding, stamped with the moment the
/// key went down on the clock every key event is stamped by, so the audio is cut where the key
/// was typed and not where the question arrived.
public enum Question: Equatable, Sendable {
    /// Is anything owed? Answered at once, from the port's own queue. A Return asks it first.
    case owed(at: TimeInterval)
    /// Say when everything owed has settled. Answered later, from the main actor.
    case settled(at: TimeInterval)
    /// Is the word box open? An Escape is kept for the app when it is. Answered from the main actor.
    case panel(at: TimeInterval)
}

/// Whatever can answer the questions: the right a question came with, or a test's stand-in,
/// so what the app decides is held without a Mach port. [LAW:decomposition]
public protocol Answering: Sendable {
    func send(_ owing: Owing) -> Reply.Delivery
    func send(_ settlement: Settlement) -> Reply.Delivery
    func send(_ panel: PanelState) -> Reply.Delivery
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
    public func send(_ panel: PanelState) -> Delivery { send(Wire.panelState(panel)) }

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
    /// The wire did not carry the question and its answer, failing it as it fails an insert.
    case wire(WireFailure)
    /// This process cannot say who the app's signature must be, so no answer could be
    /// believed, and nothing was asked.
    case unverifiable(PeerIdentity.Unreadable)

    public var description: String {
        switch self {
        case .wire(let failure): "\(failure)"
        case .unverifiable(let why): "no answer can be believed, because this process cannot say who the app is: \(why)"
        }
    }
}

/// The questions a held key asks the app: `Asker` is the real one, `FakeApp` the one a test asks,
/// and `QuestionsContract` holds the two to the same answers. [LAW:decomposition]
public protocol SteeringAsking: Sendable {
    func owed(at timestamp: TimeInterval, within bound: Duration) -> Result<Owing, NotAnswered>
    func settled(at timestamp: TimeInterval, within bound: Duration) -> Result<Settlement, NotAnswered>
    func panel(at timestamp: TimeInterval, within bound: Duration) -> Result<PanelState, NotAnswered>
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
public struct Asker: SteeringAsking {
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

    /// Whether the app's word box is open, within `bound`.
    public func panel(at timestamp: TimeInterval, within bound: Duration) -> Result<PanelState, NotAnswered> {
        ask(Wire.panel, Wire.stamp(timestamp), within: bound, read: Wire.panelState(of:))
    }

    private func ask<Answer>(_ id: mach_msg_id_t, _ payload: Data, within bound: Duration, read: (Data) -> Answer?) -> Result<Answer, NotAnswered> {
        let answerer: PeerIdentity
        do throws(PeerIdentity.Unreadable) { answerer = try self.answerer.get() } catch { return .failure(.unverifiable(error)) }
        do throws(WireFailure) {
            let said = try Exchange(portName: portName, answerer: answerer).roundTrip(payload, id: id, within: bound)
            guard let answer = read(said) else { throw .notReadable(port: portName, bytes: said.count) }
            return .success(answer)
        } catch { return .failure(.wire(error)) }
    }
}
