import AppKit
@testable import InputMethod
import InputMethodFakes
import Insertion
import InsertionFakes
import Testing

/// The controller answers the text input system's commands. Return and Escape are the two it decides: a
/// Return is held for words the app owes, and an Escape is kept only while the app's word box is open.
/// Every other command, and all text, is declined, so it reaches the app as it would have.
///
/// [LAW:behavior-not-structure] Asked by naming the command and reading the answer, not by checking which
/// methods the class overrides. Every command is asked with the modifiers the case holds, never the ones this
/// Mac's keyboard holds while the suite runs.
///
/// On the main actor because the controller is an `IMKInputController`, which is built and answered there.
/// Each case builds its controller in a process of its own, whose gate asks what the case gave it.
@Suite @MainActor struct DictationInputControllerTests {
    /// The commands the text input system binds Return and Escape to.
    static let insertNewline = NSSelectorFromString("insertNewline:")
    static let cancelOperation = NSSelectorFromString("cancelOperation:")

    /// A controller of a process whose gate asks `app`, and the process.
    private func controller(asking app: FakeApp = FakeApp()) -> (DictationInputController, AssembledProcess) {
        let assembled = AssembledProcess(asking: app)
        return (assembled.controller(), assembled)
    }

    /// `selector` answered by a controller asking `app`, typed with `modifiers` held: whether it was
    /// kept, how many times the process beeped, and every key the app was told of.
    private func answer(_ selector: Selector, holding modifiers: NSEvent.ModifierFlags = [],
                        asking app: FakeApp) -> (kept: Bool, beeps: Int, told: [SteeringKey]) {
        let (controller, assembled) = controller(asking: app)
        let kept = controller.didCommand(by: selector, holding: modifiers, typedAt: 1)
        let told = assembled.recorded.withLock { $0 }.compactMap { record in
            if case let .keyTyped(key) = record { key } else { nil }
        }
        return (kept, assembled.beeps, told)
    }

    /// Key-downs are always asked for, so Escape reaches the controller whatever the Return setting says.
    @Test func keyDownsAreAlwaysAskedFor() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.recognizedEvents(nil) == 0x400)
    }

    /// Escape passes while the word box is closed, and the app is told nothing.
    @Test func escapePassesWhileTheBoxIsClosed() {
        let answered = answer(Self.cancelOperation, asking: FakeApp(panelling: { .success(.shut) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0 && answered.told == [])
    }

    /// Escape is kept while the word box is open, and the app is told, so it cancels the press.
    @Test func escapeIsKeptWhileTheBoxIsOpen() {
        let answered = answer(Self.cancelOperation, asking: FakeApp(panelling: { .success(.shown) }))
        #expect(answered.kept == true)
        #expect(answered.beeps == 0 && answered.told == [.escape])
    }

    /// Escape passes when no app answers whether its box is open, as it does with no app running.
    @Test func escapePassesWhenNoAppAnswers() {
        let answered = answer(Self.cancelOperation, asking: FakeApp(panelling: { .failure(.wire(.nobodyIsListening(port: "port"))) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0 && answered.told == [])
    }

    /// A Return passes, silently, when the app owes nothing and when the words it owes have landed.
    @Test(arguments: [Owing.nothing, .words])
    func aReturnPassesWhenNothingIsLeftOwing(owing: Owing) {
        let answered = answer(Self.insertNewline, asking: FakeApp(owing: { .success(owing) }, settling: { .success(.landed) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0 && answered.told == [])
    }

    /// A bare Return is kept when the words the app owes did not all reach a cursor, and is heard.
    @Test func aReturnIsKeptWhenTheOwedWordsDoNotLand() {
        let answered = answer(Self.insertNewline, asking: FakeApp(owing: { .success(.words) }, settling: { .success(.notLanded) }))
        #expect(answered.kept == true)
        #expect(answered.beeps == 1 && answered.told == [])
    }

    /// Each modifier that makes a Return another key, named here rather than read from
    /// `SteeringKey`, so one dropped from its set fails a case instead of removing it.
    nonisolated static let modifiersThatMakeAnotherKey: [UInt] =
        [NSEvent.ModifierFlags.shift, .control, .option, .command, .function].map(\.rawValue)

    /// A Return typed with a modifier is another key: it passes even when the owed words did not land.
    @Test(arguments: modifiersThatMakeAnotherKey)
    func aReturnWithAModifierPassesWhenTheOwedWordsDoNotLand(modifier: UInt) {
        let answered = answer(Self.insertNewline, holding: NSEvent.ModifierFlags(rawValue: modifier),
                              asking: FakeApp(owing: { .success(.words) }, settling: { .success(.notLanded) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0 && answered.told == [])
    }

    /// A command the input method does not decide is declined, so it reaches the app.
    @Test(arguments: ["moveLeft:", "deleteBackward:", "insertTab:"])
    func anOtherCommandIsDeclined(name: String) {
        let answered = answer(NSSelectorFromString(name), asking: FakeApp(owing: { .success(.words) }, panelling: { .success(.shown) }))
        #expect(answered.kept == false, "\(name) was claimed")
        #expect(answered.beeps == 0 && answered.told == [])
    }

    /// Text is never handed to this input method as keys, so it is declined.
    @Test func textIsDeclined() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.inputText("e", client: nil) == false)
    }

    /// A call carrying no selector, which IMK may make, is declined rather than trapping and taking the
    /// input method down. Asked through IMK's own override, the edge that could trap; with no command,
    /// the keys this Mac holds change nothing.
    @Test func aCallWithNoSelectorIsDeclined() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.didCommand(by: nil, client: nil) == false)
    }

    /// A cursor given focus is told to the app, which offers it words no cursor took.
    @Test(.timeLimit(.minutes(1))) func aCursorArrivingIsTold() async {
        let assembled = AssembledProcess()
        let controller = assembled.controller()
        controller.activate(FakeTextInputClient())
        #expect(await assembled.process.notices.notices.first { @Sendable _ in true } == .cursorArrived)
        #expect(assembled.recorded.withLock { $0 } == [.footprint(0), .cursorArrived(in: "com.example.editor")])
        withExtendedLifetime(controller) {}
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
