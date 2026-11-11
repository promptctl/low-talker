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

    /// Each reading that refuses an insert does, with its own answer, and the field is left as it was.
    @Test(.timeLimit(.minutes(1)), arguments: [
        ("another app in front", Refusal.cursorIsInAnotherApp),
        ("the dictation's app not in front", .dictationIsInAnotherApp),
        ("the source not selected", .inputSourceIsNotSelected),
        ("no client", .noTextFieldHasFocus),
        ("the caret on no screen", .noTextFieldHasFocus),
    ])
    func aReadingThatRefusesAnInsertIsAnsweredWithItsRefusal(reading: String, refusal: Refusal) async {
        let assembled = AssembledProcess()
        let field = FakeTextInputClient()
        // Held through the insert: a controller that ends takes its cursor with it.
        let controller = assembled.controller()
        var destination = Destination.cursorInFront
        switch reading {
        case "another app in front":
            controller.activate(field)
            assembled.frontmost = "com.example.other"
        case "the dictation's app not in front":
            controller.activate(field)
            destination = .app("com.example.other")
        case "the source not selected":
            controller.activate(field)
            assembled.selected = false
        case "no client":
            break
        default:
            controller.activate(field)
            assembled.screens = [CGRect(x: 5000, y: 5000, width: 10, height: 10)]
        }
        #expect(await insert("hello", into: destination, through: assembled) == .refused(refusal), "\(reading)")
        #expect(field.text.isEmpty)
        withExtendedLifetime(controller) {}
    }

    /// An activation over the memory ceiling takes no client, the overrun is told to the app as the
    /// stream's last notice, and an insert asked meanwhile is refused.
    @Test(.timeLimit(.minutes(1))) func anActivationOverTheCeilingTakesNoClientAndTellsTheApp() async {
        let assembled = AssembledProcess()
        let over = Notices.memoryCeiling + 1
        assembled.footprint = over
        let field = FakeTextInputClient()
        let controller = assembled.controller()

        controller.activate(field)

        #expect(await insert("hello", through: assembled) == .refused(.noTextFieldHasFocus))
        #expect(field.text.isEmpty)
        let overrun = Overrun(footprint: over, ceiling: Notices.memoryCeiling)
        #expect(assembled.recorded.withLock { $0 } == [.footprint(over), overrun.map { .overrun($0) }].compactMap { $0 })
        var told: [Notices.Notice] = []
        for await notice in assembled.process.notices.notices { told.append(notice) }
        #expect(told == overrun.map { [.overMemoryCeiling($0)] })
        withExtendedLifetime(controller) {}
    }
}
