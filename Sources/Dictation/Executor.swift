import Foundation
import Insertion
import LowTalkerCore
import os

/// Inserts what was heard: text at the focus asked of the input method, which commits it at
/// the cursor through the text input system - no key posted, no pasteboard touched, and no
/// grant asked of an administrator.
///
/// [LAW:effects-at-boundaries] The edge where a transcript becomes an insert. The inserter is
/// a value it is given - the input method's port in the app, a fake in a test - so the
/// executor itself decides only whether there is anything to insert and where it goes.
@MainActor
public struct Executor {
    private let inserter: any Inserter
    private let log: Logger

    /// Words that do not reach the cursor are a failure and are thrown as one: the input
    /// method's refusal or the channel's, by name. Nothing puts them anywhere else.
    /// [LAW:no-silent-failure]
    public init(insertingThrough inserter: any Inserter, log: Logger = Executor.log) {
        self.inserter = inserter
        self.log = log
    }

    nonisolated public static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "insert")

    /// The event an insert is timed from: key-down for words committed while the press is
    /// still open, key-up for what is inserted once it is over, and a cursor arriving or the
    /// person asking for words held since no cursor took them.
    public struct Since: Sendable {
        public enum Key: String, Sendable {
            case down = "key-down"
            case up = "key-up"
            case cursorArrived = "a cursor arriving"
            case asked = "the person asking"
        }

        public let key: Key
        public let instant: ContinuousClock.Instant

        public static func keyDown(_ instant: ContinuousClock.Instant) -> Since { Since(key: .down, instant: instant) }
        public static func keyUp(_ instant: ContinuousClock.Instant) -> Since { Since(key: .up, instant: instant) }
        public static func cursorArrived(_ instant: ContinuousClock.Instant) -> Since { Since(key: .cursorArrived, instant: instant) }
        public static func asked(_ instant: ContinuousClock.Instant) -> Since { Since(key: .asked, instant: instant) }
    }

    /// One insert, done. The time is from the key event it is timed from to the input
    /// method's answer.
    public struct Performed: CustomStringConvertible, Sendable {
        public let characters: Int
        /// The app whose cursor took the words, as the input method names it - not
        /// necessarily the one in front at key-down: the person can move between the chord
        /// and the dictation's first words being ready, and those go where the cursor is then.
        /// [FRAMING:representation]
        public let into: BundleID
        public let acknowledged: Duration
        public let since: Since.Key

        public var description: String {
            "inserted \(characters) characters at the cursor in \(into.rawValue), \(since.rawValue) to acknowledged \(Int(acknowledged / .milliseconds(1))) ms"
        }
    }

    /// Inserts the transcript's text as one insert, logged as it completes, and answers with
    /// what was done: nil for a blank transcript, which is nothing said and inserts nothing.
    /// Throws the input method's refusal or the channel's failure as it is.
    ///
    /// `last` is the same dictation's latest insert, if it made one. The insert goes only to
    /// the app that one went to, so a dictation's words all land in one app, and the first
    /// goes to the cursor in front. [LAW:one-source-of-truth] Derived here from what landed,
    /// the one record of where that was.
    @discardableResult
    public func insert(_ transcript: Transcript, following last: Performed?, since: Since) async throws(InsertFailure) -> Performed? {
        guard !transcript.isBlank else { return nil }
        let destination = last.map { Destination.app($0.into.rawValue) } ?? .cursorInFront
        // Awaited, so the round trip runs on a thread of its own: this is the main actor, and
        // `Inserter` says in its own contract that the blocking call must not pump it.
        // [LAW:no-ambient-temporal-coupling]
        let inserted = try await inserter.insert(transcript.text, into: destination)
        let done = Performed(characters: inserted.characters, into: BundleID(rawValue: inserted.into), acknowledged: ContinuousClock.now - since.instant, since: since.key)
        log.info("\(done.description, privacy: .public)")
        return done
    }
}
