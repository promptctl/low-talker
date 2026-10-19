@testable import InputMethod
import Insertion
import Testing

/// Which cursor the words go to, and the refusal when there is none. The commit itself is
/// `Committer`'s, and held there.
///
/// [LAW:behavior-not-structure] Asked through `TextCursor`, which is the whole of what this
/// process needs of the thing in front of it. The text input system's own client is
/// `IMKTextInput` and cannot be stood in for - three dozen members, all of them macOS's -
/// so a type that demanded it could only ever be exercised by a person at a keyboard. That
/// the seam is narrow enough to test is the same fact as its being narrow enough to reason
/// about.
///
/// Each case builds its own `FocusedClient` rather than moving focus on the shared one:
/// that one belongs to the process macOS launched, and cases sharing it would be moving
/// each other's focus.
@MainActor
@Suite struct FocusedClientTests {
    /// A place words could land, in some app. Never committed into: this suite asks only
    /// which cursor is chosen.
    private final class Cursor: TextCursor {
        let application: String
        /// What the client answers when asked, which a window with no field focused
        /// answers no to. Isolated to the main actor, where it is asked, so a case can
        /// change it between inserts and the cursor stays Sendable.
        @MainActor final class Answer {
            var givesDocumentAccess: Bool
            var asked = 0
            nonisolated init(_ gives: Bool) { givesDocumentAccess = gives }
        }
        let answer: Answer

        init(in application: String = "com.example.editor", givingDocumentAccess: Bool = true) {
            self.application = application
            answer = Answer(givingDocumentAccess)
        }

        @MainActor var givesDocumentAccess: Bool {
            answer.asked += 1
            return answer.givesDocumentAccess
        }

        func commit(_ text: String) { Issue.record("the decision committed \(text.debugDescription)") }
    }

    /// The app in front, for the cases where it is simply whoever holds the cursor.
    private static let inFront = "com.example.editor"

    @Test func theCursorInFrontIsTheOneChosen() throws {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)

