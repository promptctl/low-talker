import Foundation
import Insertion
import os

/// Where an insert's words are committed, and how long its answer waits for them.
///
/// On the main actor, in the same turn that chose the cursor (IMK rule 4): the field is read
/// and `insertText` is made there, synchronously, and nowhere else. The insert port's queue
/// reaches it through one hop and waits at most `bound`, because the call into the app is
/// macOS's and not this process's to trust. Measured on studious (low-imk-rules-w3g.3ky), an
/// `insertText` into an app stalled while taking it holds the main actor 3.0 s and then returns
/// as if nothing were wrong; the words land when the app wakes. Keys typed into another app
/// meanwhile arrive as fast as when nothing is stalled (median 3.4 ms), because this source asks
/// for no keys. So a commit still running when `bound` passes is answered `notYetTaken`, and the
/// bound sits beneath both that 3 s and one phase of the app's own wait.
///
/// [LAW:no-ambient-temporal-coupling] The main queue is serial, so words asked for in order
/// land in order. A commit holding the main actor holds every insert behind it, whichever app
/// those are for: past `bound` they are refused as the input method being busy, and a `Turn`
/// makes sure that a refused insert never commits once the main actor does reach it. Words
/// refused are words the app holds, so they are offered again rather than lost; words
/// committed after a refusal would be typed twice.
///
/// **What `inserted` claims, exactly: `insertText` returned on the main actor, into the client
/// of the app in front, which had answered that it gives document access with its caret on a
/// screen or nowhere it reported.** Not that a person saw them: the text input system offers
/// no delivery report, and measured on 2026-09-22 there is nothing to derive one from. iTerm2,
/// where the words land in plain sight, answers `length()` of 0 before and after, so a check
/// for "did the document grow" would refuse the terminal. The client's field is asked about
/// before the commit instead (`FocusedClient`). [LAW:no-silent-failure]
public nonisolated final class Committer: Sendable {
    /// One phase of the app's wait is 1.25 s, and IMK's own wait on a hung app is 3 s;
    /// `CommitterTests` holds this beneath both.
    public static let standardBound = Duration.seconds(1)

    private let bound: Duration
    /// Where each main-actor turn's end is said, once it has run.
    private let told: @Sendable (Ended) -> Void
    /// [LAW:no-shared-mutable-globals] Owned here and advanced only by `insert`. Numbers the
    /// two lines an insert writes, so the port's answer and the main actor's end can be read
    /// together.
    private let inserts = OSAllocatedUnfairLock(initialState: 0)

    public init(bound: Duration = standardBound, told: @escaping @Sendable (Ended) -> Void) {
        self.bound = bound
        self.told = told
    }

    /// Answers `request` within `bound`, from what the main actor does with it: `inFront` is
    /// asked there for the cursor, and the words are committed there. Blocks the caller for
    /// at most `bound`, so it belongs on a queue that is not the main one; on the main one it
    /// would wait out its own turn, and it stops there instead. [LAW:no-silent-failure]
    public func insert(_ request: InsertRequest, inFront: @escaping @MainActor @Sendable () -> InFront) -> Placed {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let number = inserts.withLock { count in
            count += 1
            return count
        }
        let turn = Turn()
        let asked = ContinuousClock.now
        DispatchQueue.main.async { [told] in
            let waited = ContinuousClock.now - asked
            let did = MainActor.assumeIsolated { Self.place(request, turn: turn, inFront: inFront) }
            told(Ended(insert: number, waited: waited, did: did))
        }
        return Placed(insert: number, request: request, outcome: turn.wait(bound))
    }

    /// One insert's turn on the main actor: claimed, decided, committed - or let go at
    /// whichever of those the port's answer reached first.
    ///
    /// Let go at the claim, it makes no call into any app, so an insert the port has given up
    /// on costs a hung app nothing more. Let go after deciding, it commits nothing: the port
    /// has answered that the words were not sent.
    @MainActor
    static func place(_ request: InsertRequest, turn: Turn, inFront: () -> InFront) -> Ended.Did {
        guard turn.claim() else { return .letGo }
        let clock = ContinuousClock()
        let started = clock.now
        let seen = inFront()
        let deciding = clock.now - started
        let line = seen.description
        switch seen.cursor {
        case .failure(let refusal):
            let late = turn.answer(.refused(refusal), seen: line)
            return .refused(refusal, deciding: deciding, late: late)
        case .success(let cursor):
            let characters = request.text.count
            guard turn.begin(characters: characters, into: cursor.application, seen: line) else {
                return .letGoAfterDeciding(deciding: deciding, seen: line)
            }
            let committing = clock.measure { cursor.commit(request.text) }
            let late = turn.answer(.inserted(characters: characters, into: cursor.application), seen: line)
            return .committed(characters: characters, into: cursor.application, deciding: deciding, committing: committing, late: late)
        }
    }
}

