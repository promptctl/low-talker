import Darwin
import Identity
import Foundation
import DarwinCalls

/// Something that puts text at the cursor and says what happened.
///
/// The seam low-input-method-s71.b26's executor consumes, and the reason it is a protocol
/// rather than the concrete channel below: a test puts a double on this side of it and
/// never starts a second process. [LAW:decomposition] Nothing here mentions ports, input
/// methods or macOS - the caller's question is "did these words land", and that question
/// outlives whatever carries it.
public protocol Inserter: Sendable {
    /// Inserts `text` at the cursor `destination` admits, or throws why it did not: refused
    /// when the input method looked and would not, not yet taken when the app has not taken
    /// them, and otherwise whatever stopped the question reaching it.
    ///
    /// **Blocking, and not to be called on the main actor or from a task.** The one that
    /// crosses to the input method holds its thread in the kernel for up to its timeout, so
    /// on the main thread it would freeze the menu and every event for that long, and on a
    /// task it would hold a cooperative thread for the same.
    /// Said here rather than at the one implementation because this is the seam
    /// low-input-method-s71.b26's executor consumes, and the obligation belongs to whatever
    /// satisfies it. [LAW:no-ambient-temporal-coupling]
    func insert(_ text: String, into destination: Destination) throws(InsertFailure) -> Inserted
}

public extension Inserter {
    /// The same round trip asked for from inside a task, which is where the app asks from.
    ///
    /// The blocking call goes onto a thread of its own and the caller suspends, so nothing
    /// holds a cooperative thread or the main one for the length of the timeout - which is
    /// the obligation stated above, kept here once rather than by every caller that has to
    /// remember it. [LAW:single-enforcer]
    ///
    /// The `insert` inside is the blocking one: that closure is not async, so the overload
    /// it names is the protocol's own. An async caller writing `try await insert(text, into:)` gets
    /// this; there is no spelling of the call that is both awaited and blocking.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// **Not cancellable**, deliberately. A round trip already on the wire is a commit that
    /// may already have happened, so resuming a cancelled caller early would tell it the
    /// words did not land when they may have - the one conflation this module exists to
    /// prevent. What bounds the wait is the timeout, which is also the bound the answer
    /// names. [LAW:no-silent-failure]
    func insert(_ text: String, into destination: Destination) async throws(InsertFailure) -> Inserted {
        try await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: Result { () throws(InsertFailure) in try insert(text, into: destination) }) }.start()
        }.get()
    }
}

/// The app's end of the channel: one round trip to the input method.
///
/// Synchronous, with the wait bounded by the transport's own timeouts rather than by a
/// deadline this type keeps. An insert is two round trips - a greeting, then the words -
/// and each send and each receive is handed a QUARTER of `timeout`: the four phases share
/// the budget, so the call returns within `timeout` rather than within four times it, and
/// the error for a phase names that phase's own bound rather than a number nobody waited.
/// [LAW:no-ambient-temporal-coupling]
///
/// Words go only to this installation's input method, and only its answer is believed. The
/// port's name is one anyone can compute and so one anyone can publish first, and whatever
/// holds it would otherwise hear every dictation and say what it liked about where the
/// words went.
/// [LAW:single-enforcer] `PeerIdentity` is the check; this is its one caller here.
///
/// And only to that input method of this app's own build, which its greeting's answer says
/// before any words go. One of another build may read the words as something they are not,
/// or answer in a shape this end cannot read, and then nobody knows whether they landed.
/// `BuildMismatch` is that rule.
///
/// Nothing is retried. An input method that did not answer is one whose state nobody here
/// knows - it may have inserted the words and died before replying - and sending again
/// would be the one way to type the same sentence twice.
public struct InputMethodInserter: Inserter {
    private let portName: String
    private let timeout: Duration
    /// Who may answer. A failure to write the requirement is kept and thrown by every
    /// insert, so a build that cannot say who its input method is says so on each press
    /// rather than inserting through whoever answers. [LAW:no-silent-failure]
    private let answerer: Result<PeerIdentity, PeerIdentity.Unreadable>
    /// The build the words may go to: the app's own.
    private let build: Build

    /// What the app gives each insert, split evenly across its four phases. The input
    /// method's own bound on a client is set beneath one phase, so its answer naming a hung
    /// app arrives before this end stops listening; `CommitterTests` holds the two apart.
    public static let standardTimeout = Duration.seconds(5)

    /// Onto the input method's own insert port, answered only by a process signed like this
    /// one under the input method's identifier, and of `build`.
    public init(build: Build, timeout: Duration = standardTimeout) {
        self.init(
            portName: AppIdentity.inputMethodPortName, timeout: timeout,
            answerer: Result { () throws(PeerIdentity.Unreadable) in
                try .signedLikeThisProcess(identifier: AppIdentity.inputMethodBundleIdentifier)
            }, build: build)
    }

    /// Onto a port and an answerer someone else named, which is how a test puts its own port
    /// on the far end without installing an input method. [LAW:decomposition]
    package init(portName: String, timeout: Duration, answerer: Result<PeerIdentity, PeerIdentity.Unreadable>, build: Build) {
        self.portName = portName
        self.timeout = timeout
        self.answerer = answerer
        self.build = build
    }

