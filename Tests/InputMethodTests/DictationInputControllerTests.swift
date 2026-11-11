import AppKit
import InputMethod
import Insertion
import Testing

/// The controller answers the text input system's commands. Return and Escape are the two it decides: a
/// Return is held for words the app owes, and an Escape is kept only while the app's word box is open.
/// Every other command, and all text, is declined, so it reaches the app as it would have.
///
/// [LAW:behavior-not-structure] Asked by naming the command and reading the answer, not by checking which
/// methods the class overrides. A Return is asked with the modifiers the case holds, never the ones this Mac's
/// keyboard holds while the suite runs.
///
/// On the main actor because the controller is an `IMKInputController`, which is built and answered there.
///
/// Serialized because the gate is one shared fact and each case connects the app it asks.
@Suite(.serialized) @MainActor struct DictationInputControllerTests {
    /// The commands the text input system binds Return and Escape to.
    static let insertNewline = NSSelectorFromString("insertNewline:")
    static let cancelOperation = NSSelectorFromString("cancelOperation:")

    /// The app as the gate asks it, answering each question with what the case gave it.
    private struct App: SteeringAsking {
        var owing: Result<Owing, NotAnswered> = .success(.nothing)
        var settling: Result<Settlement, NotAnswered> = .success(.landed)
        var panelling: Result<PanelState, NotAnswered> = .success(.shut)

        func owed(at _: TimeInterval, within _: Duration) -> Result<Owing, NotAnswered> { owing }
        func settled(at _: TimeInterval, within _: Duration) -> Result<Settlement, NotAnswered> { settling }
        func panel(at _: TimeInterval, within _: Duration) -> Result<PanelState, NotAnswered> { panelling }
    }

    /// Connects `app` to the gate for the length of one case, then disconnects it.
    private func withApp(_ app: App = App(), _ body: (DictationInputController) throws -> Void) throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        SteeringGate.shared.connect(app)
        defer { SteeringGate.shared.connect(SteeringGate.Unconnected()) }
        try body(controller)
    }

    /// Key-downs are always asked for, so Escape reaches the controller whatever the Return setting says.
    @Test func keyDownsAreAlwaysAskedFor() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.recognizedEvents(nil) == 0x400)
    }

    /// Escape passes while the word box is closed.
    @Test func escapePassesWhileTheBoxIsClosed() throws {
        try withApp(App(panelling: .success(.shut))) { controller in
            #expect(controller.didCommand(by: Self.cancelOperation, client: nil) == false)
        }
    }

    /// Escape is kept for the app while the word box is open.
    @Test func escapeIsKeptWhileTheBoxIsOpen() throws {
        try withApp(App(panelling: .success(.shown))) { controller in
            #expect(controller.didCommand(by: Self.cancelOperation, client: nil) == true)
        }
    }

    /// Escape passes when no app answers whether its box is open, as it does with no app running.
    @Test func escapePassesWhenNoAppAnswers() throws {
        try withApp(App(panelling: .failure(.nobodyIsListening(port: "port")))) { controller in
            #expect(controller.didCommand(by: Self.cancelOperation, client: nil) == false)
        }
    }

    /// A Return passes when the app owes nothing, as it did before the hold.
    @Test func aReturnPassesWhenNothingIsOwed() throws {
        try withApp(App(owing: .success(.nothing))) { controller in
            #expect(controller.didCommand(by: Self.insertNewline, holding: []) == false)
        }
    }

    /// A Return passes once the words the app owes have landed.
    @Test func aReturnPassesWhenTheOwedWordsLand() throws {
        try withApp(App(owing: .success(.words), settling: .success(.landed))) { controller in
            #expect(controller.didCommand(by: Self.insertNewline, holding: []) == false)
        }
    }

    /// A Return is kept when the words the app owes did not all reach a cursor.
    @Test func aReturnIsKeptWhenTheOwedWordsDoNotLand() throws {
        try withApp(App(owing: .success(.words), settling: .success(.notLanded))) { controller in
            #expect(controller.didCommand(by: Self.insertNewline, holding: []) == true)
        }
    }

    /// A Return typed with a modifier is another key, and passes even when the owed words did not land.
    @Test func aReturnWithAModifierPassesWhenTheOwedWordsDoNotLand() throws {
        try withApp(App(owing: .success(.words), settling: .success(.notLanded))) { controller in
            #expect(controller.didCommand(by: Self.insertNewline, holding: .option) == false)
        }
    }

    /// A command the input method does not decide is declined, so it reaches the app.
    @Test(arguments: ["moveLeft:", "deleteBackward:", "insertTab:"])
    func anOtherCommandIsDeclined(name: String) throws {
        try withApp(App(owing: .success(.words), panelling: .success(.shown))) { controller in
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
