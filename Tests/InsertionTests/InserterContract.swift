import Foundation
@testable import Insertion
import InsertionFakes
import TestProbes
import Testing

/// What an `Inserter` says of each answer the input method can give: words inserted come back as
/// `Inserted`, and a refusal or words not yet taken are thrown as themselves. Stated once, run
/// against the one fake every test of the loop asks, and against `InputMethodInserter` sending
/// from `insertion-probe`, a process that is not the suite, to a port the suite hosts. A fake that
/// read an answer differently from the real end would fail here before any test built on it
/// could pass. [LAW:behavior-not-structure]
///
/// Each subject is asked to insert `text` while the far end gives `answer`, and says what came of
/// it as `insertion-probe` prints it, so both are held to the line a person would read.
@Suite struct InserterContract {
    static let text = "hello"
    static let into = "com.example.editor"

    static let answers: [InsertionAnswer] = [
        .inserted(characters: text.count, into: into),
        .refused(.noTextFieldHasFocus),
        .refused(.dictationIsInAnotherApp),
        .notYetTaken(characters: text.count, into: into),
    ]

    /// What `insertion-probe` prints of an insert's outcome.
    static func printed(_ outcome: () throws(InsertFailure) -> Inserted) -> String {
        do throws(InsertFailure) {
            let inserted = try outcome()
            return "inserted \(inserted.characters) into \(inserted.into)"
        } catch { return "\(error)" }
    }

    /// The fake, told to give `answer` through the knobs every loop test turns.
    static func fake(answering answer: InsertionAnswer) -> FakeInputMethod {
        let inputMethod = FakeInputMethod()
        switch answer {
        case .inserted(_, let into): inputMethod.reaching(into)
        case .refused(let refusal): inputMethod.refusing(.refused(refusal))
        case .notYetTaken(let characters, let into): inputMethod.refusing(.notYetTaken(NotYetTaken(characters: characters, into: into)))
        }
        return inputMethod
    }

    @Test(arguments: answers)
    func theFakeAndTheRealPortSayTheSame(answer: InsertionAnswer) async throws {
        let fake = Self.printed { () throws(InsertFailure) in try Self.fake(answering: answer).insert(Self.text, into: .cursorInFront) }

        let name = aPortNobodyElseUses()
        let probe = try await Probe.signed(as: "ai.promptctl.low-talker.test.probe")
        defer { try? FileManager.default.removeItem(at: probe.url) }
        let port = try InsertionPort(
            portName: name, senders: probe.identity, build: aBuild, queue: DispatchQueue(label: name), told: { Issue.record("told \($0)") }
        ) { _ in answer }
        let real = try await Probe.send(Self.text, to: name, answeredBy: try OwnProcess.identity(), from: probe.url)
        withExtendedLifetime(port) {}

        #expect(fake == real)
        #expect(fake == Self.expected(answer))
    }

    /// What each answer reads as, written out so the contract is not only that the two agree.
    static func expected(_ answer: InsertionAnswer) -> String {
        switch answer {
        case let .inserted(characters, into): "inserted \(characters) into \(into)"
        case .refused(let refusal): "\(InsertFailure.refused(refusal))"
        case let .notYetTaken(characters, into): "\(InsertFailure.notYetTaken(NotYetTaken(characters: characters, into: into)))"
        }
    }
}
