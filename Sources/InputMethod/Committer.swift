import Foundation
import Insertion
import os

/// Where commits run, and how long an answer waits for one.
///
/// Measured on low-input-method-s71.c7d against an app whose main thread was asleep:
/// - Made on the main thread, a commit waits for the app to answer, up to 3 s, and then
///   returns as if nothing were wrong. That wait holds every key this source passes
///   through, in every app, once per insert.
/// - Made off it, a commit hands the words to the app's queue and returns at once. The app
///   takes them when it recovers, in the order they were sent.
///
/// So commits run here, off the main thread, on one serial queue per app.
/// [LAW:no-ambient-temporal-coupling] Serial, so words asked for in order land in order;
/// per app, so a commit that does not return costs only that app's later inserts and never
/// another app's. The caller still waits only `bound`, because the call is macOS's and not
/// this process's to trust: a commit that does not return in time is answered by name
/// rather than waited on.
///
/// **What `inserted` claims, exactly: the words were handed to the client of the app in
/// front, which had answered that it gives document access with its caret on a screen.**
/// Not that the app has taken
/// them, and not that a person saw them. Off the main thread even a read of the client
/// returns at once from a hung app, so nothing here can ask whether the app took the words.
/// The text input system offers no delivery report either, and measured on 2026-09-22 there
/// is nothing to derive one from: iTerm2, where the words land in plain sight, answers
/// `length()` of 0 before and after, so a check for "did the document grow" would refuse
/// the terminal. The client's field is asked about before the commit instead
/// (`FocusedClient`): its own answer to whether a field has focus, and where its caret
/// is, which is how the Finder's invisible type-select buffer is told from a field.
/// [LAW:no-silent-failure]
///
/// Past `bound` the answer is `notYetTaken`, and the commit is left to finish: the words
/// are already on their way to the app, and they land when it recovers. Nothing is
/// committed twice for it.
public final class Committer: Sendable {
    /// An insert waits this long at most twice - once to learn the cursor, once to commit -
    /// and the two together sit beneath one phase of the app's own wait, so this answer
    /// arrives before the app stops listening. `CommitterTests` holds the two apart.
    public static let standardBound = Duration.milliseconds(500)

    private let bound: Duration
    private let label: String
    /// [LAW:no-shared-mutable-globals] Owned here and touched only by `queue(for:)`. One
    /// entry per app words have gone to, which is as many as the person dictates into.
    private let queues = OSAllocatedUnfairLock(initialState: [String: DispatchQueue]())

    public init(bound: Duration = standardBound, label: String) {
        self.bound = bound
        self.label = label
    }

    /// Runs `look` on `queue` and hands back what it saw, or nothing once `bound` has passed.
    ///
    /// How an insert asks the main actor which cursor is in front without waiting on it
    /// past the bound: the main thread is where IMK makes its own calls into apps, and where
    /// the cursor is asked about its field, and a hung app holds it there
    /// for up to 3 s on each. Nothing at all is an answer the
    /// caller refuses by name, and `look` runs late or never; what it saw is thrown away.
    /// [LAW:parse-dont-validate] The typed absence is the whole failure arm.
    public func ask<Seen: Sendable>(on queue: DispatchQueue, _ look: @escaping @Sendable () -> Seen) -> Seen? {
        let seen = OSAllocatedUnfairLock<Seen?>(initialState: nil)
        let answered = DispatchSemaphore(value: 0)
        queue.async {
            let saw = look()
            seen.withLock { $0 = saw }
            answered.signal()
        }
        guard answered.wait(timeout: .now() + bound / .seconds(1)) == .success else { return nil }
        return seen.withLock { $0 }
    }

    /// The answer to an insert, from what the main actor said about the cursor: nothing in
    /// time is `inputMethodIsBusy`, a refusal is that refusal, and a cursor is committed
    /// into. [LAW:dataflow-not-control-flow] The three outcomes of the ask, handled once.
    public func answer(_ text: String, at cursor: Result<any TextCursor, Refusal>?) -> InsertionAnswer {
        switch cursor {
        case .success(let cursor)?: commit(text, at: cursor)
        case .failure(let refusal)?: .refused(refusal)
        case nil: .refused(.inputMethodIsBusy)
        }
    }

    /// Commits `text` at `cursor`, answering once the app takes it or `bound` has passed.
    /// Blocks the caller for at most `bound`, so it belongs on a queue that is not the one
    /// keys are handled on.
    public func commit(_ text: String, at cursor: any TextCursor) -> InsertionAnswer {
        let taken = DispatchSemaphore(value: 0)
        queue(for: cursor.application).async {
            cursor.commit(text)
            taken.signal()
        }
        let answered = taken.wait(timeout: .now() + bound / .seconds(1)) == .success
        return answered
            ? .inserted(characters: text.count, into: cursor.application)
            : .notYetTaken(characters: text.count, into: cursor.application)
    }

    private func queue(for application: String) -> DispatchQueue {
        queues.withLock { queues in
            if let queue = queues[application] { return queue }
            let queue = DispatchQueue(label: "\(label).\(application)")
            queues[application] = queue
            return queue
        }
    }
}
