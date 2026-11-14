import Foundation
@testable import InputMethod
import InputMethodFakes
import Insertion
import InsertionFakes
import Testing

/// What a commit does to the field, and what it answers: the input method's `Committer` over the
/// fake field, and the `FakeInputMethod` every loop test asks, handed the same field and the same
/// request. A fake that took back, or put in, other text than the input method does would fail
/// here before a cancel test built on it could pass. [LAW:behavior-not-structure]
@Suite struct CommitContract {
    static let into = "com.example.editor"

    /// A field holding `before`, its caret at the end, then `request` committed into it.
    static let cases: [(before: String, request: InsertRequest)] = [
        ("say ", InsertRequest("🫠 hello", into: .app(into))),
        ("say 🫠 hello", InsertRequest("", into: .app(into), replacing: "🫠 hello")),
        ("old words hello", InsertRequest("old words", into: .app(into), replacing: "old words hello")),
        ("say goodbye", InsertRequest("", into: .app(into), replacing: "hello")),
        ("hi", InsertRequest("", into: .app(into), replacing: "hello there")),
    ]

    @MainActor
    @Test(arguments: cases)
    func theFakeAndTheInputMethodCommitTheSame(before: String, request: InsertRequest) throws {
        let client = FakeTextInputClient(in: Self.into, holding: before)
        let cursor = try client.cursor()
        let turn = Turn()
        _ = Committer.place(request, turn: turn, inFront: {
            InFront(frontmost: Self.into, selected: true, cursorApplication: Self.into, cursors: 1, ruledOut: 0,
                    field: nil, screens: [], cursor: .success(cursor))
        })
        guard case .answered(let answer, _) = turn.wait(.zero) else { Issue.record("\(turn.wait(.zero))"); return }
        let real: String = switch answer {
        case let .inserted(characters, into): "inserted \(characters) into \(into)"
        case .refused(let refusal): "\(InsertFailure.refused(refusal))"
        case let .notYetTaken(characters, into): "\(InsertFailure.notYetTaken(NotYetTaken(characters: characters, into: into)))"
        }

        let inputMethod = FakeInputMethod()
        inputMethod.reaching(Self.into)
        _ = try inputMethod.insert(InsertRequest(before, into: .app(Self.into)))
        let fake: String
        do throws(InsertFailure) {
            let inserted = try inputMethod.insert(request)
            fake = "inserted \(inserted.characters) into \(inserted.into)"
        } catch { fake = "\(error)" }

        #expect(fake == real)
        #expect(inputMethod.field == client.text)
    }
}
