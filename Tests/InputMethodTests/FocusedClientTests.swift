import Foundation
@testable import InputMethod
import InputMethodFakes
import Insertion
import Testing

/// Which cursor the words go to, and the refusal when there is none. The commit itself is
/// `Committer`'s, and held there.
///
/// [LAW:behavior-not-structure] Each cursor is the real `Client`, made as `activateServer` makes
/// it, over the fake field (`FakeTextInputClient`) answering as a measured client does. The text
/// input system's own client is `IMKTextInput` and cannot be stood in for - three dozen members,
/// all of them macOS's - so `Client` asks it only through `TextInputClient`, the seven calls it
/// makes. That the seam is narrow enough to test is the same fact as its being narrow enough to
/// reason about.
///
/// Each case builds its own `FocusedClient` rather than moving focus on the shared one:
/// that one belongs to the process macOS launched, and cases sharing it would be moving
/// each other's focus.
@MainActor
@Suite struct FocusedClientTests {
    /// The app in front, for the cases where it is simply whoever holds the cursor.
    private static let inFront = "com.example.editor"
    /// Studious's one display, where every line below was measured.
    private static let display = CGRect(x: 0, y: 0, width: 1600, height: 900)
    /// The Finder desktop's type-select buffer, measured on studious: document access given,
    /// from a line centered below the display's bottom edge.
    nonisolated private static let typeSelectLine = CGRect(x: 5, y: -13, width: 1, height: 14)

    /// A client that names no app is no cursor, even with an app in front: its app could never be
    /// compared against the one in front, so it could never be refused for being somewhere else.
    @Test(arguments: [nil, ""])
    func aClientNamingNoAppIsNoCursor(_ name: String?) {
        #expect(Client(FakeTextInputClient(in: name), inFront: "com.apple.TextEdit") == nil)
    }

    /// The decision, on a desk with only the display.
    private func cursor(_ client: FocusedClient, for destination: Destination = .cursorInFront, whileInFrontIs frontmost: String? = inFront,
                        selected: Bool = true,
                        screens: [CGRect] = [display]) -> Result<Client, Refusal> {
        client.inFront(for: destination, whileInFrontIs: frontmost, selected: selected, screens: screens).cursor
    }

    @Test func theCursorInFrontIsTheOneChosen() throws {
        let client = FocusedClient { _ in }
        let cursor = try FakeTextInputClient().cursor()
        client.took(cursor)

        #expect(try self.cursor(client).get() === cursor)
    }

