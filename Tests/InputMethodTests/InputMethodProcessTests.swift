import Foundation
@testable import InputMethod
import InputMethodFakes
import Insertion
import TestProbes
import Testing

/// The input method's insert path, whole: controllers handed clients, inserts through the process
/// from the port's side, and what the app is told, on a process assembled from fakes.
///
/// [LAW:behavior-not-structure] Read from where the words went, what each insert answered, and the
/// notices the process recorded - never from which part decided.
@Suite @MainActor struct InputMethodProcessTests {
    /// `text` inserted as the insert port asks, from a thread that is not the main one.
    private func insert(_ text: String, into destination: Destination = .cursorInFront,
                        through assembled: AssembledProcess) async -> InsertionAnswer {
        let process = assembled.process!
        return await onAThreadOfItsOwn { process.insert(InsertRequest(text, into: destination)).answer }
    }

    /// A client arrives and the app is told; words land in it; once it leaves, words are refused; and
    /// once it is back and its app quits, words are refused though nothing deactivated it.
    @Test(.timeLimit(.minutes(1))) func aClientArrivesTakesWordsLeavesAndItsAppQuits() async {
        let assembled = AssembledProcess()
        let field = FakeTextInputClient()
        let controller = assembled.controller()

        controller.activate(field)
        #expect(await insert("hello", through: assembled) == .inserted(characters: 5, into: "com.example.editor"))
        #expect(field.text == "hello")

        controller.deactivateServer(nil)
        #expect(await insert(" again", through: assembled) == .refused(.noTextFieldHasFocus))

        controller.activate(field)
        assembled.process.focused.applicationQuit("com.example.editor")
        #expect(await insert(" again", through: assembled) == .refused(.noTextFieldHasFocus))
        #expect(field.text == "hello")
        withExtendedLifetime(controller) {}
        #expect(assembled.recorded.withLock { $0 } == [
            .footprint(0), .cursorArrived(in: "com.example.editor"),
            .footprint(0), .cursorArrived(in: "com.example.editor"),
        ])
    }

    /// A reading that refuses an insert: how the case sets the Mac up, which may activate the field,
    /// and the destination the insert asks for.
    struct RefusingReading: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let refusal: Refusal
        let setUp: @MainActor @Sendable (AssembledProcess, DictationInputController, FakeTextInputClient) -> Destination

        static let all = [
            RefusingReading(testDescription: "another app in front", refusal: .cursorIsInAnotherApp) { assembled, controller, field in
                controller.activate(field)
                assembled.frontmost = "com.example.other"
                return .cursorInFront
            },
            RefusingReading(testDescription: "the dictation's app not in front", refusal: .dictationIsInAnotherApp) { _, controller, field in
                controller.activate(field)
                return .app("com.example.other")
            },
            RefusingReading(testDescription: "the source not selected", refusal: .inputSourceIsNotSelected) { assembled, controller, field in
                controller.activate(field)
                assembled.selected = false
                return .cursorInFront
            },
            RefusingReading(testDescription: "no client", refusal: .noTextFieldHasFocus) { _, _, _ in .cursorInFront },
            RefusingReading(testDescription: "the caret on no screen", refusal: .noTextFieldHasFocus) { assembled, controller, field in
                controller.activate(field)
                assembled.screens = [CGRect(x: 5000, y: 5000, width: 10, height: 10)]
                return .cursorInFront
            },
        ]
    }

    /// Each reading that refuses an insert does, with its own answer, and the field is left as it was.
    @Test(.timeLimit(.minutes(1)), arguments: RefusingReading.all)
    func aReadingThatRefusesAnInsertIsAnsweredWithItsRefusal(reading: RefusingReading) async {
        let assembled = AssembledProcess()
        let field = FakeTextInputClient()
        // Held through the insert: a controller that ends takes its cursor with it.
        let controller = assembled.controller()
        let destination = reading.setUp(assembled, controller, field)
        #expect(await insert("hello", into: destination, through: assembled) == .refused(reading.refusal))
        #expect(field.text.isEmpty)
        withExtendedLifetime(controller) {}
    }

    /// An activation over the memory ceiling takes no client, the overrun is told to the app as the
    /// stream's last notice, and an insert asked meanwhile is refused.
    @Test(.timeLimit(.minutes(1))) func anActivationOverTheCeilingTakesNoClientAndTellsTheApp() async throws {
        let assembled = AssembledProcess()
        let over = Notices.memoryCeiling + 1
        assembled.footprint = over
        let field = FakeTextInputClient()
        let controller = assembled.controller()

        controller.activate(field)

        #expect(await insert("hello", through: assembled) == .refused(.noTextFieldHasFocus))
        #expect(field.text.isEmpty)
        let overrun = try #require(Overrun(footprint: over, ceiling: Notices.memoryCeiling))
        #expect(assembled.recorded.withLock { $0 } == [.footprint(over), .overrun(overrun)])
        // The overrun finishes the stream, so the first notice read is the last there is.
        var notices = assembled.process.notices.notices.makeAsyncIterator()
        #expect(await notices.next() == .overMemoryCeiling(overrun))
        #expect(await notices.next() == nil)
        withExtendedLifetime(controller) {}
    }
}
