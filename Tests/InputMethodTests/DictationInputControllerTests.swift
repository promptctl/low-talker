import AppKit
import Carbon.HIToolbox
@testable import InputMethod
import InputMethodFakes
import Insertion
import InsertionFakes
import Synchronization
import Testing

/// The controller answers the key-downs IMK hands it. Return and Escape are the two it decides: a
/// Return is held for words the app owes, and an Escape is kept only when the app put its word box away with it.
/// Every other key is declined, so it reaches the app as it would have.
///
/// [LAW:behavior-not-structure] Asked by handing `handle` the event a key makes and reading the answer, not by
/// checking which methods the class overrides. Each event carries the modifiers the case holds, never the ones
/// this Mac's keyboard holds while the suite runs.
///
/// On the main actor because the controller is an `IMKInputController`, which is built and answered there.
/// Each case builds its controller in a process of its own, whose gate asks what the case gave it.
@Suite @MainActor struct DictationInputControllerTests {
    /// A controller of a process whose gate asks `app`, and the process.
    private func controller(asking app: FakeApp = FakeApp()) -> (DictationInputController, AssembledProcess) {
        let assembled = AssembledProcess(asking: app)
        return (assembled.controller(), assembled)
    }

    /// `keyCode` typed with `modifiers` held, answered by a controller asking `app`: whether it was
    /// kept, and how many times the process beeped.
    private func answer(_ keyCode: Int, holding modifiers: NSEvent.ModifierFlags = [],
                        asking app: FakeApp) -> (kept: Bool, beeps: Int) {
        let (controller, assembled) = controller(asking: app)
        let kept = controller.handle(Keys.down(keyCode, holding: modifiers), client: nil)
        return (kept, assembled.beeps)
    }

