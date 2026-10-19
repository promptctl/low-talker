import Foundation
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
        /// What the client answers when asked about its field. Isolated to the main actor,
        /// where it is asked, so a case can change it between inserts and the cursor stays
        /// Sendable.
        @MainActor final class Answer {
            var field: FieldAnswer
            var asked = 0
            nonisolated init(_ field: FieldAnswer) { self.field = field }
        }
        let answer: Answer

        init(in application: String = "com.example.editor", answering field: FieldAnswer = FocusedClientTests.textEdit) {
            self.application = application
            answer = Answer(field)
        }

        @MainActor var field: FieldAnswer {
            answer.asked += 1
            return answer.field
        }

        func commit(_ text: String) { Issue.record("the decision committed \(text.debugDescription)") }
    }

    /// The app in front, for the cases where it is simply whoever holds the cursor.
    private static let inFront = "com.example.editor"
    /// Studious's one display, where every line below was measured.
    private static let display = CGRect(x: 0, y: 0, width: 1600, height: 900)
    /// TextEdit's answer, measured on studious: a field with its caret on the display.
    nonisolated private static let textEdit = FieldAnswer.documentAccess(caretLine: CGRect(x: 402, y: 565, width: 1, height: 13))
    /// The Finder desktop's type-select buffer, measured on studious: document access given,
    /// from a line centered below the display's bottom edge.
    private static let typeSelect = FieldAnswer.documentAccess(caretLine: CGRect(x: 5, y: -13, width: 1, height: 14))

    /// The decision, on a desk with only the display and no secure input unless said.
    private func cursor(_ client: FocusedClient, for destination: Destination = .cursorInFront, whileInFrontIs frontmost: String? = inFront,
                        secureInputHeldBy holder: String? = nil, screens: [CGRect] = [display]) -> Result<any TextCursor, Refusal> {
        client.inFront(for: destination, whileInFrontIs: frontmost, secureInputHeldBy: holder, screens: screens).cursor
    }

    @Test func theCursorInFrontIsTheOneChosen() throws {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)

        #expect(try self.cursor(client).get() === cursor)
    }

    /// A cursor held from before secure input came on is not committed into: macOS has
    /// stopped routing to input methods, and the refusal names what to fix instead of
    /// asking the person to click into a text field they are already in.
    @Test func secureInputIsRefusedByName() {
        let client = FocusedClient()
        client.took(Cursor())

        #expect(throws: Refusal.secureInputIsOn) { try cursor(client, secureInputHeldBy: "iTerm2").get() }
    }

    /// Secure input is the reason given even where another refusal about the cursor also
    /// holds: the fix is in the app holding it, and naming the other would send the person
    /// to click into a text field that cannot help.
    @Test func secureInputIsTheReasonOverEveryRefusalAboutTheCursor() {
        #expect(throws: Refusal.secureInputIsOn) { try cursor(FocusedClient(), secureInputHeldBy: "iTerm2").get() }
        let client = FocusedClient()
        client.took(Cursor())
        #expect(throws: Refusal.secureInputIsOn) { try cursor(client, whileInFrontIs: "com.example.elsewhere", secureInputHeldBy: "iTerm2").get() }
        let typeSelecting = FocusedClient()
        typeSelecting.took(Cursor(answering: Self.typeSelect))
        #expect(throws: Refusal.secureInputIsOn) { try cursor(typeSelecting, secureInputHeldBy: "iTerm2").get() }
    }

    /// Nothing in front is an answer, not a failure, and it is said by name.
    @Test func nothingInFrontIsRefusedByName() {
        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(FocusedClient()).get() }
    }

    /// A window with no field focused still hands the input method a client, and what is
    /// committed into it goes nowhere while the commit answers that it landed: Calculator,
    /// Installer, a page's body text. The client says so itself by giving no document
    /// access, and the words are refused rather than lost. [LAW:no-silent-failure]
    @Test func aCursorGivingNoDocumentAccessIsRefusedAsNoTextField() {
        let client = FocusedClient()
        client.took(Cursor(in: "com.apple.calculator", answering: .noDocumentAccess))

        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(client, whileInFrontIs: "com.apple.calculator").get() }
    }

    /// The Finder's desktop and file lists give document access to a type-select buffer in
    /// no window, which takes the words where nobody can see them. Its caret is on no
    /// screen, and that is what refuses it. [LAW:no-silent-failure]
    @Test func aCaretOnNoScreenIsRefusedAsNoTextField() {
        let client = FocusedClient()
        client.took(Cursor(in: "com.apple.finder", answering: Self.typeSelect))

        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(client, whileInFrontIs: "com.apple.finder").get() }
    }

    /// Any screen will do: a field on a second display, wherever it is arranged, is a field.
    @Test func aCaretOnAnyScreenIsTaken() throws {
        let client = FocusedClient()
        let cursor = Cursor(answering: .documentAccess(caretLine: CGRect(x: 2000, y: -300, width: 1, height: 16)))
        client.took(cursor)
        let below = CGRect(x: 1600, y: -1080, width: 1920, height: 1080)

        #expect(throws: Refusal.noTextFieldHasFocus) { try self.cursor(client).get() }
        #expect(try self.cursor(client, screens: [Self.display, below]).get() === cursor)
    }

    /// A field reporting no caret line is a field: nothing it said places the caret off the
    /// screens, and real fields answer that way between activating and their first answer.
    @Test func aFieldReportingNoCaretIsTaken() throws {
        let client = FocusedClient()
        let cursor = Cursor(answering: .documentAccess(caretLine: nil))
        client.took(cursor)

        #expect(try self.cursor(client).get() === cursor)
    }

    /// The field is asked about when the words are, not when the cursor arrived: a page
    /// whose body was clicked after its field had focus answers no from then on.
    @Test func theFieldIsTheAnswerAtTheMomentOfTheInsert() throws {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.google.Chrome")
        client.took(cursor)
        #expect(try self.cursor(client, whileInFrontIs: "com.google.Chrome").get() === cursor)

        cursor.answer.field = .noDocumentAccess
        #expect(throws: Refusal.noTextFieldHasFocus) { try self.cursor(client, whileInFrontIs: "com.google.Chrome").get() }
    }

    /// The field is a call into the cursor's app, which may be hung, so it is asked only of
    /// the cursor the words would go to, and once: never of one left in an app the person
    /// has moved away from, under secure input, or after the dictation moved apps.
    @Test func theFieldIsAskedOnceAndOnlyOfTheCursorTheWordsWouldGoTo() {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.apple.TextEdit")
        client.took(cursor)

        _ = client.inFront(for: .cursorInFront, whileInFrontIs: "com.apple.finder", secureInputHeldBy: nil, screens: [Self.display])
        _ = client.inFront(for: .cursorInFront, whileInFrontIs: "com.apple.TextEdit", secureInputHeldBy: "iTerm2", screens: [Self.display])
        _ = client.inFront(for: .app("com.apple.finder"), whileInFrontIs: "com.apple.TextEdit", secureInputHeldBy: nil, screens: [Self.display])
        #expect(cursor.answer.asked == 0)

        let seen = client.inFront(for: .cursorInFront, whileInFrontIs: "com.apple.TextEdit", secureInputHeldBy: nil, screens: [Self.display])
        _ = seen.description
        #expect(cursor.answer.asked == 1)
    }

    /// The insert's log line tells the three ways into `noTextFieldHasFocus` apart - no
    /// cursor, a client giving no document access, a caret on no screen - and says where
    /// the caret of a taken insert was.
    @Test func whatTheInsertSawNamesTheCursorAndWhatItsClientAnswered() {
        func seen(_ field: FieldAnswer?, inFront frontmost: String? = "com.apple.finder", secureInputHeldBy holder: String? = nil) -> InFront {
            let client = FocusedClient()
            field.map { client.took(Cursor(in: "com.apple.finder", answering: $0)) }
            return client.inFront(for: .cursorInFront, whileInFrontIs: frontmost, secureInputHeldBy: holder, screens: [Self.display])
        }

        let none = seen(nil)
        #expect(throws: Refusal.noTextFieldHasFocus) { try none.cursor.get() }
        #expect(none.description == "with com.apple.finder in front and no cursor")

        let noAccess = seen(.noDocumentAccess)
        #expect(throws: Refusal.noTextFieldHasFocus) { try noAccess.cursor.get() }
        #expect(noAccess.description == "with com.apple.finder in front and the cursor in com.apple.finder, which gives no document access")

        let offScreen = seen(Self.typeSelect)
        #expect(throws: Refusal.noTextFieldHasFocus) { try offScreen.cursor.get() }
        #expect(offScreen.description == "with com.apple.finder in front and the cursor in com.apple.finder, its caret line at (5.0, -13.0, 1.0, 14.0), on no screen")

        let taken = seen(.documentAccess(caretLine: CGRect(x: 1305, y: 435, width: 1, height: 16)))
        #expect((try? taken.cursor.get()) != nil)
        #expect(taken.description == "with com.apple.finder in front and the cursor in com.apple.finder, its caret line at (1305.0, 435.0, 1.0, 16.0)")

        let noCaret = seen(.documentAccess(caretLine: nil))
        #expect((try? noCaret.cursor.get()) != nil)
        #expect(noCaret.description == "with com.apple.finder in front and the cursor in com.apple.finder, which reports no caret")

        let securing = seen(.noDocumentAccess, inFront: nil, secureInputHeldBy: "iTerm2")
        #expect(throws: Refusal.secureInputIsOn) { try securing.cursor.get() }
        #expect(securing.description == "with nothing in front and the cursor in com.apple.finder, secure input held by iTerm2")
    }

    /// A cursor does not outlive the app it belongs to. Without this the person could
    /// dictate into TextEdit, quit it, launch it again, and have the words answered
    /// `inserted` into a client whose process no longer exists - the app names would match
    /// and nothing else would object. [LAW:no-silent-failure]
    @Test func aCursorDiesWithItsApp() {
        let client = FocusedClient()
        client.took(Cursor(in: "com.apple.TextEdit"))
        client.applicationQuit("com.apple.TextEdit")

        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(client, whileInFrontIs: "com.apple.TextEdit").get() }
    }

    /// Some other app quitting is not this cursor's business.
    @Test func anotherAppQuittingLeavesTheCursorAlone() throws {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)
        client.applicationQuit("com.apple.Safari")

        #expect(try self.cursor(client).get() === cursor)
    }

    @Test func aCursorThatLeavesTakesTheFocusWithIt() {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)
        client.left(cursor)

        #expect(throws: Refusal.noTextFieldHasFocus) { try self.cursor(client).get() }
    }

    /// Committing into a window the person has left is the one outcome worse than
    /// refusing, and it is reachable: focus can move to an app that never becomes a client
    /// of this input method, and then nothing deactivates the cursor left standing. Held
    /// here and not by a reading - on this Mac every app tried, the Finder's desktop
    /// included, presented a client of its own. [LAW:no-silent-failure]
    @Test func aCursorLeftBehindInAnotherAppIsRefusedRatherThanInsertedInto() {
        let client = FocusedClient()
        client.took(Cursor(in: "com.apple.TextEdit"))

        #expect(throws: Refusal.cursorIsInAnotherApp) { try cursor(client, whileInFrontIs: "com.apple.finder").get() }
    }

    /// A dictation's later words go only to the app its first went to. The person who moved
    /// to the Finder mid-press is refused there - the case measured on studious, where the
    /// Finder presents a client and took the rest of a TextEdit dictation.
    @Test func wordsBoundToAnotherAppAreRefusedAtTheCursorInFront() {
        let client = FocusedClient()
        client.took(Cursor(in: "com.apple.finder"))

        #expect(throws: Refusal.dictationIsInAnotherApp) { try cursor(client, for: .app("com.apple.TextEdit"), whileInFrontIs: "com.apple.finder").get() }
    }

    /// The person who moved is told they moved, whatever the app they moved to holds: no
    /// cursor of its own, a cursor still standing in the app they left, or secure input.
    /// None of those is where the words were going, so none is the thing to fix.
    @Test func aMoveIsTheReasonOverWhatTheAppMovedToHolds() {
        let bound = Destination.app("com.apple.TextEdit")
        #expect(throws: Refusal.dictationIsInAnotherApp) { try cursor(FocusedClient(), for: bound, whileInFrontIs: "com.apple.finder").get() }
        let client = FocusedClient()
        client.took(Cursor(in: "com.apple.TextEdit"))
        #expect(throws: Refusal.dictationIsInAnotherApp) { try cursor(client, for: bound, whileInFrontIs: "com.apple.finder").get() }
        #expect(throws: Refusal.dictationIsInAnotherApp) { try cursor(client, for: bound, whileInFrontIs: "com.apple.finder", secureInputHeldBy: "iTerm2").get() }
    }

    @Test func wordsBoundToTheAppInFrontGoToItsCursor() throws {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.apple.TextEdit")
        client.took(cursor)

        #expect(try self.cursor(client, for: .app("com.apple.TextEdit"), whileInFrontIs: "com.apple.TextEdit").get() === cursor)
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

        #expect(try self.cursor(client).get() === new)
    }
}