/// One insert's handshake between the port, which waits a bounded time, and the main actor,
/// which may reach the insert after that time is up.
///
/// [LAW:no-ambient-temporal-coupling] The order the two sides reach it in is a state with one
/// owner, not a race: whichever moves first decides, and the other reads what it decided.
/// The main actor claims the turn before any call into an app and begins it before the
/// commit; the port, its wait over, abandons it. A turn abandoned before it began is never
/// committed into, so the refusal the port answered stays true.
nonisolated final class Turn: Sendable {
    /// While open, the state is the port's answer if its wait ended now, so the port's answer
    /// is read off the state and not mapped from it. [LAW:one-source-of-truth]
    private enum State {
        case open(Placed.Outcome)
        /// The port's wait is over and it has answered.
        case abandoned
    }

    private let state = OSAllocatedUnfairLock(initialState: State.open(.busy(reached: false)))
    private let reached = DispatchSemaphore(value: 0)

    /// The main actor has reached the turn. False once the port has abandoned it, and then
    /// nothing is asked of any app.
    func claim() -> Bool {
        state.withLock { state in
            guard case .open(.busy(reached: false)) = state else { return false }
            state = .open(.busy(reached: true))
            return true
        }
    }

    /// The words are about to be committed. False once the port has abandoned the turn, and
    /// then they are not.
    func begin(characters: Int, into application: String, seen: String) -> Bool {
        state.withLock { state in
            guard case .open(.busy(reached: true)) = state else { return false }
            state = .open(.notYetTaken(characters: characters, into: application, seen: seen))
            return true
        }
    }

    /// The main actor's answer, which is late - true - when the port had already answered.
    func answer(_ answer: InsertionAnswer, seen: String) -> Bool {
        let late = state.withLock { state in
            if case .abandoned = state { return true }
            state = .open(.answered(answer, seen: seen))
            return false
        }
        reached.signal()
        return late
    }

    /// Waits up to `bound` for the main actor's answer, then abandons the turn, answering
    /// what the state held. Waited on once, by the insert that made it.
    func wait(_ bound: Duration) -> Placed.Outcome {
        _ = reached.wait(timeout: .now() + bound / .seconds(1))
        let left = state.withLock { state in
            defer { state = .abandoned }
            return state
        }
        guard case .open(let outcome) = left else { preconditionFailure("a turn is waited on once, by the insert that made it") }
        return outcome
    }
}

/// What the port answered one insert, and what it knew when it did: the line the insert port
/// logs for every request. [LAW:nothing-unseen]
public nonisolated struct Placed: Sendable, CustomStringConvertible {
    /// How the port's wait ended.
    enum Outcome: Equatable, Sendable {
        /// The main actor had not finished deciding in time - had not reached the insert at
        /// all, or was still deciding what is in front - so nothing was committed and nothing
        /// will be.
        case busy(reached: Bool)
        /// The words were being handed to the client when the wait ran out.
        case notYetTaken(characters: Int, into: String, seen: String)
        /// The main actor answered in time.
        case answered(InsertionAnswer, seen: String)
    }

    let insert: Int
    let request: InsertRequest
    let outcome: Outcome

    public var answer: InsertionAnswer {
        switch outcome {
        case .busy: .refused(.inputMethodIsBusy)
        case let .notYetTaken(characters, application, _): .notYetTaken(characters: characters, into: application)
        case let .answered(answer, _): answer
        }
    }

    /// A main actor that did not decide is said as not knowing, never as nothing in front.
    /// [LAW:no-silent-failure]
    public var description: String {
        let context = switch outcome {
        case .busy(reached: false): "without knowing what is in front, since the main thread did not reach the insert in time"
        case .busy(reached: true): "without knowing what is in front, since the main thread was still deciding what is in front when time ran out"
        case let .notYetTaken(_, _, seen): "\(seen), still committing when time ran out"
        case let .answered(_, seen): seen
        }
        return "insert \(insert) of \(request.text.count) characters into \(request.destination): \(answer), \(context)"
    }
}

/// What one insert's turn did on the main actor, how long it waited for it, and how long it
/// held it: the line said once
/// the turn has run, which is the only account of a commit that outlasted the port's answer.
/// [LAW:nothing-unseen]
public nonisolated struct Ended: Sendable, CustomStringConvertible {
    enum Did: Equatable, Sendable {
        /// Reached after the port answered: no call was made into any app.
        case letGo
        /// The port answered while the cursor was being decided, so nothing was committed.
        case letGoAfterDeciding(deciding: Duration, seen: String)
        case refused(Refusal, deciding: Duration, late: Bool)
        case committed(characters: Int, into: String, deciding: Duration, committing: Duration, late: Bool)
    }

    let insert: Int
    /// From the port's ask to the main actor reaching the turn: time spent behind whatever
    /// held the main actor, another insert's commit included.
    let waited: Duration
    let did: Did

    public var description: String {
        let main = "insert \(insert) on the main thread, reached after \(Self.ms(waited))"
        return switch did {
        case .letGo:
            "\(main): let go before any call into an app, since the port had already answered that the input method is busy"
        case let .letGoAfterDeciding(deciding, seen):
            "\(main): let go after \(Self.ms(deciding)) deciding \(seen), since the port had already answered that the input method is busy; nothing was committed"
        case let .refused(refusal, deciding, late):
            "\(main): refused \(refusal.rawValue) after \(Self.ms(deciding)) deciding" + (late ? ", after the port had answered that the input method is busy" : "")
        case let .committed(characters, application, deciding, committing, late):
            "\(main): \(Self.ms(deciding)) deciding, then \(Self.ms(committing)) committing \(characters) characters into \(application)"
                + (late ? ", finishing after the port had answered that they were not yet taken" : "")
        }
    }

    /// Spelled the same in every locale, so a line reads the same on every Mac.
    private static func ms(_ duration: Duration) -> String {
        String(format: "%.1f ms", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }
}
