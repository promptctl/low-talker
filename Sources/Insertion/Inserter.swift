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
    /// Commits `request`: its `text` at the cursor its `destination` admits, in place of its
    /// `replacing`, or throws why it did not: refused when the input method looked and would
    /// not, not yet taken when the app has not taken them, and otherwise whatever stopped the
    /// question reaching it.
    ///
    /// **Blocking, and not to be called on the main actor or from a task.** The one that
    /// crosses to the input method holds its thread in the kernel for up to its timeout, so
    /// on the main thread it would freeze the menu and every event for that long, and on a
    /// task it would hold a cooperative thread for the same.
    /// Said here rather than at the one implementation because this is the seam
    /// low-input-method-s71.b26's executor consumes, and the obligation belongs to whatever
    /// satisfies it. [LAW:no-ambient-temporal-coupling]
    func insert(_ request: InsertRequest) throws(InsertFailure) -> Inserted
}

public extension Inserter {
    /// Inserts `text` where `destination` admits, replacing nothing.
    func insert(_ text: String, into destination: Destination) throws(InsertFailure) -> Inserted {
        try insert(InsertRequest(text, into: destination))
    }

    /// The same round trip asked for from inside a task, which is where the app asks from.
    ///
    /// The blocking call goes onto a thread of its own and the caller suspends, so nothing
    /// holds a cooperative thread or the main one for the length of the timeout - which is
    /// the obligation stated above, kept here once rather than by every caller that has to
    /// remember it. [LAW:single-enforcer]
    ///
    /// The `insert` inside is the blocking one: that closure is not async, so the overload
    /// it names is the protocol's own. An async caller writing `try await insert(request)` gets
    /// this; there is no spelling of the call that is both awaited and blocking.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// **Not cancellable**, deliberately. A round trip already on the wire is a commit that
    /// may already have happened, so resuming a cancelled caller early would tell it the
    /// words did not land when they may have - the one conflation this module exists to
    /// prevent. What bounds the wait is the timeout, which is also the bound the answer
    /// names. [LAW:no-silent-failure]
    func insert(_ request: InsertRequest) async throws(InsertFailure) -> Inserted {
        try await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: Result { () throws(InsertFailure) in try insert(request) }) }.start()
        }.get()
    }

    func insert(_ text: String, into destination: Destination) async throws(InsertFailure) -> Inserted {
        try await insert(InsertRequest(text, into: destination))
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
/// To that input method of whatever build: the wire is read across builds (`Wire`), so an
/// input method that cannot do a request refuses it and the words are held, and an answer
/// this build cannot read is never taken for words that did not land.
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

    /// What the app gives each insert, split evenly across its four phases. The input
    /// method's own bound on a client is set beneath one phase, so its answer naming a hung
    /// app arrives before this end stops listening; `CommitterTests` holds the two apart.
    public static let standardTimeout = Duration.seconds(5)

    /// Onto the input method's own insert port, answered only by a process signed like this
    /// one under the input method's identifier.
    public init(timeout: Duration = standardTimeout) async {
        // The identity is read once here and kept; a failure to read it is kept too and thrown
        // by every insert (see `answerer`). `signedLikeThisProcess` runs the read off the
        // caller's actor, which is why this init is async. [LAW:single-enforcer]
        let answerer: Result<PeerIdentity, PeerIdentity.Unreadable>
        do throws(PeerIdentity.Unreadable) {
            answerer = .success(try await .signedLikeThisProcess(identifier: AppIdentity.inputMethodBundleIdentifier))
        } catch { answerer = .failure(error) }
        self.init(portName: AppIdentity.inputMethodPortName, timeout: timeout, answerer: answerer)
    }

    /// Onto a port and an answerer someone else named, which is how a test puts its own port
    /// on the far end without installing an input method. [LAW:decomposition]
    package init(portName: String, timeout: Duration, answerer: Result<PeerIdentity, PeerIdentity.Unreadable>) {
        self.portName = portName
        self.timeout = timeout
        self.answerer = answerer
    }

    public func insert(_ request: InsertRequest) throws(InsertFailure) -> Inserted {
        let answerer: PeerIdentity
        do throws(PeerIdentity.Unreadable) { answerer = try self.answerer.get() } catch { throw .answererUnreadable(error) }
        // Nothing has been said to the far end before the greeting, so failing to reach it is a
        // greeting's failure.
        let exchange: Exchange
        do throws(WireFailure) { exchange = try Exchange(portName: portName, answerer: answerer) } catch {
            throw .unreachable(Unreachable(error, at: .greeting))
        }
        try greet(through: exchange)
        let data = try say(Wire.request(request), id: Wire.insert, through: exchange, at: .words)
        guard let answer = Wire.answer(of: data) else { throw unread(data, at: .words) }
        // [LAW:parse-dont-validate] The wire's sum ends here: past this line a refusal or
        // words not yet taken is a failure thrown like the others, and a caller holds words
        // inserted or nothing.
        switch answer {
        case .inserted(let characters, let into): return Inserted(characters: characters, into: into)
        case .refused(let refusal): throw .refused(refusal)
        case .notYetTaken(let characters, let into): throw .notYetTaken(NotYetTaken(characters: characters, into: into))
        }
    }

    /// The greeting every insert is preceded by. Who holds the name is asked before a word is
    /// said to it. A name anyone can compute is a name anyone can register first, and checking
    /// only the answer to the words would be checking after the dictation had already gone to
    /// whoever that was. The receive right the greeting is answered from is the one the words go
    /// to, and only its holder can move it, so the process that answered is the process that hears.
    private func greet(through exchange: Exchange) throws(InsertFailure) {
        let said = try say(Data(), id: Wire.greeting, through: exchange, at: .greeting)
        // The greeting's answer is the input method's build, or its refusal to listen, which is
        // thrown by name like any other.
        switch Wire.greeting(of: said) {
        case .admitted?: return
        case .refused(let refusal)?: throw .refused(refusal)
        case nil: throw unread(said, at: .greeting)
        }
    }

    /// One step of the insert across the wire. Each step's send and its receive get a quarter of
    /// the budget apiece, so the whole insert returns within `timeout`.
    private func say(_ payload: Data, id: mach_msg_id_t, through exchange: Exchange, at step: Unreachable.Step) throws(InsertFailure) -> Data {
        do throws(WireFailure) { return try exchange.roundTrip(payload, id: id, within: timeout / 4) } catch {
            throw .unreachable(Unreachable(error, at: step))
        }
    }

    /// What an answer this build could not read says: a refusal for a reason only another
    /// build names, which commits nothing, or no answer at all. [LAW:single-enforcer] The one
    /// reading of unread bytes, for the greeting and the words alike.
    private func unread(_ data: Data, at step: Unreachable.Step) -> InsertFailure {
        Wire.refusalReason(of: data).map(InsertFailure.refusedForAnUnknownReason)
            ?? .unreachable(Unreachable(.notReadable(port: portName, bytes: data.count), at: step))
    }
}
