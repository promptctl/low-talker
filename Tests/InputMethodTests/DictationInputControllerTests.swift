import AppKit
import InputMethod
import Testing

/// The controller hands back every key it is offered.
///
/// [LAW:behavior-not-structure] Asked by offering real events and reading the answer, not by
/// checking which methods the class overrides: a later ticket may answer keys through a
/// different door, and what must not change is that no key stops here.
///
/// On the main actor because the answering is done with AppKit objects - an `NSEvent` and an
/// `IMKInputController` - and swift-testing runs the cases of a parameterised test
/// concurrently. Building those off the main thread is not promised to work, and what an
/// unpromised thing does is fail on some runs and not others.
/// [LAW:no-ambient-temporal-coupling]
///
/// Serialized because the arrivals told are one stream with one reader at a time: two cases
/// waiting on it at once each take arrivals the other is waiting for.
@Suite(.serialized) @MainActor struct DictationInputControllerTests {
    /// A key as something that can be carried into a test case. `NSEvent` itself cannot -
    /// it is explicitly not `Sendable` - so what travels is the description of the press and
    /// the event is built where it is used.
    struct Press: Sendable, CustomStringConvertible {
        let description: String
        let characters: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags.RawValue

        /// Throwing rather than force-unwrapping: an `NSEvent` AppKit declined to build is
        /// this one case failing by name, where a trap would take the whole test process
        /// down and every other suite's result with it.
        var event: NSEvent {
            get throws {
                try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .init(rawValue: modifiers), timestamp: 0,
                    windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: keyCode
                ), "AppKit built no event for \(description)")
            }
        }
    }

    /// Presses a person would notice losing: a plain letter, the dead key the checkpoint
    /// types, a Command shortcut, and Return.
    /// `nonisolated` where the suite is not: this is the case list, read to build the cases
    /// before any of them runs, and it carries no AppKit object - `Press` is four values.
    nonisolated static let presses: [Press] = [
        .init(description: "the letter e", characters: "e", keyCode: 14, modifiers: 0),
        .init(description: "Option+E, the dead key", characters: "´", keyCode: 14, modifiers: NSEvent.ModifierFlags.option.rawValue),
        .init(description: "Command+Z", characters: "z", keyCode: 6, modifiers: NSEvent.ModifierFlags.command.rawValue),
        .init(description: "Return", characters: "\r", keyCode: 36, modifiers: 0),
    ]

    /// Asked for nothing: the app hears the modifier keys itself, and a key typed is none of
    /// this process's business.
    @Test func noEventIsAskedFor() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.recognizedEvents(nil) == 0)
    }

    /// A change of the modifier keys, offered anyway, is handed back like every key.
    @Test func aChangeOfTheModifierKeysIsHandedBack() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        let moved = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true))
        moved.type = .flagsChanged
        moved.flags = .maskAlternate
        let event = try #require(NSEvent(cgEvent: moved))
        #expect(controller.handle(event, client: nil) == false, "Right Option was claimed by the input method")
    }

    /// A cursor given focus is told to the app, which offers it words no cursor took.
    @Test(.timeLimit(.minutes(1))) func aCursorArrivingIsTold() async {
        Notices.shared.cursorArrived(in: "com.apple.TextEdit")
        #expect(await Notices.shared.notices.first { @Sendable _ in true } == .cursorArrived)
    }

    /// A call carrying no event, which IMK makes, is handed back rather than trapping and
    /// taking the input method down.
    @Test func aCallWithNoEventIsHandedBack() throws {
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        #expect(controller.handle(nil, client: nil) == false)
    }

    @Test(arguments: presses)
    func everyKeyIsHandedBack(press: Press) throws {
        let controller = try #require(
            DictationInputController(server: nil, delegate: nil, client: nil),
            "the controller could not be built to be asked"
        )
        #expect(try controller.handle(press.event, client: nil) == false, "\(press) was claimed by the input method")
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
