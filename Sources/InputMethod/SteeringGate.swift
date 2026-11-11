import Foundation
import Insertion
import Synchronization

/// What happens to a steering key the input method has been handed: it reaches the app, or it is
/// swallowed. [LAW:types-are-the-program] `didCommand` answers from this and nothing else.
public nonisolated enum SteeringVerdict: Equatable, Sendable {
    /// Declined, so the text input system delivers the key to the app: after any words committed
    /// while it was held, since `didCommand` has not returned until they were.
    case pass
    /// Taken, so the app never sees it.
    case keep
}

/// A verdict, the reason for it, and how long the key was held for it.
public nonisolated struct SteeringDecision: Equatable, Sendable, CustomStringConvertible {
    public let verdict: SteeringVerdict
    public let because: String
    /// How long the main thread held the key while the app was asked.
    public let waited: Duration
    /// A key typed with nothing owed, which is nearly every Return and Escape: said at debug
    /// level so the log is not a record of when a person pressed them.
    public let routine: Bool

    public init(verdict: SteeringVerdict, because: String, waited: Duration = .zero, routine: Bool = false) {
        (self.verdict, self.because, self.waited, self.routine) = (verdict, because, waited, routine)
    }

    /// This decision, held for `waited`.
    func held(for waited: Duration) -> SteeringDecision {
        SteeringDecision(verdict: verdict, because: because, waited: waited, routine: routine)
    }

    public var description: String {
        "\(verdict == .pass ? "passes" : "is kept")" + (routine ? "" : " after \(waited)") + ": \(because)"
    }
}