    /// With another input source selected the cursor last held is one the text input system
    /// has deactivated, and the refusal names the Input menu over any refusal about the
    /// cursor, since no field the person clicks into can take the words until it is fixed.
    @Test func anotherSourceSelectedIsRefusedByName() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient().cursor())
        #expect(throws: Refusal.inputSourceIsNotSelected) { try cursor(client, selected: false).get() }
        #expect(throws: Refusal.inputSourceIsNotSelected) { try cursor(FocusedClient { _ in }, selected: false).get() }
    }

    /// Nothing in front is an answer, not a failure, and it is said by name.
    @Test func nothingInFrontIsRefusedByName() {
        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(FocusedClient { _ in }).get() }
    }

    /// A window with no field focused still hands the input method a client, and what is
    /// committed into it goes nowhere while the commit answers that it landed: Calculator,
    /// Installer, a page's body text. The client says so itself by giving no document
    /// access, and the words are refused rather than lost. [LAW:no-silent-failure]
    @Test func aCursorGivingNoDocumentAccessIsRefusedAsNoTextField() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: "com.apple.calculator", .noTextField).cursor())

        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(client, whileInFrontIs: "com.apple.calculator").get() }
    }

    /// The Finder's desktop and file lists give document access to a type-select buffer in
    /// no window, which takes the words where nobody can see them. Its caret is on no
    /// screen, and that is what refuses it. [LAW:no-silent-failure]
    @Test func aCaretOnNoScreenIsRefusedAsNoTextField() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: "com.apple.finder", caretLine: Self.typeSelectLine).cursor())

        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(client, whileInFrontIs: "com.apple.finder").get() }
    }

    /// Any screen will do: a field on a second display, wherever it is arranged, is a field.
    @Test func aCaretOnAnyScreenIsTaken() throws {
        let client = FocusedClient { _ in }
        let cursor = try FakeTextInputClient(caretLine: CGRect(x: 2000, y: -300, width: 1, height: 16)).cursor()
        client.took(cursor)
        let below = CGRect(x: 1600, y: -1080, width: 1920, height: 1080)

        #expect(throws: Refusal.noTextFieldHasFocus) { try self.cursor(client).get() }
        #expect(try self.cursor(client, screens: [Self.display, below]).get() === cursor)
    }

    /// A field reporting no caret line is a field: nothing it said places the caret off the
    /// screens, and real fields answer that way between activating and their first answer.
    @Test func aFieldReportingNoCaretIsTaken() throws {
        let client = FocusedClient { _ in }
        let cursor = try FakeTextInputClient(caretLine: nil).cursor()
        client.took(cursor)

        #expect(try self.cursor(client).get() === cursor)
    }

    /// The field is asked about when the words are, not when the cursor arrived: a page
    /// whose body was clicked after its field had focus answers no from then on.
    @Test func theFieldIsTheAnswerAtTheMomentOfTheInsert() throws {
        let client = FocusedClient { _ in }
        let field = FakeTextInputClient(in: "com.google.Chrome", .webKitTextArea)
        let cursor = try field.cursor()
        client.took(cursor)
        #expect(try self.cursor(client, whileInFrontIs: "com.google.Chrome").get() === cursor)

        field.profile = .noTextField
        #expect(throws: Refusal.noTextFieldHasFocus) { try self.cursor(client, whileInFrontIs: "com.google.Chrome").get() }
    }

    /// The field is a call into the cursor's app, which may be hung, so it is asked only of
    /// the cursor the words would go to, and once: never of one left in an app the person
    /// has moved away from or after the dictation moved apps.
    @Test func theFieldIsAskedOnceAndOnlyOfTheCursorTheWordsWouldGoTo() throws {
        let client = FocusedClient { _ in }
        let field = FakeTextInputClient(in: "com.apple.TextEdit")
        try client.took(field.cursor())

        _ = client.inFront(for: .cursorInFront, whileInFrontIs: "com.apple.finder", selected: true, screens: [Self.display])
        _ = client.inFront(for: .app("com.apple.finder"), whileInFrontIs: "com.apple.TextEdit", selected: true, screens: [Self.display])
        #expect(field.documentAccessAsked == 0)

        let seen = client.inFront(for: .cursorInFront, whileInFrontIs: "com.apple.TextEdit", selected: true, screens: [Self.display])
        _ = seen.description
        #expect(field.documentAccessAsked == 1)
        #expect(field.text.isEmpty, "deciding where the words would go put some there")
    }

    /// The insert's log line tells the three ways into `noTextFieldHasFocus` apart - no
    /// cursor, a client giving no document access, a caret on no screen - and says where
    /// the caret of a taken insert was.
    @Test func whatTheInsertSawNamesTheCursorAndWhatItsClientAnswered() throws {
        func seen(_ field: FakeTextInputClient?, inFront frontmost: String? = "com.apple.finder",
                  selected: Bool = true, screens: [CGRect] = [Self.display]) throws -> InFront {
            let client = FocusedClient { _ in }
            try field.map { try client.took($0.cursor()) }
            return client.inFront(for: .cursorInFront, whileInFrontIs: frontmost, selected: selected,
                                  screens: screens)
        }

        let none = try seen(nil)
        #expect(throws: Refusal.noTextFieldHasFocus) { try none.cursor.get() }
        #expect(none.description == "with com.apple.finder in front and no cursor")

        func finder(_ profile: ClientProfile = .appKit, caretLine: CGRect? = FakeTextInputClient.textEditLine) -> FakeTextInputClient {
            FakeTextInputClient(in: "com.apple.finder", profile, caretLine: caretLine)
        }

        let noAccess = try seen(finder(.noTextField))
        #expect(throws: Refusal.noTextFieldHasFocus) { try noAccess.cursor.get() }
        #expect(noAccess.description == "with com.apple.finder in front and the cursor in com.apple.finder, which gives no document access")

        let offScreen = try seen(finder(caretLine: Self.typeSelectLine))
        #expect(throws: Refusal.noTextFieldHasFocus) { try offScreen.cursor.get() }
        #expect(offScreen.description == "with com.apple.finder in front and the cursor in com.apple.finder, its caret line at (5.0, -13.0, 1.0, 14.0), on none of the screens [(0.0, 0.0, 1600.0, 900.0)]")

        let noScreens = try seen(finder(caretLine: CGRect(x: 1305, y: 435, width: 1, height: 16)), screens: [])
        #expect(throws: Refusal.noTextFieldHasFocus) { try noScreens.cursor.get() }
        #expect(noScreens.description == "with com.apple.finder in front and the cursor in com.apple.finder, its caret line at (1305.0, 435.0, 1.0, 16.0), on none of the screens []")

        let taken = try seen(finder(caretLine: CGRect(x: 1305, y: 435, width: 1, height: 16)))
        #expect((try? taken.cursor.get()) != nil)
        #expect(taken.description == "with com.apple.finder in front and the cursor in com.apple.finder, its caret line at (1305.0, 435.0, 1.0, 16.0)")

        let noCaret = try seen(finder(caretLine: nil))
        #expect((try? noCaret.cursor.get()) != nil)
        #expect(noCaret.description == "with com.apple.finder in front and the cursor in com.apple.finder, which reports no caret")

        let elsewhere = try seen(finder(), selected: false)
        #expect(throws: Refusal.inputSourceIsNotSelected) { try elsewhere.cursor.get() }
        #expect(elsewhere.description == "with com.apple.finder in front and the cursor in com.apple.finder, another input source selected")
    }

    /// A cursor does not outlive the app it belongs to. Without this the person could
    /// dictate into TextEdit, quit it, launch it again, and have the words answered
    /// `inserted` into a client whose process no longer exists - the app names would match
    /// and nothing else would object. [LAW:no-silent-failure]
    @Test func aCursorDiesWithItsApp() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: "com.apple.TextEdit").cursor())
        client.applicationQuit("com.apple.TextEdit")

        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(client, whileInFrontIs: "com.apple.TextEdit").get() }
    }

    /// Some other app quitting is not this cursor's business.
    @Test func anotherAppQuittingLeavesTheCursorAlone() throws {
        let client = FocusedClient { _ in }
        let cursor = try FakeTextInputClient().cursor()
        client.took(cursor)
        client.applicationQuit("com.apple.Safari")

        #expect(try self.cursor(client).get() === cursor)
    }

    @Test func aCursorThatLeavesTakesTheFocusWithIt() throws {
        let client = FocusedClient { _ in }
        let cursor = try FakeTextInputClient().cursor()
        client.took(cursor)
        client.left(cursor)

        #expect(throws: Refusal.noTextFieldHasFocus) { try self.cursor(client).get() }
    }

    /// Committing into a window the person has left is the one outcome worse than
    /// refusing, and it is reachable: focus can move to an app that never becomes a client
    /// of this input method, and then nothing deactivates the cursor left standing. Held
    /// here and not by a reading - on this Mac every app tried, the Finder's desktop
    /// included, presented a client of its own. [LAW:no-silent-failure]
    @Test func aCursorLeftBehindInAnotherAppIsRefusedRatherThanInsertedInto() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: "com.apple.TextEdit").cursor())

        #expect(throws: Refusal.cursorIsInAnotherApp) { try cursor(client, whileInFrontIs: "com.apple.finder").get() }
    }

    /// A dictation's later words go only to the app its first went to. The person who moved
    /// to the Finder mid-press is refused there - the case measured on studious, where the
    /// Finder presents a client and took the rest of a TextEdit dictation.
    @Test func wordsBoundToAnotherAppAreRefusedAtTheCursorInFront() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: "com.apple.finder").cursor())

        #expect(throws: Refusal.dictationIsInAnotherApp) { try cursor(client, for: .app("com.apple.TextEdit"), whileInFrontIs: "com.apple.finder").get() }
    }

    /// The person who moved is told they moved, whatever the app they moved to holds: no
    /// cursor of its own, or a cursor still standing in the app they left.
    /// None of those is where the words were going, so none is the thing to fix.
    @Test func aMoveIsTheReasonOverWhatTheAppMovedToHolds() throws {
        let bound = Destination.app("com.apple.TextEdit")
        #expect(throws: Refusal.dictationIsInAnotherApp) { try cursor(FocusedClient { _ in }, for: bound, whileInFrontIs: "com.apple.finder").get() }
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: "com.apple.TextEdit").cursor())
        #expect(throws: Refusal.dictationIsInAnotherApp) { try cursor(client, for: bound, whileInFrontIs: "com.apple.finder").get() }
    }

    @Test func wordsBoundToTheAppInFrontGoToItsCursor() throws {
        let client = FocusedClient { _ in }
        let cursor = try FakeTextInputClient(in: "com.apple.TextEdit").cursor()
        client.took(cursor)

        #expect(try self.cursor(client, for: .app("com.apple.TextEdit"), whileInFrontIs: "com.apple.TextEdit").get() === cursor)
    }

    /// The one that matters: focus can move by activating the new client before
    /// deactivating the old, and a `left` that cleared on anyone's word would drop the
    /// client that just arrived. The insert would then be refused with a live cursor
    /// sitting right there, and nothing would say why. [LAW:no-silent-failure]
    @Test func aCursorLeavingAfterAnotherArrivedDoesNotTakeTheNewOnesFocus() throws {
        let client = FocusedClient { _ in }
        let old = try FakeTextInputClient().cursor()
        let new = try FakeTextInputClient().cursor()
        client.took(old)
        client.took(new)
        client.left(old)

        #expect(try self.cursor(client).get() === new)
    }

    // MARK: several cursors of the app in front (low-reliability-z2z.n8z)

    private static let textEdit = "com.apple.TextEdit"

    /// A controller, as `IMKServer` builds one per client: only its identity is used.
    private final class Controller: InputController {}

    /// A `FocusedClient` that records each app it tells of a cursor arrival.
    @MainActor private final class Told {
        var arrivals: [String] = []
        lazy var client = FocusedClient { [unowned self] in self.arrivals.append($0) }
    }

    /// TextEdit launched with restored windows: the key window's client and the one behind it
    /// both activated in the same millisecond, and neither was deactivated. Nothing says which is
    /// the key window, so neither takes the words, and neither is asked about its field: the
    /// refusal is decided before any call into the app. The case seen on studious, where the
    /// words went to the window behind and were answered inserted.
    @Test func twoLiveCursorsOfTheAppInFrontAreRefusedAndNeitherIsWrittenTo() throws {
        let client = FocusedClient { _ in }
        let key = FakeTextInputClient(in: Self.textEdit)
        let behind = FakeTextInputClient(in: Self.textEdit)
        try client.took(key.cursor())
        try client.took(behind.cursor())

        #expect(throws: Refusal.cursorIsNotSettled) { try cursor(client, whileInFrontIs: Self.textEdit).get() }
        #expect(key.documentAccessAsked == 0 && behind.documentAccessAsked == 0)
        #expect(key.text.isEmpty && behind.text.isEmpty)
    }

    /// A key reaches only the controller of the client it is typed into, so that client has the
    /// keyboard, and it is where the words go from then on.
    @Test func aKeyTypedIntoOneOfThemMakesItTheCursor() throws {
        let client = FocusedClient { _ in }
        let key = try FakeTextInputClient(in: Self.textEdit).cursor()
        let behind = try FakeTextInputClient(in: Self.textEdit).cursor()
        client.took(key)
        client.took(behind)
        client.typedInto(key)

        #expect(try cursor(client, whileInFrontIs: Self.textEdit).get() === key)
    }

    /// The refusal's way out offers the words again: the key that settles it tells the app a
    /// cursor arrived, once. A key typed where there was only ever one cursor tells nothing, so
    /// typing is not an arrival per keystroke.
    @Test func theKeyThatSettlesItIsToldAsAnArrivalAndNoOtherKeyIs() throws {
        let told = Told()
        let key = try FakeTextInputClient(in: Self.textEdit).cursor()
        let behind = try FakeTextInputClient(in: Self.textEdit).cursor()
        told.client.took(key)
        told.client.took(behind)
        #expect(told.arrivals == [Self.textEdit], "only the first activation found a cursor alone")

        told.client.typedInto(key)
        told.client.typedInto(key)
        told.client.typedInto(key)
        #expect(told.arrivals == [Self.textEdit, Self.textEdit])
    }

    /// A switch between two windows that activates the new client before it deactivates the old:
    /// for that moment both are live and words are refused, and the deactivation that leaves the
    /// new one alone is the arrival that offers them again. Seen in Safari in this Mac's log,
    /// twelve times in a day, each for a millisecond or less.
    @Test func aSwitchThatActivatesFirstIsToldOnceTheOldOneLeaves() throws {
        let told = Told()
        let old = try FakeTextInputClient(in: Self.textEdit).cursor()
        let new = try FakeTextInputClient(in: Self.textEdit).cursor()
        told.client.took(old)
        told.client.took(new)
        #expect(throws: Refusal.cursorIsNotSettled) { try cursor(told.client, whileInFrontIs: Self.textEdit).get() }

        told.client.left(old)
        #expect(told.arrivals == [Self.textEdit, Self.textEdit])
        #expect(try cursor(told.client, whileInFrontIs: Self.textEdit).get() === new)
    }

    /// A controller activated again replaces its own cursor rather than standing beside it, and
    /// that is an arrival as every activation alone is.
    @Test func aControllerActivatedAgainIsOneCursor() throws {
        let told = Told()
        let controller = Controller()
        let first = try FakeTextInputClient(in: Self.textEdit).cursor()
        let again = try FakeTextInputClient(in: Self.textEdit).cursor()
        told.client.took(first, by: controller)
        told.client.took(again, by: controller)

        #expect(try cursor(told.client, whileInFrontIs: Self.textEdit).get() === again)
        #expect(told.arrivals == [Self.textEdit, Self.textEdit])
    }

    /// A deactivation removes only its own controller's cursor, in either order, while both are
    /// live: an orphan's late deactivation never takes the cursor of the controller that replaced
    /// it, and the controller that replaced it never takes the orphan's.
    @Test(arguments: [true, false])
    func aDeactivationRemovesOnlyItsOwnControllersCursor(orphanLeavesFirst: Bool) throws {
        let orphan = Controller()
        let replacement = Controller()
        let client = FocusedClient { _ in }
        let old = try FakeTextInputClient(in: Self.textEdit).cursor()
        let current = try FakeTextInputClient(in: Self.textEdit).cursor()
        client.took(old, by: orphan)
        client.took(current, by: replacement)

        client.left(orphanLeavesFirst ? orphan : replacement)
        #expect(try cursor(client, whileInFrontIs: Self.textEdit).get() === (orphanLeavesFirst ? current : old))
    }

    /// A key settles which window has the keyboard, and the window it ruled out is not lost for
    /// it: once the person moves there and types, that key is the same proof, whether or not
    /// macOS activates its client again first. Until then the words are refused as not settled,
    /// which names that key, rather than as no field.
    @Test func aKeyIntoACursorAnotherKeyRuledOutMakesItTheCursor() throws {
        let told = Told()
        let (key, window) = (Controller(), Controller())
        let there = try FakeTextInputClient(in: Self.textEdit).cursor()
        try told.client.took(FakeTextInputClient(in: Self.textEdit).cursor(), by: key)
        told.client.took(there, by: window)
        told.client.typedInto(key)
        told.client.left(key)
        #expect(throws: Refusal.cursorIsNotSettled) { try cursor(told.client, whileInFrontIs: Self.textEdit).get() }

        told.client.typedInto(window)
        #expect(try cursor(told.client, whileInFrontIs: Self.textEdit).get() === there)
        #expect(told.arrivals == [Self.textEdit, Self.textEdit, Self.textEdit])
    }

    /// An overlay of another app activates a client and leaves, and macOS need not activate the
    /// window behind it again: the cursor there is ruled out but held, and a key typed into it
    /// makes it the cursor and offers the words again.
    @Test func aKeyIntoACursorAnotherAppRuledOutMakesItTheCursor() throws {
        let told = Told()
        let (editor, overlay) = (Controller(), Controller())
        let there = try FakeTextInputClient(in: Self.textEdit).cursor()
        told.client.took(there, by: editor)
        try told.client.took(FakeTextInputClient(in: "com.apple.Spotlight").cursor(), by: overlay)
        told.client.left(overlay)
        #expect(told.client.holding(editor) == "holding \(there), not live")
        #expect(throws: Refusal.cursorIsNotSettled) { try cursor(told.client, whileInFrontIs: Self.textEdit).get() }
        let seen = told.client.inFront(for: .cursorInFront, whileInFrontIs: Self.textEdit, selected: true, screens: [Self.display])
        #expect(seen.description == "with com.apple.TextEdit in front and no cursor, 1 of its own ruled out")

        told.client.typedInto(editor)
        #expect(told.client.holding(editor) == "holding \(there)")
        #expect(try cursor(told.client, whileInFrontIs: Self.textEdit).get() === there)
        #expect(told.arrivals == [Self.textEdit, "com.apple.Spotlight", Self.textEdit])
    }

    /// Focus is in one app at a time, so a client activating in another app ends every cursor
    /// left here, whether or not they are ever deactivated: back in TextEdit, its cursors are not
    /// standing to be inserted into or argued over.
    @Test func anActivationInAnotherAppEndsEveryCursorHere() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: Self.textEdit).cursor())
        try client.took(FakeTextInputClient(in: Self.textEdit).cursor())
        let safari = try FakeTextInputClient(in: "com.apple.Safari").cursor()
        client.took(safari)

        #expect(try cursor(client, whileInFrontIs: "com.apple.Safari").get() === safari)
        #expect(throws: Refusal.cursorIsInAnotherApp) { try cursor(client, whileInFrontIs: Self.textEdit).get() }
    }

    /// A key that reaches a controller holding no cursor - one deactivated, or that never had a
    /// client it could use - says nothing about the cursors that are, and changes nothing.
    @Test func aKeyIntoAControllerHoldingNoCursorChangesNothing() throws {
        let told = Told()
        try told.client.took(FakeTextInputClient(in: Self.textEdit).cursor())
        try told.client.took(FakeTextInputClient(in: Self.textEdit).cursor())
        told.client.typedInto(Controller())

        #expect(throws: Refusal.cursorIsNotSettled) { try cursor(told.client, whileInFrontIs: Self.textEdit).get() }
        #expect(told.arrivals == [Self.textEdit])
    }

    /// The app quitting takes every one of its cursors with it.
    @Test func anAppQuittingTakesAllItsCursors() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: Self.textEdit).cursor())
        try client.took(FakeTextInputClient(in: Self.textEdit).cursor())
        client.applicationQuit(Self.textEdit)

        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(client, whileInFrontIs: Self.textEdit).get() }
    }

    /// The insert's log line says how many cursors were live, which is the fact that decided it.
    @Test func whatTheInsertSawNamesHowManyCursorsWereLive() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: Self.textEdit).cursor())
        try client.took(FakeTextInputClient(in: Self.textEdit).cursor())

        let seen = client.inFront(for: .cursorInFront, whileInFrontIs: Self.textEdit, selected: true, screens: [Self.display])
        #expect(seen.description == "with com.apple.TextEdit in front and 2 cursors in com.apple.TextEdit")
    }

    // MARK: an Open or Save panel's field, whose client is the service that draws the panel

    private static let panelService = "com.apple.appkit.xpc.openAndSavePanelService"
    private static let installer = "com.apple.installer"

    /// The cursor `activateServer` makes of the panel's client while `host` is in front.
    private func panelCursor(hosted host: String = installer, caretLine: CGRect = FakeTextInputClient.textEditLine) throws -> Client {
        try FakeTextInputClient(in: Self.panelService, caretLine: caretLine).cursor(whileInFrontIs: host)
    }

    /// The case measured on studious: Installer in front, its Open panel's name field focused.
    @Test func wordsGoToThePanelsFieldWhileItsHostIsInFront() throws {
        let client = FocusedClient { _ in }
        let cursor = try panelCursor()
        client.took(cursor)

        #expect(try self.cursor(client, whileInFrontIs: Self.installer).get() === cursor)
    }

    /// The panel's file list gives document access from a type-select buffer with its caret on
    /// no screen, which is what keeps words out of it now that the panel is in front.
    @Test func thePanelsFileListIsStillNotAField() throws {
        let client = FocusedClient { _ in }
        try client.took(panelCursor(caretLine: Self.typeSelectLine))

        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(client, whileInFrontIs: Self.installer).get() }
    }

    /// A person who left the app the panel belongs to is refused, as for any cursor left behind.
    @Test func aPanelLeftBehindIsRefusedOnceAnotherAppIsInFront() throws {
        let client = FocusedClient { _ in }
        try client.took(panelCursor())

        #expect(throws: Refusal.cursorIsInAnotherApp) { try cursor(client, whileInFrontIs: "com.apple.Safari").get() }
    }

    /// The words after a dictation's first are bound to the app the first went to, and what
    /// the cursor reports as that is the host - the service is never in front.
    @Test func laterWordsOfADictationIntoThePanelStillGoToIt() throws {
        let client = FocusedClient { _ in }
        let cursor = try panelCursor()
        client.took(cursor)

        #expect(try self.cursor(client, for: .app(cursor.application), whileInFrontIs: Self.installer).get() === cursor)
    }

    /// A Save panel over a document whose client was never deactivated is a second cursor of the
    /// host, and refused as one; typing the file's name into the panel's field settles it there.
    @Test func aPanelBesideItsHostsLiveDocumentIsSettledByTypingInIt() throws {
        let client = FocusedClient { _ in }
        try client.took(FakeTextInputClient(in: Self.installer).cursor())
        let panel = try panelCursor()
        client.took(panel)
        #expect(throws: Refusal.cursorIsNotSettled) { try cursor(client, whileInFrontIs: Self.installer).get() }

        client.typedInto(panel)
        #expect(try cursor(client, whileInFrontIs: Self.installer).get() === panel)
    }

    /// The host quitting takes its panel's cursor with it, so the same app relaunched into
    /// front is not committed into through a proxy for a process that is gone.
    @Test func theHostQuittingClearsThePanelsCursor() throws {
        let client = FocusedClient { _ in }
        try client.took(panelCursor())
        client.applicationQuit(Self.installer)

        #expect(throws: Refusal.noTextFieldHasFocus) { try cursor(client, whileInFrontIs: Self.installer).get() }
    }
}
