import AppKit
import InputMethod
import Insertion
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
/// Each case builds its controller with a gate of its own and records the effects its verdicts ask for.
@Suite @MainActor struct DictationInputControllerTests {
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

    /// The effects a controller's verdicts asked for, in order.
    @MainActor private final class Performed: Sendable {
        var effects: [SteeringEffect] = []
    }

    /// A controller whose gate asks `app`, and what it performed.
    private func controller(asking app: App = App()) -> (DictationInputController, Performed) {
        let performed = Performed()
        let steering = Steering(gate: SteeringGate(ceiling: .seconds(30), asking: app)) { performed.effects.append($0) }
        return (DictationInputController(steering: steering), performed)
    }

    /// `selector` answered by a controller asking `app`, typed with `modifiers` held, and what it performed.
    private func answer(_ selector: Selector, holding modifiers: NSEvent.ModifierFlags = [],
                        asking app: App) -> (kept: Bool, performed: [SteeringEffect]) {
        let (controller, performed) = controller(asking: app)
        let kept = controller.didCommand(by: selector, holding: modifiers, typedAt: ProcessInfo.processInfo.systemUptime)
        return (kept, performed.effects)
    }

    /// Key-downs are always asked for, so Escape reaches the controller whatever the Return setting says.
    @Test func keyDownsAreAlwaysAskedFor() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.recognizedEvents(nil) == 0x400)
    }

    /// Escape passes while the word box is closed, and the app is told nothing.
    @Test func escapePassesWhileTheBoxIsClosed() {
        let answered = answer(Self.cancelOperation, asking: App(panelling: .success(.shut)))
        #expect(answered.kept == false)
        #expect(answered.performed == [])
    }

    /// Escape is kept while the word box is open, and the app is told, so it cancels the press.
    @Test func escapeIsKeptWhileTheBoxIsOpen() {
        let answered = answer(Self.cancelOperation, asking: App(panelling: .success(.shown)))
        #expect(answered.kept == true)
        #expect(answered.performed == [.tellTheApp])
    }

    /// Escape passes when no app answers whether its box is open, as it does with no app running.
    @Test func escapePassesWhenNoAppAnswers() {
        let answered = answer(Self.cancelOperation, asking: App(panelling: .failure(.nobodyIsListening(port: "port"))))
        #expect(answered.kept == false)
        #expect(answered.performed == [])
    }

    /// A Return passes, silently, when the app owes nothing and when the words it owes have landed.
    @Test(arguments: [Owing.nothing, .words])
    func aReturnPassesWhenNothingIsLeftOwing(owing: Owing) {
        let answered = answer(Self.insertNewline, asking: App(owing: .success(owing), settling: .success(.landed)))
        #expect(answered.kept == false)
        #expect(answered.performed == [])
    }

    /// A bare Return is kept when the words the app owes did not all reach a cursor, and is heard.
    @Test func aReturnIsKeptWhenTheOwedWordsDoNotLand() {
        let answered = answer(Self.insertNewline, asking: App(owing: .success(.words), settling: .success(.notLanded)))
        #expect(answered.kept == true)
        #expect(answered.performed == [.beep])
    }

    /// Each modifier that makes a Return another key, named here rather than read from
    /// `SteeringKey`, so one dropped from its set fails a case instead of removing it.
    nonisolated static let modifiersThatMakeAnotherKey: [UInt] =
        [NSEvent.ModifierFlags.shift, .control, .option, .command, .function].map(\.rawValue)

    /// A Return typed with a modifier is another key: it passes even when the owed words did not land.
    @Test(arguments: modifiersThatMakeAnotherKey)
    func aReturnWithAModifierPassesWhenTheOwedWordsDoNotLand(modifier: UInt) {
        let answered = answer(Self.insertNewline, holding: NSEvent.ModifierFlags(rawValue: modifier),
                              asking: App(owing: .success(.words), settling: .success(.notLanded)))
        #expect(answered.kept == false)
        #expect(answered.performed == [])
    }

    /// A command the input method does not decide is declined, so it reaches the app.
    @Test(arguments: ["moveLeft:", "deleteBackward:", "insertTab:"])
    func anOtherCommandIsDeclined(name: String) {
        let answered = answer(NSSelectorFromString(name), asking: App(owing: .success(.words), panelling: .success(.shown)))
        #expect(answered.kept == false, "\(name) was claimed")
        #expect(answered.performed == [])
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

    /// A cursor given focus is told to the app, which offers it words no cursor took. Other notices
    /// the shared stream holds, such as the Escape the process's steering tells, are passed over.
    @Test(.timeLimit(.minutes(1))) func aCursorArrivingIsTold() async {
        Notices.shared.cursorArrived(in: "com.apple.TextEdit")
        #expect(await Notices.shared.notices.first { @Sendable notice in notice == .cursorArrived } == .cursorArrived)
    }

    /// The shipped process's steering tells the app of a kept Escape, through the notices it hears.
    @Test(.timeLimit(.minutes(1))) func theProcessSteeringTellsTheAppOfAKeptEscape() async {
        await Steering.process.perform(.tellTheApp)
        #expect(await Notices.shared.notices.first { @Sendable notice in notice == .keyTyped(.escape) } == .keyTyped(.escape))
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