    /// Key-downs are always asked for, so Escape reaches the controller whatever the Return setting says.
    @Test func keyDownsAreAlwaysAskedFor() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.recognizedEvents(nil) == 0x400)
    }

    /// An Escape bare, and under Option and Right Option, the chord's modifier: `SteeringKeyTests` holds
    /// every other modifier to the same key.
    nonisolated static let escapes: [UInt] = [0, NSEvent.ModifierFlags.option.rawValue, 0x80140]

    /// An Escape passes when the app had no word box to put away with it.
    @Test(arguments: escapes)
    func escapePassesWhenNoBoxWasShown(held: UInt) {
        let answered = answer(kVK_Escape, holding: .init(rawValue: held), asking: FakeApp(dismissing: { .success(.nothingShown) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0)
    }

    /// An Escape is kept, silently, when the app put its word box away with it.
    @Test(arguments: escapes)
    func escapeIsKeptWhenTheAppDismissedTheBox(held: UInt) {
        let answered = answer(kVK_Escape, holding: .init(rawValue: held), asking: FakeApp(dismissing: { .success(.dismissed) }))
        #expect(answered.kept == true)
        #expect(answered.beeps == 0)
    }

    /// An Escape passes when no app answers, as it does with no app running.
    @Test(arguments: escapes)
    func escapePassesWhenNoAppAnswers(held: UInt) {
        let answered = answer(kVK_Escape, holding: .init(rawValue: held),
                              asking: FakeApp(dismissing: { .failure(.wire(.nobodyIsListening(port: "port"))) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0)
    }

    /// A Return passes, silently, when the app owes nothing and when the words it owes have landed.
    @Test(arguments: Keys.returns, [Owing.nothing, .words])
    func aReturnPassesWhenNothingIsLeftOwing(keyCode: Int, owing: Owing) {
        let answered = answer(keyCode, asking: FakeApp(owing: { .success(owing) }, settling: { .success(.landed) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0)
    }

    /// A bare Return is kept when the words the app owes did not all reach a cursor, and is heard.
    @Test(arguments: Keys.returns)
    func aReturnIsKeptWhenTheOwedWordsDoNotLand(keyCode: Int) {
        let answered = answer(keyCode, asking: FakeApp(owing: { .success(.words) }, settling: { .success(.notLanded) }))
        #expect(answered.kept == true)
        #expect(answered.beeps == 1)
    }

    /// A Return typed with Option is another key: it passes even when the owed words did not land.
    @Test func aReturnWithAModifierPassesWhenTheOwedWordsDoNotLand() {
        let answered = answer(kVK_Return, holding: .option, asking: FakeApp(owing: { .success(.words) }, settling: { .success(.notLanded) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0)
    }

    /// A key the input method does not decide is declined, so it reaches the app: a letter under Option,
    /// and Command+Period and Control+[, which AppKit binds to `cancelOperation:` as it binds Escape.
    @Test(arguments: [(kVK_ANSI_A, NSEvent.ModifierFlags.option.rawValue), (kVK_ANSI_Period, NSEvent.ModifierFlags.command.rawValue),
                      (kVK_ANSI_LeftBracket, NSEvent.ModifierFlags.control.rawValue)])
    func anOtherKeyIsDeclined(keyCode: Int, held: UInt) {
        let answered = answer(keyCode, holding: .init(rawValue: held), asking: FakeApp(owing: { .success(.words) }, dismissing: { .success(.dismissed) }))
        #expect(answered.kept == false, "key \(keyCode) was claimed")
        #expect(answered.beeps == 0)
    }

    /// The app is asked about a key at the moment the key went down, the event's own, which is the
    /// moment a latched press is ended at.
    @Test(arguments: [kVK_Escape, kVK_Return])
    func theAppIsAskedAboutAKeyAtTheMomentItWentDown(keyCode: Int) {
        let app = FakeApp(owing: { .success(.words) }, settling: { .success(.landed) }, dismissing: { .success(.nothingShown) })
        let (controller, _) = controller(asking: app)
        _ = controller.handle(Keys.down(keyCode, at: 4321.5), client: nil)
        #expect(!app.askedAt.isEmpty)
        #expect(app.askedAt.allSatisfy { $0 == 4321.5 }, "asked at \(app.askedAt)")
    }

    /// A held Escape's repeats follow its press, unasked: kept with it once the box is put away, which
    /// would otherwise find nothing shown and reach the app, and passed with it when there was no box.
    @Test(arguments: [Dismissal.dismissed, .nothingShown])
    func aHeldEscapesRepeatsFollowItsPress(first: Dismissal) {
        let answers = Mutex([first, .nothingShown, .nothingShown])
        let app = FakeApp(dismissing: { .success(answers.withLock { $0.removeFirst() }) })
        let (controller, _) = controller(asking: app)
        let pressed = controller.handle(Keys.down(kVK_Escape, holding: .option), client: nil)
        let repeats = (0..<2).map { _ in controller.handle(Keys.down(kVK_Escape, holding: .option, repeating: true), client: nil) }
        #expect(pressed == (first == .dismissed))
        #expect(repeats == [pressed, pressed])
        #expect(app.askedAt.count == 1, "the repeats were asked about")
    }

    /// A held Return kept for owed words stays kept at each repeat, and is heard once.
    @Test func aHeldReturnsRepeatsFollowItsPressUnheard() {
        let (controller, assembled) = controller(asking: FakeApp(owing: { .success(.words) }, settling: { .success(.notLanded) }))
        let pressed = controller.handle(Keys.down(kVK_Return), client: nil)
        let repeated = controller.handle(Keys.down(kVK_Return, repeating: true), client: nil)
        #expect(pressed && repeated)
        #expect(assembled.beeps == 1)
    }

    /// A held key repeats wherever focus goes: an Escape kept in one client, whose repeats reach
    /// another, follows its press there, unasked.
    @Test func aHeldEscapesRepeatsFollowItsPressIntoAnotherClient() {
        let answers = Mutex([Dismissal.dismissed, .nothingShown])
        let app = FakeApp(dismissing: { .success(answers.withLock { $0.removeFirst() }) })
        let assembled = AssembledProcess(asking: app)
        let pressedIn = assembled.controller(), repeatedIn = assembled.controller()
        #expect(pressedIn.handle(Keys.down(kVK_Escape, holding: .option), client: nil) == true)
        #expect(repeatedIn.handle(Keys.down(kVK_Escape, holding: .option, repeating: true), client: nil) == true)
        #expect(app.askedAt.count == 1, "the repeat was asked about")
    }

    /// A repeat is said at its press's level, so a kept repeat is on the record as its press is, and
    /// says it is a repeat.
    @Test(arguments: [Settlement.landed, .notLanded])
    func aRepeatIsSaidAtItsPresssLevel(settled: Settlement) throws {
        let steering = AssembledProcess(asking: FakeApp(owing: { .success(.words) }, settling: { .success(settled) })).process.steering
        let press = try #require(steering.decide(KeyDown(steering: .return, typedAt: 1, repeats: false)))
        let repeated = try #require(steering.decide(KeyDown(steering: .return, typedAt: 2, repeats: true)))
        #expect(repeated.decision.verdict == press.decision.verdict)
        #expect(repeated.decision.routine == press.decision.routine)
        #expect(repeated.decision.because.contains("repeats"))
    }

    /// A repeat after another key went down is no repeat of the steering key pressed before it, and is
    /// decided as a press: an Escape kept, then a letter or a Return, then an Escape repeat, is asked about.
    @Test(arguments: [kVK_ANSI_A, kVK_Return])
    func aRepeatAfterAnotherKeyIsDecidedAsAPress(between: Int) {
        let answers = Mutex([Dismissal.dismissed, .nothingShown])
        let app = FakeApp(dismissing: { .success(answers.withLock { $0.removeFirst() }) })
        let (controller, _) = controller(asking: app)
        #expect(controller.handle(Keys.down(kVK_Escape), client: nil) == true)
        _ = controller.handle(Keys.down(between), client: nil)
        #expect(controller.handle(Keys.down(kVK_Escape, repeating: true), client: nil) == false)
    }

    /// A call carrying no event, which IMK makes after an activate, is declined rather than trapping and
    /// taking the input method down, and so is an event that is no key.
    @Test func aCallWithNoKeyIsDeclined() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.handle(nil, client: nil) == false)
        #expect(controller.handle(Keys.click(), client: nil) == false)
    }

    /// Every key typed says which client has the keyboard, steering key or not: of two cursors in the app
    /// in front, words are refused until a key is typed into one, and then go to it. A call with no key
    /// says nothing.
    @Test(arguments: [kVK_ANSI_A, kVK_Escape])
    func aKeyTypedSaysWhichClientHasTheKeyboard(keyCode: Int) {
        let assembled = AssembledProcess(asking: FakeApp(dismissing: { .success(.nothingShown) }))
        let typedInto = assembled.controller(), behind = assembled.controller()
        typedInto.activate(FakeTextInputClient())
        behind.activate(FakeTextInputClient())
        let cursor = {
            assembled.process.focused.inFront(for: .cursorInFront, whileInFrontIs: assembled.frontmost,
                                              selected: assembled.selected, screens: assembled.screens).cursor
        }
        #expect(throws: Refusal.cursorIsNotSettled) { try cursor().get() }

        _ = typedInto.handle(nil, client: nil)
        #expect(throws: Refusal.cursorIsNotSettled, "a call with no key settled the keyboard") { try cursor().get() }

        _ = typedInto.handle(Keys.down(keyCode, holding: .option), client: nil)
        #expect(throws: Never.self) { try cursor().get() }
        withExtendedLifetime(behind) {}
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