/// Holds a Return in `didCommand(by:)` while the app is asked what it means for the dictation, and keeps an
/// Escape while the app's word box is open.
///
/// A Return is held until the words the app owes have landed, then let through.
///
/// A genuine Return reaches the app grant-free in one way only: this process declines the key
/// and the text input system delivers it. Declining after the words are committed puts them
/// first, so the gate waits on the main thread inside `didCommand`, and what it waits for is the
/// app's to say. The app is asked whether it owes anything; when it does not, or does not
/// answer that, the Return passes at once as it would with no LowTalker: **a Return is held
/// only against a debt the app has admitted to**. When it does owe, the gate waits for the app to
/// say the debt landed, and a debt that did not land, or is not settled within `ceiling`, keeps
/// the Return: one sent ahead of its words sends the message without them, and one that did
/// nothing costs a keystroke. [LAW:no-silent-failure] Every verdict is a `SteeringDecision`, which the
/// controller's record carries with its reason.
///
/// An Escape is kept only while the app says its word box is open, and then the app cancels the
/// open press and lets go the held words itself. Anything else, including an app that does not
/// answer, passes the Escape to the app in front as typed.
///
/// While it waits the main thread commits what the app's inserts ask of it (`MainTurns`), since
/// those are the words it is waiting for. The ceiling protects the keyboard, which the held thread
/// is every app's: the longest the app itself waits on any one insert, and not a guess at how fast
/// the engine decodes.
///
/// Its one mutable fact is the app asker, connected once by the process's entry point once the
/// app's signature has been read. The shipped process's gate is `InputMethodProcess.shipped.steering.gate`.
public nonisolated final class SteeringGate: Sendable {

    /// The longest a key is held: what the app itself waits on an insert.
    /// `SteeringGateTests` holds it equal to that.
    public static let standardCeiling = InputMethodInserter.standardTimeout
    /// How long the app has to answer a question. An app that does not answer in this time has
    /// admitted nothing, and the key passes.
    public static let standardQuestion = Duration.milliseconds(100)

    /// Where the words the app owes are committed while a Return waits for them.
    public let turns: MainTurns
    private let ceiling: Duration
    private let question: Duration
    private let asker: Mutex<any SteeringAsking>

    public init(turns: MainTurns = MainTurns(), ceiling: Duration = standardCeiling, question: Duration = standardQuestion,
                asking asker: any SteeringAsking = Unconnected()) {
        self.turns = turns
        self.ceiling = ceiling
        self.question = question
        self.asker = Mutex(asker)
    }

    /// Asks `asker` from now on. The entry point connects it once this installation's app can be
    /// recognised; until then nobody admits anything, and every key passes.
    public func connect(_ asker: any SteeringAsking) {
        self.asker.withLock { $0 = asker }
    }

    /// The gate before it is connected: nobody is listening.
    public struct Unconnected: SteeringAsking {
        public init() {}
        public func owed(at _: TimeInterval, within _: Duration) -> Result<Owing, NotAnswered> {
            .failure(.wire(.nobodyIsListening(port: "no app has been connected yet")))
        }
        public func settled(at _: TimeInterval, within _: Duration) -> Result<Settlement, NotAnswered> {
            .failure(.wire(.nobodyIsListening(port: "no app has been connected yet")))
        }
        public func panel(at _: TimeInterval, within _: Duration) -> Result<PanelState, NotAnswered> {
            .failure(.wire(.nobodyIsListening(port: "no app has been connected yet")))
        }
    }

    /// One key's verdict, set once by its thread and read by its gate. Made for that key alone, so
    /// what it holds is never another's.
    private final class Slot: Sendable {
        let decided = Mutex<SteeringDecision?>(nil)
    }

    /// What the gate does with a Return typed at `timestamp`, on the main thread, where `didCommand` is
    /// called. Returns once the Return passes or is kept, and in between runs the commits the app's
    /// inserts ask for.
    @MainActor
    public func verdict(at timestamp: TimeInterval) -> SteeringDecision {
        let (question, ceiling) = (self.question, self.ceiling)
        return answered(unanswered: SteeringDecision(verdict: .keep, because: "the app had not answered after \(ceiling)")) { asker in
            Self.decide(asker, at: timestamp, question: question, ceiling: ceiling)
        }
    }

    /// What the gate does with an Escape typed, on the main thread, where `didCommand` is called:
    /// kept while the app's word box is open, and passed otherwise.
    @MainActor
    public func escapeVerdict(at timestamp: TimeInterval) -> SteeringDecision {
        let question = self.question
        return answered(unanswered: SteeringDecision(verdict: .pass, because: "the app had not answered whether its word box is open")) { asker in
            Self.decideEscape(asker, at: timestamp, question: question)
        }
    }

    /// Runs `decide` against the app on a thread made for this one key, with its own reply port and
    /// its own slot for the verdict. A late answer to an earlier key lands in that key's abandoned
    /// slot and is read by nobody, and a key typed while an earlier one's thread is still blocked is
    /// not queued behind it. [LAW:no-ambient-temporal-coupling]
    @MainActor
    private func answered(unanswered: SteeringDecision, _ decide: @escaping @Sendable (any SteeringAsking) -> SteeringDecision) -> SteeringDecision {
        let asking = asker.withLock { $0 }
        let slot = Slot()
        let turns = self.turns
        let ceiling = self.ceiling
        let started = ContinuousClock.now
        Thread {
            let decided = decide(asking)
            slot.decided.withLock { $0 = decided }
            turns.poke()
        }.start()
        turns.hold(until: started + ceiling, while: { slot.decided.withLock { $0 } == nil })
        return (slot.decided.withLock { $0 } ?? unanswered).held(for: ContinuousClock.now - started)
    }

    /// Whether an app that is not there, which is how an app that is not running looks from here
    /// and is as ordinary as a key typed with it off.
    private static func isAbsence(_ why: NotAnswered) -> Bool {
        if case .wire(.nobodyIsListening) = why { true } else { false }
    }

    private static func decide(_ asker: any SteeringAsking, at timestamp: TimeInterval, question: Duration, ceiling: Duration) -> SteeringDecision {
        switch asker.owed(at: timestamp, within: question) {
        case .success(.nothing):
            return SteeringDecision(verdict: .pass, because: "the app owes nothing", routine: true)
        case .failure(let why):
            return SteeringDecision(verdict: .pass, because: "the app admitted no debt: \(why)", routine: isAbsence(why))
        case .success(.words):
            switch asker.settled(at: timestamp, within: ceiling) {
            case .success(.landed): return SteeringDecision(verdict: .pass, because: "the words landed")
            case .success(.notLanded): return SteeringDecision(verdict: .keep, because: "the words did not all reach a cursor")
            case .failure(let why): return SteeringDecision(verdict: .keep, because: "the debt was admitted and not settled: \(why)")
            }
        }
    }

    private static func decideEscape(_ asker: any SteeringAsking, at timestamp: TimeInterval, question: Duration) -> SteeringDecision {
        switch asker.panel(at: timestamp, within: question) {
        case .success(.shown):
            return SteeringDecision(verdict: .keep, because: "the word box is open, so the app cancels the press with it")
        case .success(.shut):
            return SteeringDecision(verdict: .pass, because: "the word box is shut", routine: true)
        case .failure(let why):
            return SteeringDecision(verdict: .pass, because: "the app did not say the word box is open: \(why)", routine: isAbsence(why))
        }
    }
}
