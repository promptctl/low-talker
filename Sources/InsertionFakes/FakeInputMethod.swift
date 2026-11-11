import Dispatch
import Foundation
import Insertion
import Synchronization
import TestProbes

/// An input method that records every request it was handed, answers that it reached the app it
/// is told, refuses an insert bound to another app as the real one does, and refuses or holds an
/// insert when a test says so. The one `Inserter` fake, since each behavior is a value; the
/// `InserterContract` holds it to the answers `InputMethodInserter` reads from a real port.
/// [LAW:composability] [LAW:one-type-per-behavior]
///
/// Asked on a thread of the executor's choosing: `Inserter`'s awaited overload puts the
/// blocking call on a thread of its own, which is also what lets a held insert block here
/// without holding the main actor.
public final class FakeInputMethod: Inserter, Sendable {
    private struct State {
        var requests: [InsertRequest] = []
        var inserted: [String] = []
        var into = "com.apple.TextEdit"
        var refusal: InsertFailure?
        var gate: DispatchSemaphore?
        var holding = 0
        /// What the app's document holds: every insert's text in order, less the text a take-back
        /// replaced, so what a cancel leaves in the field is read off it.
        var field = ""
        var takeBackRefusal: InsertFailure?
        /// An insert that fails as the app not answering, whose words landed anyway.
        var landingDespiteFailure = false
    }

    private let state = Mutex(State())
    /// A test's signal, moved whenever this fake's state changes so a test awaits the change
    /// instead of polling for it. [LAW:no-ambient-temporal-coupling]
    private let onChange = Mutex<Changes?>(nil)

    public init() {}

    public func noting(_ changes: Changes) { onChange.withLock { $0 = changes } }
    private func moved() { onChange.withLock { $0 }?.note() }

    /// Every text put at the cursor, in order. A held insert is not in it until it is let go.
    public var inserted: [String] { state.withLock { $0.inserted } }
    /// Where each request it was handed was bound, answered or refused, in order.
    public var destinations: [Destination] { state.withLock { $0.requests.map(\.destination) } }
    /// The document the inserts went into, as it stands: what a cancel is read against.
    public var field: String { state.withLock { $0.field } }
    /// The texts every request to take words back named, held, answered or refused.
    public var takeBacks: [String] { state.withLock { $0.requests.map(\.replacing).filter { !$0.isEmpty } } }
    /// How many inserts it was asked for, answered or refused.
    public var asked: Int { state.withLock { $0.requests.count } }
    /// How many inserts are held at the gate now.
    public var holding: Int { state.withLock { $0.holding } }

    /// Every take-back from now on is refused with `refusal`, or none is when it is nil.
    public func refusingTakeBack(_ refusal: InsertFailure?) { state.withLock { $0.takeBackRefusal = refusal } }
    /// An insert refused with a failure that may have landed lands in the document anyway, which is
    /// what the failure means: the words are somewhere nobody was told.
    public func landingDespiteFailure(_ lands: Bool = true) { state.withLock { $0.landingDespiteFailure = lands } }
    /// The app the next inserts say they reached, by bundle identifier.
    public func reaching(_ app: String) { state.withLock { $0.into = app } }
    /// Every insert from now on is refused with `refusal`, or none is when it is nil.
    public func refusing(_ refusal: InsertFailure?) { state.withLock { $0.refusal = refusal } }
    /// Every insert from now on waits until `letGo`, the way a real one waits for the app to
    /// answer - held at a gate rather than for a duration. [LAW:no-ambient-temporal-coupling]
    public func hold() { state.withLock { $0.gate = DispatchSemaphore(value: 0) } }
    /// Lets the held insert through, and holds none after it.
    public func letGo() {
        let gate = state.withLock { state in
            defer { state.gate = nil }
            return state.gate
        }
        gate?.signal()
    }

    public func insert(_ request: InsertRequest) throws(InsertFailure) -> Inserted {
        // Every exit - the text landing, a refusal thrown, a take-back - moves the signal, so a
        // test awaits the insert resolving. The hold below moves it separately, before it blocks.
        defer { moved() }
        let (text, destination) = (request.text, request.destination)
        state.withLock { $0.requests.append(request) }
        if let gate = state.withLock({ $0.gate }) {
            state.withLock { $0.holding += 1 }
            moved()
            gate.wait()
            state.withLock { $0.holding -= 1 }
        }
        return try state.withLock { state throws(InsertFailure) in
            // A request that replaces text is a take-back, proved by the input method's own rule
            // over the document read as a client with its caret at the end and nothing selected.
            // [LAW:one-source-of-truth]
            if !request.replacing.isEmpty {
                if let refusal = state.takeBackRefusal { throw refusal }
                guard destination.admits(state.into) else { throw .refused(.dictationIsInAnotherApp) }
                let field = Array(state.field.utf16)
                let found = Replacement.range(of: request.replacing, selection: { NSRange(location: field.count, length: 0) },
                                              text: { String(decoding: field[$0.location..<NSMaxRange($0)], as: UTF16.self) })
                guard case .success(let range) = found else { throw .refused(.wordsCannotBeTakenBack) }
                // The range is replaced by the request's text, as the client's commit puts it.
                state.field = String(decoding: field[..<range.location], as: UTF16.self) + text
                if !text.isEmpty { state.inserted.append(text) }
                return Inserted(characters: text.count, into: state.into)
            }
            if let refusal = state.refusal {
                if state.landingDespiteFailure, refusal.wordsMayHaveLanded { state.field += text }
                throw refusal
            }
            guard destination.admits(state.into) else { throw .refused(.dictationIsInAnotherApp) }
            state.inserted.append(text)
            state.field += text
            return Inserted(characters: text.count, into: state.into)
        }
    }
}
