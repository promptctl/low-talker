import AppKit
import Carbon.HIToolbox
@testable import InputMethod
import InputMethodFakes
import Insertion
import InsertionFakes
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
    /// The key-down a key makes with `modifiers` held, as IMK hands it to `handle`.
    nonisolated static func keyDown(_ keyCode: Int, holding modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(keyCode))!
    }

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
        let kept = controller.handle(Self.keyDown(keyCode, holding: modifiers), client: nil)
        return (kept, assembled.beeps)
    }

    /// Key-downs are always asked for, so Escape reaches the controller whatever the Return setting says.
    @Test func keyDownsAreAlwaysAskedFor() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.recognizedEvents(nil) == 0x400)
    }

    /// What an Escape is typed with. Option first: it is the chord's modifier, so the Escape a person
    /// types mid-press, and AppKit binds Option+Escape to `complete:`, not `cancelOperation:`.
    nonisolated static let escapeHeld: [UInt] = [
        NSEvent.ModifierFlags.option.rawValue,
        0x80140, // Right Option, the default chord, as a real event carries it
        0, NSEvent.ModifierFlags.shift.rawValue, NSEvent.ModifierFlags.control.rawValue,
        NSEvent.ModifierFlags.command.rawValue, NSEvent.ModifierFlags.function.rawValue,
    ]

    /// An Escape passes when the app had no word box to put away with it.
    @Test(arguments: escapeHeld)
    func escapePassesWhenNoBoxWasShown(held: UInt) {
        let answered = answer(kVK_Escape, holding: .init(rawValue: held), asking: FakeApp(dismissing: { .success(.nothingShown) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0)
    }

    /// An Escape is kept, silently, when the app put its word box away with it, whatever is held.
    @Test(arguments: escapeHeld)
    func escapeIsKeptWhenTheAppDismissedTheBox(held: UInt) {
        let answered = answer(kVK_Escape, holding: .init(rawValue: held), asking: FakeApp(dismissing: { .success(.dismissed) }))
        #expect(answered.kept == true)
        #expect(answered.beeps == 0)
    }

    /// An Escape passes when no app answers, as it does with no app running.
    @Test(arguments: escapeHeld)
    func escapePassesWhenNoAppAnswers(held: UInt) {
        let answered = answer(kVK_Escape, holding: .init(rawValue: held),
                              asking: FakeApp(dismissing: { .failure(.wire(.nobodyIsListening(port: "port"))) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0)
    }

    /// Return and the keypad's Enter.
    nonisolated static let returns = [kVK_Return, kVK_ANSI_KeypadEnter]

    /// A Return passes, silently, when the app owes nothing and when the words it owes have landed.
    @Test(arguments: returns, [Owing.nothing, .words])
    func aReturnPassesWhenNothingIsLeftOwing(keyCode: Int, owing: Owing) {
        let answered = answer(keyCode, asking: FakeApp(owing: { .success(owing) }, settling: { .success(.landed) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0)
    }

    /// A bare Return is kept when the words the app owes did not all reach a cursor, and is heard.
    @Test(arguments: returns)
    func aReturnIsKeptWhenTheOwedWordsDoNotLand(keyCode: Int) {
        let answered = answer(keyCode, asking: FakeApp(owing: { .success(.words) }, settling: { .success(.notLanded) }))
        #expect(answered.kept == true)
        #expect(answered.beeps == 1)
    }

    /// Each modifier that makes a Return another key, named here rather than read from
    /// `SteeringKey`, so one dropped from its set fails a case instead of removing it.
    nonisolated static let modifiersThatMakeAnotherKey: [UInt] =
        [NSEvent.ModifierFlags.shift, .control, .option, .command, .function].map(\.rawValue)

    /// A Return typed with a modifier is another key: it passes even when the owed words did not land.
    @Test(arguments: modifiersThatMakeAnotherKey)
    func aReturnWithAModifierPassesWhenTheOwedWordsDoNotLand(modifier: UInt) {
        let answered = answer(kVK_Return, holding: NSEvent.ModifierFlags(rawValue: modifier),
                              asking: FakeApp(owing: { .success(.words) }, settling: { .success(.notLanded) }))
        #expect(answered.kept == false)
        #expect(answered.beeps == 0)
    }

    /// A key the input method does not decide is declined, so it reaches the app, Option or not; F5 is
    /// bound to `complete:` as Option+Escape is.
    @Test(arguments: [kVK_ANSI_A, kVK_Tab, kVK_Delete, kVK_F5], [0, NSEvent.ModifierFlags.option.rawValue])
    func anOtherKeyIsDeclined(keyCode: Int, held: UInt) {
        let answered = answer(keyCode, holding: .init(rawValue: held),
                              asking: FakeApp(owing: { .success(.words) }, dismissing: { .success(.dismissed) }))
        #expect(answered.kept == false, "key \(keyCode) was claimed")
        #expect(answered.beeps == 0)
    }

    /// A call carrying no event, which IMK makes after an activate, is declined rather than trapping and
    /// taking the input method down, and so is an event that is no key.
    @Test func aCallWithNoKeyIsDeclined() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(controller.handle(nil, client: nil) == false)
        #expect(controller.handle(click, client: nil) == false)
    }

    /// Every key typed says which client has the keyboard, steering key or not: of two live cursors in one
    /// app, the one a key is typed into is the one left live. A call with no key says nothing.
    @Test(arguments: [kVK_ANSI_A, kVK_Escape])
    func aKeyTypedSaysWhichClientHasTheKeyboard(keyCode: Int) {
        let assembled = AssembledProcess(asking: FakeApp(dismissing: { .success(.nothingShown) }))
        let typedInto = assembled.controller(), behind = assembled.controller()
        typedInto.activate(FakeTextInputClient())
        behind.activate(FakeTextInputClient())

        _ = typedInto.handle(nil, client: nil)
        #expect(!assembled.process.focused.holding(behind).hasSuffix(", not live"), "a call with no key moved the keyboard")

        _ = typedInto.handle(Self.keyDown(keyCode, holding: .option), client: nil)
        #expect(!assembled.process.focused.holding(typedInto).hasSuffix(", not live"))
        #expect(assembled.process.focused.holding(behind).hasSuffix(", not live"))
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