        #expect(try client.cursor(for: .cursorInFront, whileInFrontIs: Self.inFront, secureInputIsOn: false).get() === cursor)
    }

    /// A cursor held from before secure input came on is not committed into: macOS has
    /// stopped routing to input methods, and the refusal names what to fix instead of
    /// asking the person to click into a text field they are already in.
    @Test func secureInputIsRefusedByName() {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)

        #expect(throws: Refusal.secureInputIsOn) { try client.cursor(for: .cursorInFront, whileInFrontIs: Self.inFront, secureInputIsOn: true).get() }
    }

    /// Secure input is the reason given even where another refusal about the cursor also
    /// holds: the fix is in the app holding it, and naming the other would send the person
    /// to click into a text field that cannot help.
    @Test func secureInputIsTheReasonOverEveryRefusalAboutTheCursor() {
        #expect(throws: Refusal.secureInputIsOn) { try FocusedClient().cursor(for: .cursorInFront, whileInFrontIs: Self.inFront, secureInputIsOn: true).get() }
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)
        #expect(throws: Refusal.secureInputIsOn) { try client.cursor(for: .cursorInFront, whileInFrontIs: "com.example.elsewhere", secureInputIsOn: true).get() }
    }

    /// Nothing in front is an answer, not a failure, and it is said by name.
    @Test func nothingInFrontIsRefusedByName() {
        #expect(throws: Refusal.noTextFieldHasFocus) { try FocusedClient().cursor(for: .cursorInFront, whileInFrontIs: Self.inFront, secureInputIsOn: false).get() }
    }

    /// A window with no field focused still hands the input method a client, and what is
    /// committed into it goes nowhere while the commit answers that it landed: Calculator,
    /// Installer, a page's body text. The client says so itself by giving no document
    /// access, and the words are refused rather than lost. [LAW:no-silent-failure]
    @Test func aCursorGivingNoDocumentAccessIsRefusedAsNoTextField() {
        let client = FocusedClient()
        client.took(Cursor(in: "com.apple.calculator", givingDocumentAccess: false))

        #expect(throws: Refusal.noTextFieldHasFocus) {
            try client.cursor(for: .cursorInFront, whileInFrontIs: "com.apple.calculator", secureInputIsOn: false).get()
        }
    }

    /// Document access is asked when the words are, not when the cursor arrived: a page
    /// whose body was clicked after its field had focus answers no from then on.
    @Test func documentAccessIsTheAnswerAtTheMomentOfTheInsert() throws {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.google.Chrome")
        client.took(cursor)
        #expect(try client.cursor(for: .cursorInFront, whileInFrontIs: "com.google.Chrome", secureInputIsOn: false).get() === cursor)

        cursor.answer.givesDocumentAccess = false
        #expect(throws: Refusal.noTextFieldHasFocus) {
            try client.cursor(for: .cursorInFront, whileInFrontIs: "com.google.Chrome", secureInputIsOn: false).get()
        }
    }

    /// Document access is a call into the cursor's app, which may be hung, so it is asked
    /// only of the cursor the words would go to: never of one left in an app the person
    /// has moved away from, under secure input, or after the dictation moved apps.
    @Test func documentAccessIsAskedOnlyOfTheCursorTheWordsWouldGoTo() {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.apple.TextEdit")
        client.took(cursor)

        _ = client.cursor(for: .cursorInFront, whileInFrontIs: "com.apple.finder", secureInputIsOn: false)
        _ = client.cursor(for: .cursorInFront, whileInFrontIs: "com.apple.TextEdit", secureInputIsOn: true)
        _ = client.cursor(for: .app("com.apple.finder"), whileInFrontIs: "com.apple.TextEdit", secureInputIsOn: false)
        #expect(cursor.answer.asked == 0)

        _ = client.cursor(for: .cursorInFront, whileInFrontIs: "com.apple.TextEdit", secureInputIsOn: false)
        #expect(cursor.answer.asked == 1)
    }

    /// The insert's log line tells the two ways into `noTextFieldHasFocus` apart: no cursor
    /// at all, or a cursor in the app in front whose client gave no document access.
    @Test func whatTheInsertSawNamesTheCursorHeld() {
        let client = FocusedClient()
        let none = client.inFront(for: .cursorInFront, whileInFrontIs: "com.apple.calculator", secureInputHeldBy: nil)
        #expect(throws: Refusal.noTextFieldHasFocus) { try none.cursor.get() }
        #expect(none.description == "with com.apple.calculator in front and no cursor")

        client.took(Cursor(in: "com.apple.calculator", givingDocumentAccess: false))
        let held = client.inFront(for: .cursorInFront, whileInFrontIs: "com.apple.calculator", secureInputHeldBy: nil)
        #expect(throws: Refusal.noTextFieldHasFocus) { try held.cursor.get() }
        #expect(held.description == "with com.apple.calculator in front and the cursor in com.apple.calculator")

        let securing = client.inFront(for: .cursorInFront, whileInFrontIs: nil, secureInputHeldBy: "iTerm2")
        #expect(throws: Refusal.secureInputIsOn) { try securing.cursor.get() }
        #expect(securing.description == "with nothing in front and the cursor in com.apple.calculator, secure input held by iTerm2")
    }

    /// A cursor does not outlive the app it belongs to. Without this the person could
    /// dictate into TextEdit, quit it, launch it again, and have the words answered
    /// `inserted` into a client whose process no longer exists - the app names would match
    /// and nothing else would object. [LAW:no-silent-failure]
    @Test func aCursorDiesWithItsApp() {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.apple.TextEdit")
        client.took(cursor)
        client.applicationQuit("com.apple.TextEdit")

        #expect(throws: Refusal.noTextFieldHasFocus) { try client.cursor(for: .cursorInFront, whileInFrontIs: "com.apple.TextEdit", secureInputIsOn: false).get() }
    }

    /// Some other app quitting is not this cursor's business.
    @Test func anotherAppQuittingLeavesTheCursorAlone() throws {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)
        client.applicationQuit("com.apple.Safari")

        #expect(try client.cursor(for: .cursorInFront, whileInFrontIs: Self.inFront, secureInputIsOn: false).get() === cursor)
    }

    @Test func aCursorThatLeavesTakesTheFocusWithIt() {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)
        client.left(cursor)

        #expect(throws: Refusal.noTextFieldHasFocus) { try client.cursor(for: .cursorInFront, whileInFrontIs: Self.inFront, secureInputIsOn: false).get() }
    }

    /// Committing into a window the person has left is the one outcome worse than
    /// refusing, and it is reachable: focus can move to an app that never becomes a client
    /// of this input method, and then nothing deactivates the cursor left standing. Held
    /// here and not by a reading - on this Mac every app tried, the Finder's desktop
    /// included, presented a client of its own. [LAW:no-silent-failure]
    @Test func aCursorLeftBehindInAnotherAppIsRefusedRatherThanInsertedInto() {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.apple.TextEdit")
        client.took(cursor)

        #expect(throws: Refusal.cursorIsInAnotherApp) { try client.cursor(for: .cursorInFront, whileInFrontIs: "com.apple.finder", secureInputIsOn: false).get() }
    }

    /// A dictation's later words go only to the app its first went to. The person who moved
    /// to the Finder mid-press is refused there - the case measured on studious, where the
    /// Finder presents a client and took the rest of a TextEdit dictation.
    @Test func wordsBoundToAnotherAppAreRefusedAtTheCursorInFront() {
        let client = FocusedClient()
        client.took(Cursor(in: "com.apple.finder"))

        #expect(throws: Refusal.dictationIsInAnotherApp) {
            try client.cursor(for: .app("com.apple.TextEdit"), whileInFrontIs: "com.apple.finder", secureInputIsOn: false).get()
        }
    }

    /// The person who moved is told they moved, whatever the app they moved to holds: no
    /// cursor of its own, a cursor still standing in the app they left, or secure input.
    /// None of those is where the words were going, so none is the thing to fix.
    @Test func aMoveIsTheReasonOverWhatTheAppMovedToHolds() {
        let bound = Destination.app("com.apple.TextEdit")
        #expect(throws: Refusal.dictationIsInAnotherApp) { try FocusedClient().cursor(for: bound, whileInFrontIs: "com.apple.finder", secureInputIsOn: false).get() }
        let client = FocusedClient()
        client.took(Cursor(in: "com.apple.TextEdit"))
        #expect(throws: Refusal.dictationIsInAnotherApp) { try client.cursor(for: bound, whileInFrontIs: "com.apple.finder", secureInputIsOn: false).get() }
        #expect(throws: Refusal.dictationIsInAnotherApp) { try client.cursor(for: bound, whileInFrontIs: "com.apple.finder", secureInputIsOn: true).get() }
    }

    @Test func wordsBoundToTheAppInFrontGoToItsCursor() throws {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.apple.TextEdit")
        client.took(cursor)

        #expect(try client.cursor(for: .app("com.apple.TextEdit"), whileInFrontIs: "com.apple.TextEdit", secureInputIsOn: false).get() === cursor)
    }

    /// The one that matters: focus can move by activating the new client before
    /// deactivating the old, and a `left` that cleared on anyone's word would drop the
    /// client that just arrived. The insert would then be refused with a live cursor
    /// sitting right there, and nothing would say why. [LAW:no-silent-failure]
    @Test func aCursorLeavingAfterAnotherArrivedDoesNotTakeTheNewOnesFocus() throws {
        let client = FocusedClient()
        let old = Cursor()
        let new = Cursor()
        client.took(old)
        client.took(new)
        client.left(old)

        #expect(try client.cursor(for: .cursorInFront, whileInFrontIs: Self.inFront, secureInputIsOn: false).get() === new)
    }
}