    public func insert(_ text: String, into destination: Destination) throws(InsertFailure) -> Inserted {
        let answerer: PeerIdentity
        do throws(PeerIdentity.Unreadable) { answerer = try self.answerer.get() } catch { throw .answererUnreadable(error) }
        var remote = mach_port_t()
        // [LAW:parse-dont-validate] The boundary: past here there is a port or a thrown
        // reason, never a maybe-port that later code has to keep asking about.
        guard lt_bootstrap_look_up(portName, &remote) == KERN_SUCCESS else {
            throw .unreachable(.nothingIsListening(port: portName))
        }
        defer { mach_port_deallocate(mach_task_self_, remote) }
        let reply: ReceiveRight
        do throws(ReceiveRight.NotAllocated) { reply = try ReceiveRight(sendable: false) } catch { throw .unreachable(.failed(port: portName, status: error.status, words: .notSent)) }
        let phase = timeout / 4
        // Who holds the name is asked before a word is said to it. A name anyone can compute
        // is a name anyone can register first, and checking only the answer to the words
        // would be checking after the dictation had already gone to whoever that was. The
        // receive right the greeting is answered from is the one the words go to, and only
        // its holder can move it, so the process that answered is the process that hears.
        let greeting: Mach.Received
        do throws(Unreachable) {
            greeting = try roundTrip(
                Data(), id: Wire.greeting, to: remote, answeredOn: reply, by: answerer, within: phase, once: .notSent,
                unanswered: .didNotSayWhoItIs(port: portName, after: phase),
                // Dropped unanswered before any words went, which is a far end not answering.
                abandoned: .nothingIsListening(port: portName))
        } catch { throw .unreachable(error) }
        // The greeting's answer is the input method's build, or its refusal to listen, which is
        // thrown by name like any other.
        let said = greeting.payload ?? Data()
        switch Wire.greeting(of: said) {
        case .admitted(let inputMethod)?:
            if let mismatch = BuildMismatch(app: build, inputMethod: inputMethod) { throw .buildMismatch(mismatch) }
        case .refused(let refusal)?:
            throw .refused(refusal)
        case nil:
            throw .unreachable(.answerWasNotReadable(port: portName, bytes: said.count, words: .notSent))
        }
        let received: Mach.Received
        do throws(Unreachable) {
            received = try roundTrip(
                Wire.request(InsertRequest(text, into: destination)), id: Wire.insert, to: remote, answeredOn: reply, by: answerer, within: phase, once: .mayHaveLanded,
                unanswered: .answerDidNotArrive(port: portName, after: phase),
                abandoned: .answerWasAbandoned(port: portName))
        } catch { throw .unreachable(error) }
        let data = received.payload ?? Data()
        guard let answer = Wire.answer(of: data) else {
            throw .unreachable(.answerWasNotReadable(port: portName, bytes: data.count, words: .mayHaveLanded))
        }
        // [LAW:parse-dont-validate] The wire's sum ends here: past this line a refusal or
        // words not yet taken is a failure thrown like the others, and a caller holds words
        // inserted or nothing.
        switch answer {
        case .inserted(let characters, let into): return Inserted(characters: characters, into: into)
        case .refused(let refusal): throw .refused(refusal)
        case .notYetTaken(let characters, let into): throw .notYetTaken(NotYetTaken(characters: characters, into: into))
        }
    }

    /// One message out and its answer back, from `answerer` and nobody else, each half
    /// bounded by `phase`. What differs between the greeting and the words is only what a
    /// silence or a dropped question means, and where the words are `once` the message is
    /// in the far end's queue, so that is all the caller says. Before then they are not sent,
    /// whichever message this is: a send the kernel refuses leaves nothing queued.
    /// [LAW:one-type-per-behavior]
    private func roundTrip(
        _ payload: Data, id: mach_msg_id_t, to remote: mach_port_t, answeredOn reply: ReceiveRight,
        by answerer: PeerIdentity, within phase: Duration, once words: Words, unanswered: Unreachable, abandoned: Unreachable
    ) throws(Unreachable) -> Mach.Received {
        let sent = Mach.send(
            payload, id: id, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: reply.port, timeout: phase)
        switch sent {
        case MACH_MSG_SUCCESS:
            break
        case MACH_SEND_TIMED_OUT:
            throw Unreachable.requestWasNotTaken(port: portName, after: phase)
        // The far end went away between resolving the name and sending to it, which is the
        // same fact as never having found it and is said the same way.
        case MACH_SEND_INVALID_DEST:
            throw Unreachable.nothingIsListening(port: portName)
        default:
            throw Unreachable.failed(port: portName, status: sent, words: .notSent)
        }
        let received: Mach.Received
        switch Mach.receive(on: reply.port, timeout: phase) {
        case .received(let arrived): received = arrived
        case .failed(MACH_RCV_TIMED_OUT): throw unanswered
        case .failed(let status): throw Unreachable.failed(port: portName, status: status, words: words)
        }
        received.discardReply()
        // The kernel's word that the right the answer was to come back on was destroyed
        // unanswered: the far end took the message and then went away, or dropped it.
        guard received.id != Mach.answerAbandoned else { throw abandoned }
        do throws(PeerIdentity.NotAdmitted) {
            try answerer.admits(received.sender)
        } catch {
            throw Unreachable.answeredByAStranger(port: portName, pid: received.sender.pid, because: error, required: answerer, words: words)
        }
        return received
    }
}
