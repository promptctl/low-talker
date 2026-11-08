import AppKit
import InputMethod
import Insertion
import Testing

/// The controller answers the text input system's commands. Return and Escape are the two it decides: a
/// Return is held for words the app owes, and an Escape is kept only while the app's word box is open.
/// Every other command, and all text, is declined, so it reaches the app as it would have.
///
/// [LAW:behavior-not-structure] Asked by naming the command and reading the answer, not by checking which
/// methods the class overrides.
///
/// On the main actor because the controller is an `IMKInputController`, which is built and answered there.
///
/// Serialized because `AppState` is one shared fact and each case sets it.
@Suite(.serialized) @MainActor struct DictationInputControllerTests {
    /// The commands the text input system binds Return and Escape to.
    static let insertNewline = NSSelectorFromString("insertNewline:")
    static let cancelOperation = NSSelectorFromString("cancelOperation:")

    /// Sets what the app last said for the length of one case, then puts back nothing held.
    private func withState(holdsReturn: Bool, panelShown: Bool, _ body: (DictationInputController) throws -> Void) throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        AppState.shared.set(InputMethodState(holdsReturn: holdsReturn, panelShown: panelShown))
        defer { AppState.shared.set(.none) }
        try body(controller)
    }

    /// Key-downs are always asked for, so Escape reaches the controller whatever the Return setting says.
    @Test func keyDownsAreAlwaysAskedFor() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.recognizedEvents(nil) == 0x400)
    }

    /// A fresh input method has been told nothing: no Return held and no box open.
    @Test func aFreshInputMethodHoldsNothingAndShowsNothing() {
        let state = AppState()
        #expect(state.holdsReturn == false)
        #expect(state.panelShown == false)
    }

    /// Escape passes while the word box is closed.
    @Test func escapePassesWhileTheBoxIsClosed() throws {
        try withState(holdsReturn: false, panelShown: false) { controller in
            #expect(controller.didCommand(by: Self.cancelOperation, client: nil) == false)
        }
    }

    /// Escape is kept for the app while the word box is open.
    @Test func escapeIsKeptWhileTheBoxIsOpen() throws {
        try withState(holdsReturn: false, panelShown: true) { controller in
            #expect(controller.didCommand(by: Self.cancelOperation, client: nil) == true)
        }
    }

    /// A Return passes when nothing is held, as it did before the hold.
    @Test func aReturnPassesWhenNothingIsHeld() throws {
        try withState(holdsReturn: false, panelShown: false) { controller in
            #expect(controller.didCommand(by: Self.insertNewline, client: nil) == false)
        }
    }

    /// A command the input method does not decide is declined, so it reaches the app.
    @Test(arguments: ["moveLeft:", "deleteBackward:", "insertTab:"])
    func anOtherCommandIsDeclined(name: String) throws {
        try withState(holdsReturn: true, panelShown: true) { controller in
            #expect(controller.didCommand(by: NSSelectorFromString(name), client: nil) == false, "\(name) was claimed")
        }
    }

    /// Text is never handed to this input method as keys, so it is declined.
    @Test func textIsDeclined() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.inputText("e", client: nil) == false)
    }

    /// A call carrying no selector, which IMK may make, is declined rather than trapping and taking the
    /// input method down.
    @Test func aCallWithNoSelectorIsDeclined() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.didCommand(by: nil, client: nil) == false)
    }

    /// A cursor given focus is told to the app, which offers it words no cursor took. Other notices
    /// the shared stream holds, such as a reported Escape, are passed over.
    @Test(.timeLimit(.minutes(1))) func aCursorArrivingIsTold() async {
        Notices.shared.cursorArrived(in: "com.apple.TextEdit")
        #expect(await Notices.shared.notices.first { @Sendable notice in notice == .cursorArrived } == .cursorArrived)
    }

    /// The bundle's `InputMethodServerControllerClass` is a string macOS resolves through
    /// the Objective-C runtime, so the name in project.yml and the name this class actually
    /// has are one fact in two places. A rename that moved only the Swift side would leave
    /// macOS looking up a class that no longer exists - and it looks it up at launch, long
    /// after any build succeeded. [LAW:one-source-of-truth]
    @Test func theControllerAnswersToTheNameThePlistNames() {
        #expect(NSStringFromClass(DictationInputController.self) == "DictationInputController")
    }
}
