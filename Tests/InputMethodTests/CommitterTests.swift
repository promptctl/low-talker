import Foundation
@testable import InputMethod
import Insertion
import Testing

/// Committing, and how long an answer waits for it.
///
/// [LAW:behavior-not-structure] Held through `TextCursor`, with a cursor that can be made
/// to hang the way an app whose main thread is asleep does. A bound only the stuck case
/// tests is small; every case that expects a commit to finish gives it a bound no runner
/// stall can spend, because a busy CI machine is not a hung app.
@Suite struct CommitterTests {
    /// A cursor in some app, which records what it was given and, when told to, holds each
    /// commit until the test lets it go.
    private final class Cursor: TextCursor, @unchecked Sendable {
        let application: String
        private let lock = NSLock()
        private var landed: [String] = []
        private var onMain: [Bool] = []
        private let held: DispatchSemaphore?

        init(in application: String = "com.example.editor", holding: Bool = false) {
            self.application = application
            held = holding ? DispatchSemaphore(value: 0) : nil
        }

        func commit(_ text: String) {
            held?.wait()
            lock.withLock {
                landed.append(text)
                onMain.append(Thread.isMainThread)
            }
        }

        // Never asked here: whether a cursor takes words is decided before it reaches the
        // committer, by `FocusedClient`.
        @MainActor var givesDocumentAccess: Bool { true }

        func release() { held?.signal() }
        var committed: [String] { lock.withLock { landed } }
        var committedOnMain: [Bool] { lock.withLock { onMain } }
    }

    private static let unspendable = Duration.seconds(20)

    @Test func wordsCommittedAreAnsweredWithTheirCount() {
        let cursor = Cursor()
        let answer = Committer(bound: Self.unspendable, label: #function).commit("🫠 hello", at: cursor)

        // The count is what a person would count, not what a buffer would: an emoji is one
        // character to whoever dictated it.
        #expect(answer == .inserted(characters: 7, into: cursor.application))
        #expect(cursor.committed == ["🫠 hello"])
    }

    /// Asked from the main thread, committed off it: a commit made on the main thread is the
    /// one a hung app turns into a dead keyboard.
    @MainActor
    @Test func aCommitAskedOnTheMainThreadIsNotMadeThere() {
        let cursor = Cursor()
        _ = Committer(bound: Self.unspendable, label: #function).commit("hello", at: cursor)

        #expect(cursor.committedOnMain == [false])
    }

    @Test func wordsAskedForInOrderLandInOrder() {
        let cursor = Cursor()
        let committer = Committer(bound: Self.unspendable, label: #function)
        for word in ["one", "two", "three"] { _ = committer.commit(word, at: cursor) }

        #expect(cursor.committed == ["one", "two", "three"])
    }

    /// An app that does not take the words in time is answered by name - and the words are
    /// not lost with it, nor committed twice: they land when the app comes back, once
    /// each, in the order they were asked for. Every answer here is given while the cursor
    /// is still held, so no runner stall can turn one into the other.
    @Test func wordsNotTakenInTimeAreSaidByNameAndStillLandOnceInOrder() {
        let hung = Cursor(holding: true)
        let committer = Committer(bound: .milliseconds(50), label: #function)

        #expect(committer.commit("first", at: hung) == .notYetTaken(characters: 5, into: hung.application))
        #expect(committer.commit("second", at: hung) == .notYetTaken(characters: 6, into: hung.application))
        #expect(hung.committed.isEmpty)

        hung.release()
        hung.release()
        let deadline = ContinuousClock.now + Self.unspendable
        while hung.committed.count < 2, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(hung.committed == ["first", "second"])
    }

    /// A hung app costs only its own words: the person switches to another app and
    /// dictates, and those words go straight in rather than waiting behind the hung one's.
    @Test func aHungAppDoesNotHoldAnotherAppsWords() {
        let hung = Cursor(in: "com.example.hung", holding: true)
        let elsewhere = Cursor(in: "com.example.elsewhere")
        let committer = Committer(bound: .milliseconds(50), label: #function)
        _ = committer.commit("stuck", at: hung)

        // Waited for rather than read off the answer, so a runner stall past the small
        // bound cannot fail it: behind a shared queue these words would never land at all
        // while the hung app is held.
        _ = committer.commit("moved on", at: elsewhere)
        let deadline = ContinuousClock.now + Self.unspendable
        while elsewhere.committed.isEmpty, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(elsewhere.committed == ["moved on"])
        #expect(hung.committed.isEmpty)
        hung.release()
    }

    /// What the main actor said about the cursor decides the answer: a cursor is committed
    /// into, a refusal is passed on, and nothing said in time is the input method busy -
    /// with nothing committed anywhere.
    @Test func theAnswerFollowsWhatWasSaidAboutTheCursor() {
        let committer = Committer(bound: Self.unspendable, label: #function)
        let cursor = Cursor()

        #expect(committer.answer("hello", at: .success(cursor)) == .inserted(characters: 5, into: cursor.application))
        #expect(committer.answer("hello", at: .failure(.noTextFieldHasFocus)) == .refused(.noTextFieldHasFocus))
        #expect(committer.answer("hello", at: nil) == .refused(.inputMethodIsBusy))
        #expect(cursor.committed == ["hello"])
    }

    @Test func whatTheQueueSawIsHandedBack() {
        let queue = DispatchQueue(label: #function)
        #expect(Committer(bound: Self.unspendable, label: #function).ask(on: queue) { "the cursor" } == "the cursor")
    }

    /// A queue that does not get round to looking - the main thread, held by a call into a
    /// hung app - is nothing at all, and the look it runs later changes nothing.
    @Test func aQueueThatDoesNotLookInTimeIsNothing() {
        let held = DispatchQueue(label: #function)
        held.suspend()
        defer { held.resume() }

        #expect(Committer(bound: .milliseconds(50), label: #function).ask(on: held) { "too late" } == nil)
    }

    /// The input method's answer naming a hung app has to reach the app before the app
    /// stops listening, which it does after one of its four phases. An insert waits the
    /// bound at most twice: to learn the cursor, then to commit.
    @Test func bothWaitsFitWithinOnePhaseOfTheAppsWait() {
        #expect(Committer.standardBound * 2 < InputMethodInserter.standardTimeout / 4)
    }
}
